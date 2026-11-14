import AVFoundation
import Combine
import SwiftUI
import os

@MainActor
final class ProbeAudio: ObservableObject {
    let transportOnly: Bool
    private let idleTimeout: TimeInterval?
    private let routeName: String
    private var configuration: Configuration?
    struct Configuration {
        var filters: [EQFilter]
        var preamp: Double
        var stereo: EQStereo
        var bypassGain: Double
        var peakProtection: Bool
    }
    @Published private(set) var running = false
    @Published private(set) var preparing = false
    @Published private(set) var status = "Ready to prepare the receiver"
    @Published private(set) var route = "—"
    @Published private(set) var diagnostics = "No test has run."
    @Published private(set) var inputLevel = "—"
    @Published private(set) var outputLevel = "—"
    @Published private(set) var connected = false
    @Published private(set) var failure: String?
    @Published var bypass = false { didSet { updateFilter() } }
    @Published var cutoff = 1000.0 { didSet { updateFilter() } }

    private let log = Logger(subsystem: "local.aural.route-probe", category: "receiver")
    private var engine: AVAudioEngine?
    private var link: OpaquePointer?
    private var renderer: OpaquePointer?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var wantsRunning = false
    private var permissionRequest = 0
    private var interrupted = false
    private var startedAt: Date?
    private var lastAudioAt: Date?
    private var previousFrames: UInt64 = 0
    private var events: [String] = []
    private var lastDiagnosticLogAt: Date?

    init(transportOnly: Bool = false, idleTimeout: TimeInterval? = 90, routeName: String = "Aural Route Probe") {
        self.transportOnly = transportOnly
        self.idleTimeout = idleTimeout
        self.routeName = routeName
        if transportOnly {
            status = "Ready for silent transport diagnostic"
            route = "No playback — transport only"
            event("Transport-only diagnostic: no audio session, engine or EQ will be created.")
            return
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
            Task { @MainActor in self?.becameInactive(context) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
            Task { @MainActor in self?.resumeRecommended(context) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            Task { @MainActor in self?.routeChanged(reason, previous: previous) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fail("Audio services reset. Prepare the receiver and select the route again.") }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running, self.engine?.isRunning == false else { return }
                self.fail("Audio configuration changed. Prepare the receiver and select the route again.")
            }
        })
    }

    func prepare() {
        guard !running && !preparing else { return }
        wantsRunning = true
        failure = nil
        interrupted = false // An explicit user retry may attempt activation again.
        if transportOnly { start(); return }
        permissionRequest += 1
        let request = permissionRequest
        preparing = true
        status = "Checking audio-session permission…"
        // This prototype uses playAndRecord to keep its output session separate.
        // No input node is connected and no microphone samples are read.
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            Task { @MainActor in
                guard let self, self.permissionRequest == request else { return }
                self.preparing = false
                guard self.wantsRunning else { return }
                guard allowed else {
                    self.fail("Allow microphone permission in Settings to enable Aural’s separate playback session. Aural does not read or record your microphone.")
                    return
                }
                self.start()
            }
        }
    }

    private func start() {
        guard wantsRunning, !interrupted else { return }
        stopResources(deactivate: true)
        guard let newLink = transportOnly ? ar_link_create_transport_sink() : ar_link_create(false) else {
            fail("Could not allocate the audio receiver."); return
        }
        link = newLink
        let error = ar_link_start(newLink)
        guard error == 0 else { fail("Could not listen on the local audio port: \(String(cString: strerror(error))) (\(error))."); return }
        if transportOnly { beginMonitoring(); return }
        guard let newRenderer = ar_renderer_create(newLink) else { fail("Could not allocate Aural’s EQ engine."); return }
        renderer = newRenderer
        guard applyConfiguration(newRenderer) else { fail("The EQ settings were rejected."); return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP])
            try session.setPreferredSampleRate(Double(ARSampleRate))
            try session.setPreferredIOBufferDuration(0.005)
            try session.setPrefersInterruptionOnRouteDisconnect(true)
            try session.setActive(true)
            event("Playback session activated: \(session.category.rawValue); policy=\(session.routeSharingPolicy.rawValue); outputs=\(outputDescription(session.currentRoute)).")
            guard physicalOutputIsValid() else {
                fail("Unsupported receiver output: \(outputDescription(session.currentRoute)). Choose a physical output before starting again.")
                return
            }
            let newEngine = AVAudioEngine()
            engine = newEngine
            guard let node = ARMakeSourceNode(newRenderer),
                  let format = AVAudioFormat(standardFormatWithSampleRate: Double(ARSampleRate), channels: 2) else {
                fail("Could not create the stereo audio source.")
                return
            }
            // The source always consumes 48 kHz. AVAudioEngine's mixer converts
            // to the hardware rate; a 44.1 kHz output must not change pitch.
            newEngine.attach(node)
            try newEngine.connectNode(node, to: newEngine.mainMixerNode, format: format)
            ar_renderer_enable(newRenderer, true)
            try newEngine.start()
        } catch {
            let error = error as NSError
            fail("Audio start failed: \(error.domain) \(error.code) — \(error.localizedDescription)")
            return
        }
        beginMonitoring()
    }

    private func beginMonitoring() {
        running = true
        startedAt = Date(); lastAudioAt = nil; previousFrames = 0; lastDiagnosticLogAt = nil
        event(transportOnly ? "Silent transport receiver prepared; no audio session or renderer." : "Receiver prepared; select \(routeName) in Control Center.")
        status = "Select \(routeName) in Control Center"
        let newTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
        tick()
    }

    func stop() {
        wantsRunning = false
        permissionRequest += 1
        preparing = false
        tick()
        stopResources(deactivate: true)
        status = "Stopped. Choose your normal output in Control Center."
        event("Stopped by user.")
    }

    private func stopResources(deactivate: Bool) {
        timer?.invalidate(); timer = nil
        if let renderer { ar_renderer_enable(renderer, false) }
        // Stop and release the graph before freeing pointers captured by its render block.
        engine?.stop(); engine = nil
        if let renderer { ar_renderer_destroy(renderer); self.renderer = nil }
        if let link { ar_link_destroy(link); self.link = nil }
        running = false; connected = false
        if deactivate && !transportOnly {
            do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            catch { event("Audio deactivation failed: \(error.localizedDescription)") }
        }
    }

    private func fail(_ message: String) {
        failure = message
        wantsRunning = false
        stopResources(deactivate: !interrupted)
        status = message
        event(message)
        log.error("\(message, privacy: .public)")
    }

    func enteredBackground() {
        guard transportOnly, running else { return }
        fail("Silent diagnostic stopped in background. Return here, prepare, then open Control Center from this app.")
    }

    private func updateFilter() {
        guard let renderer else { return }
        guard applyConfiguration(renderer) else { fail("Invalid EQ settings."); return }
        event(bypass ? "EQ bypass enabled." : "EQ settings applied.")
    }

    // The production app and the diagnostic share the same session/transport lifecycle.
    // Persist a complete configuration before starting, so no test filter is ever audible.
    func configure(_ next: Configuration) throws {
        if let renderer, !applyConfiguration(renderer, using: next) {
            throw NSError(domain: "Aural.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "The audio engine rejected the EQ configuration."])
        }
        configuration = next
    }

    private func applyConfiguration(_ renderer: OpaquePointer, using value: Configuration? = nil) -> Bool {
        guard var value = value ?? configuration else { return ar_renderer_update(renderer, cutoff, bypass) }
        return ar_renderer_configure(renderer, value.filters, UInt32(value.filters.count), value.preamp,
                                     bypass, &value.stereo, value.bypassGain, value.peakProtection)
    }

    private func physicalOutputIsValid() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        route = outputs.map(\.portName).joined(separator: ", ")
        // Restrict the first test to physical outputs. This also stops a feedback
        // loop if the receiver is accidentally routed back into the extension.
        let supported: Set<AVAudioSession.Port> = [.builtInSpeaker, .headphones, .bluetoothA2DP, .usbAudio]
        return !outputs.isEmpty && outputs.allSatisfy { supported.contains($0.portType) }
    }

    private func outputDescription(_ route: AVAudioSessionRouteDescription) -> String {
        let outputs = route.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }
        return outputs.isEmpty ? "none" : outputs.joined(separator: ", ")
    }

    private func routeChanged(_ raw: UInt?, previous: AVAudioSessionRouteDescription?) {
        guard running else { return }
        guard let raw, let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else {
            fail("Received an unrecognized audio-route change."); return
        }
        let session = AVAudioSession.sharedInstance()
        event("Output route changed (reason \(raw)): \(previous.map(outputDescription) ?? "unknown") → \(outputDescription(session.currentRoute)); hardware=\(session.sampleRate) Hz.")
        if reason == .oldDeviceUnavailable {
            fail("Output disconnected. Reconnect headphones or choose the speaker, then prepare again.")
        } else if !physicalOutputIsValid() {
            fail("Unsupported receiver output. Choose the speaker, wired headphones, USB audio, or Bluetooth stereo headphones, then start again.")
        }
    }

    private func becameInactive(_ context: AVAudioSession.DeactivationContext?) {
        guard running else { return }
        guard let context else { fail("Received a deactivation without context."); return }
        // A delayed notification from our own stop must not interrupt a new run.
        guard context.source != .app else { return }
        event("Audio session deactivated: source=\(context.source.rawValue); interruption=\(context.interruptionContext.map { String($0.reason.rawValue) } ?? "none"); outputs=\(outputDescription(AVAudioSession.sharedInstance().currentRoute)).")
        interrupted = true
        if context.interruptionContext?.reason == .routeDisconnected {
            fail("Output disconnected. Reconnect headphones or choose the speaker, then prepare again.")
            return
        }
        stopResources(deactivate: false)
        status = "Audio interrupted"
        event(status)
    }

    private func resumeRecommended(_ context: AVAudioSession.ResumptionContext?) {
        guard interrupted, wantsRunning else { return }
        guard let context else { fail("Received a resumption recommendation without context."); return }
        event("Audio resumption recommendation: \(context.recommendation.rawValue).")
        interrupted = false
        if context.recommendation == .shouldResume {
            start()
        } else {
            wantsRunning = false
            status = "Interruption ended. Prepare the receiver to resume."
            event(status)
        }
    }

    private func tick() {
        guard running, let link else { return }
        let transport = ar_link_stats(link)
        if connected != transport.connected {
            connected = transport.connected
            event(connected ? "Extension connected." : "Extension disconnected.")
        }
        if transport.transferredFrames > previousFrames {
            lastAudioAt = Date(); previousFrames = transport.transferredFrames
        }
        let silenceSince = lastAudioAt ?? startedAt ?? Date()
        if let idleTimeout, Date().timeIntervalSince(silenceSince) > idleTimeout {
            fail("No audio frames for \(Int(idleTimeout)) seconds. Prepare again when ready to test."); return
        }
        if transportOnly {
            status = transport.connected
                ? (transport.transferredFrames > 0 ? "Receiving frames · intentionally silent" : "Connected · waiting for frames")
                : "Silent diagnostic · waiting for route"
            if transport.connected && (lastDiagnosticLogAt.map { Date().timeIntervalSince($0) >= 1 } ?? true) {
                lastDiagnosticLogAt = Date()
                log.notice("Transport-only: received=\(transport.transferredFrames) connections=\(transport.connections) buffered=\(transport.bufferedFrames) dropped=\(transport.droppedFrames) errno=\(transport.error)")
            }
            diagnostics = """
            Aural transport-only diagnostic
            No AVAudioSession, AVAudioEngine, renderer or EQ
            Device: \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)
            Run started: \(startedAt?.ISO8601Format() ?? "—")
            Transport: float32 stereo, 48000 Hz, loopback TCP
            Received and discarded frames: \(transport.transferredFrames)
            Connections: \(transport.connections)
            Buffered / dropped frames: \(transport.bufferedFrames) / \(transport.droppedFrames)
            Protocol errors: \(transport.protocolErrors)
            Last socket errno: \(transport.error)
            """
            if transport.protocolErrors > 0 || transport.error != 0 {
                fail("Transport-only diagnostic failed. See the diagnostic report.")
            }
            return
        }
        guard let renderer else { fail("Audio renderer is missing from the playback test."); return }
        let audio = ar_renderer_stats(renderer)
        guard physicalOutputIsValid() else { fail("Output changed to an unsupported or looping route."); return }
        inputLevel = decibels(audio.inputPeak); outputLevel = decibels(audio.outputPeak)
        if transport.connected {
            status = audio.inputPeak > 0.00001 ? "Playing · \(bypass ? "EQ bypassed" : "EQ active")" : "Connected · waiting for audio"
        } else { status = "Select \(routeName) in Control Center" }
        let session = AVAudioSession.sharedInstance()
        diagnostics = """
        Aural audio diagnostics
        Build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
        Device: \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)
        Run started: \(startedAt?.ISO8601Format() ?? "—")
        Output: \(route)
        Output ports: \(outputDescription(session.currentRoute))
        Session: \(session.category.rawValue); sharing policy: \(session.routeSharingPolicy.rawValue)
        Transport: float32 stereo, 48000 Hz, loopback TCP
        Hardware rate: \(session.sampleRate) Hz
        Hardware I/O buffer: \(session.ioBufferDuration * 1000) ms
        Reported output latency: \(session.outputLatency * 1000) ms
        Buffer now: \(transport.bufferedFrames) frames (\(Double(transport.bufferedFrames) / 48) ms)
        Preroll target: \(ARPrerollFrames) frames
        DSP look-ahead: \(ar_renderer_latency(renderer)) frames
        End-to-end latency: NOT MEASURED
        Received frames: \(transport.transferredFrames)
        Rendered frames: \(audio.renderedFrames)
        Connections: \(transport.connections)
        Dropped frames: \(transport.droppedFrames)
        Underrun frames: \(transport.underrunFrames)
        Protocol errors: \(transport.protocolErrors)
        Last socket errno: \(transport.error)
        Render format errors: \(audio.formatErrors)
        DSP faults / contained signal faults: \(audio.dspFaults) / \(audio.signalFaults)
        Input / output: \(inputLevel) / \(outputLevel) dBFS
        Limiter reduction: \(audio.reductionDB) dB
        EQ: \(configuration.map { "\($0.filters.count) sections" } ?? "test low-pass \(Int(cutoff)) Hz"); bypass: \(bypass)
        """
        if audio.formatErrors > 0 || audio.dspFaults > 0 || transport.protocolErrors > 0 {
            fail("Audio format or transport validation failed. See the diagnostic report.")
        }
    }

    private func decibels(_ peak: Float) -> String {
        peak > 0 ? String(format: "%.1f", 20 * log10(peak)) : "−∞"
    }
    private func event(_ message: String) {
        log.notice("\(message, privacy: .public)")
        events.append("\(Date().ISO8601Format()) \(message)")
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }
    var report: String { "Status: \(status)\n\n" + diagnostics + "\n\nEvents\n" + events.joined(separator: "\n") }
}
