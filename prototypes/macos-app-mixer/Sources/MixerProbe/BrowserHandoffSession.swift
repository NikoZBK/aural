import CoreAudio
import Foundation
import ProbeCore

struct BrowserEpoch: Encodable {
    let date: Date
    let controls: MixerControls
    let processes: [AudioProcessInfo]
    let phase: UInt32
}
struct BrowserCapture: Encodable {
    let phase: UInt32
    let controls: MixerControls
    let firstSamples: Bool
    let inputRMS: Double?
    let observedGain: Double?
    let normalizedError: Double?
    let peerAmplitude: Double?
    let passed: Bool
}
struct BrowserHandoffReport: Encodable {
    let schemaVersion = 1
    let outcome: String
    let error: String?
    let output: DeviceInfo
    let bundleID: String
    let ownershipPolicy: OwnershipPolicy
    let controls: MixerControls
    let epochs: [BrowserEpoch]
    let events: [RecoveryEvent]
    let captures: [BrowserCapture]
    let totals: RecoveryTotals
    let gates: [Gate]
    let limitations = ["Unknown newcomers wait on this output until classified; existing verified peers keep playing",
                       "Safari ownership uses an explicitly enabled undocumented query; no shared-bundle process restoration is enabled",
                       "First-sample capture begins at the app lane's first nonzero sample; it does not independently establish physical-output continuity",
                       "The diagnostic stops on output loss or an unprovable stream map; it does not change the default output or system volume"]
}

@MainActor func browserHandoffSession(_ options: Options, device: DeviceInfo) throws {
    guard let bundleID = options.values["--bundle"], ["com.apple.Safari", "com.google.Chrome"].contains(bundleID),
          let uid = options.values["--output"], !["builtin", "default"].contains(uid),
          let controlPath = options.values["--control"], let statusPath = options.values["--status"] else {
        throw ProbeFailure(message: "browser-handoff-test requires Safari/Chrome --bundle, exact --output UID, --control and --status paths")
    }
    guard bundleID != "com.apple.Safari" || options.ownershipPolicy == .experimentalResponsibility else {
        throw ProbeFailure(message: "Safari handoff requires the explicit experimental-responsibility ownership policy")
    }
    let duration = try options.number("--duration", default: 180, range: 5...600)
    let minimum = try options.number("--min-restarts", default: 1, range: 1...8)
    guard minimum.rounded() == minimum else { throw ProbeFailure(message: "--min-restarts must be an integer") }
    let mute = options.values["--muted"] ?? "off"
    guard ["on", "off"].contains(mute) else { throw ProbeFailure(message: "--muted must be on or off") }
    var controls = MixerControls(volume: Float(try options.number("--gain", default: 0.25, range: 0...1)), muted: mute == "on")
    try controls.validate()
    let route = ProbeRoute(device: device), deadline = Date().addingTimeInterval(duration)
    var reference: Process?, failure: Error?, finished = false
    var epochs: [BrowserEpoch] = [], events: [RecoveryEvent] = [], captures: [BrowserCapture] = []
    var segments: [(controls: MixerControls, first: Bool, recorded: Bool)] = []
    var totals = RecoveryTotals(), revision: UInt64 = 0, previousData: Data?, lastStatus = Date.distantPast
    var partition: BrowserPartition?, pendingSince: Date?, incompleteSince: Date?
    func event(_ kind: String, _ detail: String) {
        events.append(RecoveryEvent(date: Date(), generation: UInt64(epochs.count), kind: kind, detail: detail))
        fputs("\(kind): \(detail)\n", stderr)
    }
    func beginCapture(_ engine: OpaquePointer, first: Bool) throws -> UInt32 {
        guard segments.count < Int(ProbeMaxPhases) else { throw ProbeFailure(message: "Browser capture capacity exceeded") }
        let phase = UInt32(segments.count)
        let accepted = first ? probe_set_phase_immediate(engine, phase) : probe_set_phase(engine, phase)
        guard accepted else { throw ProbeFailure(message: "Browser capture request rejected") }
        segments.append((controls, first, false))
        return phase
    }
    func collect(_ engine: OpaquePointer) {
        for index in segments.indices where !segments[index].recorded && probe_capture_ready(engine, UInt32(index)) {
            let segment = segments[index], gains: [Float] = [segment.controls.gain, 1, 1, 0]
            let check = probe_render_check(engine, UInt32(index), gains, 4, 0)
            let error = check.valid && check.inputRMS > 0 ? finite(check.errorRMS / check.inputRMS) : nil
            let peer = finite(probe_tone_amplitude(engine, UInt32(index), 1, 0, 997))
            let passed = check.valid && check.inputRMS > 0.0001 &&
                abs(check.observedGain - Double(segment.controls.gain)) < 0.00001 &&
                (error ?? .infinity) < 0.00001 && (peer ?? 0) > 0.0001
            captures.append(BrowserCapture(phase: UInt32(index), controls: segment.controls, firstSamples: segment.first,
                inputRMS: check.valid ? finite(check.inputRMS) : nil,
                observedGain: check.valid ? finite(check.observedGain) : nil,
                normalizedError: error, peerAmplitude: peer, passed: passed))
            segments[index].recorded = true
            event("measurement", "phase=\(index), gain=\(check.observedGain), requested=\(segment.controls.gain), firstSamples=\(segment.first), passed=\(passed)")
        }
    }
    do {
        let before = try playbackPreflight(device: device, playback: .all, ownership: options.ownershipPolicy)
        let initial = appProcesses(before, bundleID: bundleID)
        guard initial.contains(where: { $0.runningOutput && $0.outputDevices.contains(device.id) }),
              initial.allSatisfy({ $0.identityNote == nil && $0.instance != nil }) else {
            throw ProbeFailure(message: "Play the browser directly through the selected physical output before testing")
        }
        reference = try sourceProcess("B", frequency: 997, device: device, duration: duration + 10)
        guard let reference else { throw ProbeFailure(message: "No reference source was created") }
        let peer = try HAL.process(reference.processIdentifier), own = try HAL.process(getpid())
        let catalog = try inventory(ownership: options.ownershipPolicy)
        let first = try BrowserPartition(catalog: catalog, bundleID: bundleID, excluding: [peer, own])
        guard !first.app.isEmpty else { throw ProbeFailure(message: "Browser helpers disappeared during preparation") }
        try route.prepare(apps: [first.app.map(\.object), [peer]], playback: .all,
                          passthrough: first.passthrough.map(\.object))
        guard let engine = route.engine, probe_prime_gain(engine, 0, controls.gain), probe_capture_on_signal(engine, 0) else {
            throw ProbeFailure(message: "Cannot prime retained browser gain and first-sample capture")
        }
        partition = first
        let phase = try beginCapture(engine, first: true)
        try route.start()
        epochs.append(BrowserEpoch(date: Date(), controls: controls, processes: first.app, phase: phase))
        event("running", "Selected-output newcomer quarantine active; volume=\(controls.volume), muted=\(controls.muted)")
        repeat {
            let current = try DeviceInfo.selected(device.uid)
            guard current.id == device.id, current.rate == device.rate else { throw ProbeFailure(message: "Selected output changed during browser handoff") }
            try route.validateStreamMap()
            guard reference.isRunning else { throw ProbeFailure(message: "Reference source exited unexpectedly") }
            let counters = probe_counters(engine)
            guard counters.invalidBuffers == 0, counters.nonfiniteSamples == 0 else { throw ProbeFailure(message: "Browser callback buffer fault") }
            collect(engine)
            // Only missing control files are normal; malformed or unreadable files fail visibly.
            var data: Data?
            do { data = try Data(contentsOf: URL(fileURLWithPath: controlPath)) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { data = nil }
            if let data, data != previousData {
                guard data.count <= 16384 else { throw ProbeFailure(message: "Browser control file is too large") }
                let command = try JSONDecoder().decode(RecoveryControl.self, from: data)
                try MixerControls(volume: command.volume, muted: command.muted).validate()
                previousData = data
                if command.revision > revision {
                    revision = command.revision
                    if !command.enabled || command.finish { finished = true; event("stop", "Stop/Finish requested") }
                    else {
                        let desired = MixerControls(volume: command.volume, muted: command.muted)
                        if desired != controls {
                            controls = desired
                            guard probe_set_gain(engine, 0, controls.gain) else { throw ProbeFailure(message: "Browser controls rejected") }
                            _ = try beginCapture(engine, first: false)
                            event("controls", "volume=\(controls.volume), muted=\(controls.muted)")
                        }
                    }
                } else { event("stale-control", "Ignored control revision \(command.revision)") }
            }
            if finished { break }
            let nextCatalog = try inventory(ownership: options.ownershipPolicy)
            try validatePlaybackConflicts(nextCatalog, device: device)
            if !nextCatalog.issues.isEmpty {
                // Freeze newcomers until the next complete snapshot; no uncertain
                // object is added to either replay lane from an incomplete list.
                if incompleteSince == nil { incompleteSince = Date(); event("catalog-retry", "Process catalog changed while reading; retaining the guarded route") }
                guard Date().timeIntervalSince(incompleteSince ?? .distantPast) < 2 else {
                    throw ProbeFailure(message: "Process catalog remained incomplete for two seconds")
                }
            } else {
                incompleteSince = nil
                let next = try BrowserPartition(catalog: nextCatalog, bundleID: bundleID, excluding: [peer, own])
                let appChanged = !sameBrowserBindings(partition?.app ?? [], next.app)
                let otherChanged = !sameBrowserBindings(partition?.passthrough ?? [], next.passthrough)
                if appChanged || otherChanged {
                    try route.rebindBrowser(first: next.app.map(\.object), passthrough: next.passthrough.map(\.object), replaceFirst: appChanged) {
                        if !next.app.isEmpty {
                            let phase = try beginCapture(engine, first: true)
                            epochs.append(BrowserEpoch(date: Date(), controls: controls, processes: next.app, phase: phase))
                        }
                    }
                    if appChanged { event(next.app.isEmpty ? "waiting-helper" : "helper-bound", "Verified app processes=\(next.app.count); saved gain=\(controls.gain)") }
                }
                partition = next
                let unresolved = next.pending.contains { $0.runningOutput && $0.outputDevices.contains(device.id) }
                if unresolved {
                    if pendingSince == nil { pendingSince = Date(); event("waiting-identity", "Unresolved newcomer held out of replay") }
                    guard Date().timeIntervalSince(pendingSince ?? .distantPast) < 5 else {
                        throw ProbeFailure(message: "A playing newcomer could not be attributed within five seconds")
                    }
                } else { pendingSince = nil }
            }
            if Date().timeIntervalSince(lastStatus) >= 0.5 {
                struct Status: Encodable {
                    let running: Bool; let revision: UInt64; let controls: MixerControls
                    let epochs: Int; let app: [AudioProcessInfo]; let pending: [AudioProcessInfo]; let captures: [BrowserCapture]
                }
                try writeJSON(Status(running: true, revision: revision, controls: controls, epochs: epochs.count,
                                     app: partition?.app ?? [], pending: partition?.pending ?? [], captures: captures), to: statusPath)
                lastStatus = Date()
            }
            wait(0.05)
        } while Date() < deadline
    } catch { failure = error }
    do { try route.suspend() } catch { failure = ProbeFailure(message: (failure.map { $0.localizedDescription + " Cleanup: " } ?? "") + error.localizedDescription) }
    if let engine = route.engine {
        collect(engine)
        let counters = probe_counters(engine)
        totals.frames = counters.frames; totals.invalidBuffers = counters.invalidBuffers; totals.nonfiniteSamples = counters.nonfiniteSamples
        totals.maximumCallbackMicroseconds = Double(counters.maximumCallbackNanoseconds) / 1000
    }
    do { try route.stop() } catch { failure = ProbeFailure(message: (failure.map { $0.localizedDescription + " Cleanup: " } ?? "") + error.localizedDescription) }
    if let reference { if reference.isRunning { reference.terminate() }; reference.waitUntilExit() }
    let gates = [
        Gate(name: "Live helper replacement", passed: epochs.count >= Int(minimum) + 1, detail: "Required \(Int(minimum)) replacement groups; observed \(max(0, epochs.count - 1)) on the same running route"),
        Gate(name: "Retained first-sample controls", passed: !epochs.isEmpty && epochs.allSatisfy { epoch in captures.contains { $0.phase == epoch.phase && $0.firstSamples && $0.passed } }, detail: "Each bound group has a complete capture beginning at its first nonzero app-lane sample with saved controls"),
        Gate(name: "Measured controls", passed: !captures.isEmpty && captures.allSatisfy(\.passed), detail: "All completed captures match saved gain/mute with the independent peer unchanged"),
        Gate(name: "Callback buffers", passed: totals.frames > 0 && totals.invalidBuffers == 0 && totals.nonfiniteSamples == 0, detail: "No malformed buffers or nonfinite samples")]
    if failure == nil, gates.contains(where: { !$0.passed }) { failure = ProbeFailure(message: "A browser handoff gate failed; inspect the report") }
    let report = BrowserHandoffReport(outcome: failure == nil ? "passed" : "failed", error: failure?.localizedDescription,
        output: device, bundleID: bundleID, ownershipPolicy: options.ownershipPolicy, controls: controls,
        epochs: epochs, events: events, captures: captures, totals: totals, gates: gates)
    try writeJSON(report, to: options.values["--report"])
    try writeJSON(report, to: statusPath)
    if let failure { throw failure }
}
