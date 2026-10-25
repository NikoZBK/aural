import CoreAudio
import Foundation
import ProbeCore

struct RecoveryControl: Codable {
    let revision: UInt64
    let enabled: Bool
    let volume: Float
    let muted: Bool
    let finish: Bool
}
struct RecoveryEvent: Encodable {
    let date: Date
    let generation: UInt64
    let kind: String
    let detail: String
}
struct RecoveryCapture: Encodable {
    let generation: UInt64
    let phase: UInt32
    let controls: MixerControls
    let frames: UInt32
    let inputRMS: Double?
    let observedGain: Double?
    let normalizedError: Double?
    let passed: Bool
}
struct RecoveryEpoch: Encodable {
    let generation: UInt64
    let startedAt: Date
    let output: DeviceInfo
    let appProcesses: [AudioProcessInfo]
    let aggregate: AudioObjectID
}
struct RecoveryTotals: Encodable {
    var frames: UInt64 = 0
    var invalidBuffers: UInt64 = 0
    var nonfiniteSamples: UInt64 = 0
    var maximumCallbackMicroseconds: Double = 0
}
struct RecoverySnapshot: Encodable {
    let phase: MixerRecoveryState.Phase
    let generation: UInt64
    let revision: UInt64
    let controls: MixerControls
    let successfulStarts: Int
    let disconnects: Int
    let notice: String
    let holdingMuteTaps: Int
    let guardReaders: [StandbyGuardMeasurements]
    let lastCapture: RecoveryCapture?
}
struct RecoveryReport: Encodable {
    let outcome: String
    let error: String?
    let finalState: RecoverySnapshot
    let events: [RecoveryEvent]
    let epochs: [RecoveryEpoch]
    let captures: [RecoveryCapture]
    let totals: RecoveryTotals
    let gates: [Gate]
    let guardReaders: [StandbyGuardMeasurements]
    let limitations = ["Only completed, immutable capture windows are analyzed; no PCM files are written",
                       "A passed settled capture cannot establish mute continuity during disconnect/reconnect; hardware listening or loopback is a separate gate",
                       "This diagnostic uses Aural's recovery policy but is not installed into the production mixer",
                       "Recovery rebuilds only the saved output; it does not change the macOS default or control Spotify transport"]
}

@MainActor final class RecoveringMixer {
    private(set) var state: MixerRecoveryState
    private(set) var events: [RecoveryEvent] = []
    private(set) var epochs: [RecoveryEpoch] = []
    private(set) var captures: [RecoveryCapture] = []
    private(set) var totals = RecoveryTotals()
    private(set) var disconnects = 0
    private(set) var finishRequested = false
    private(set) var revision: UInt64 = 0
    private var desiredEnabled = true
    private var notice = "Waiting for the saved output"
    private var lastAvailability: String?
    private var lastControlData: Data?
    private var lastStatus: Date = .distantPast
    private var holdingGuards: [StandbyMuteGuard] = []
    private(set) var guardHistory: [StandbyGuardMeasurements] = []
    private var holdingBinding: StandbyMuteBinding?
    private var route: ProbeRoute?
    private var reference: Process?
    private var activeGeneration: UInt64?
    private var accounted = RecoveryTotals()
    private var segments: [(controls: MixerControls, recorded: Bool)] = []
    private let bundleID: String
    private let controlURL: URL
    private let statusPath: String
    private let deadline: Date

    init(uid: String, bundleID: String, controls: MixerControls, controlPath: String, statusPath: String, deadline: Date) throws {
        state = try MixerRecoveryState(outputUID: uid, outputName: "the saved output", controls: controls)
        self.bundleID = bundleID; controlURL = URL(fileURLWithPath: controlPath); self.statusPath = statusPath; self.deadline = deadline
        state.start(now: Date())
    }
    var snapshot: RecoverySnapshot {
        RecoverySnapshot(phase: state.phase, generation: state.generation, revision: revision, controls: state.controls,
                         successfulStarts: epochs.count, disconnects: disconnects, notice: state.error ?? notice,
                         holdingMuteTaps: holdingGuards.filter { $0.tap != 0 }.count,
                         guardReaders: holdingGuards.map(\.measurements), lastCapture: captures.last)
    }
    private func event(_ kind: String, _ detail: String) {
        events.append(RecoveryEvent(date: Date(), generation: state.generation, kind: kind, detail: detail))
        fputs("\(kind): \(detail)\n", stderr)
    }
    func publish(force: Bool = false) throws {
        if force || Date().timeIntervalSince(lastStatus) >= 1 {
            try writeJSON(snapshot, to: statusPath); lastStatus = Date()
        }
    }
    private func collectCaptures() throws {
        guard let route, let engine = route.engine, let activeGeneration else { return }
        for index in segments.indices where !segments[index].recorded && probe_capture_ready(engine, UInt32(index)) {
            let controls = segments[index].controls
            let gains: [Float] = [controls.gain, 1, 1, 0]
            let check = probe_render_check(engine, UInt32(index), gains, UInt32(gains.count), 0)
            let error = check.valid && check.inputRMS > 0 ? finite(check.errorRMS / check.inputRMS) : nil
            let observed = check.valid ? finite(check.observedGain) : nil
            let passed = check.valid && check.inputRMS > 0.0001 && abs(check.observedGain - Double(controls.gain)) < 0.00001 && (error ?? .infinity) < 0.00001
            captures.append(RecoveryCapture(generation: activeGeneration, phase: UInt32(index), controls: controls,
                frames: probe_capture_count(engine, UInt32(index)), inputRMS: check.valid ? finite(check.inputRMS) : nil,
                observedGain: observed, normalizedError: error, passed: passed))
            segments[index].recorded = true
            event("measurement", "gain=\(observed.map(String.init(describing:)) ?? "no app samples"), requested=\(controls.gain), valid=\(passed)")
        }
    }
    // Keep the old guard until its replacement exists. A surviving tap object
    // may still target the previous hardware instance, so rebind for every new
    // output/recovery generation even when the app's process objects are stable.
    private func retainMuteGuard(group: [AudioObjectID], device: DeviceInfo) throws {
        let binding = StandbyMuteBinding(generation: state.generation, outputObject: device.id,
                                        outputUID: device.uid, processes: group)
        if holdingBinding == binding, holdingGuards.count == 1 {
            try holdingGuards[0].validate()
            return
        }
        let next = StandbyMuteGuard(binding: binding)
        holdingGuards.append(next) // Own partial setup before any throwing HAL call.
        try next.start(device: device)
        let previous = holdingGuards.dropLast()
        var pending: [StandbyMuteGuard] = [], failures: [String] = []
        for old in previous {
            let measurements = old.measurements
            do { try old.stop() } catch { failures.append(error.localizedDescription) }
            if old.hasResources { pending.append(old) }
            else { guardHistory.append(measurements) }
        }
        holdingGuards = pending + [next]; holdingBinding = binding
        event("guard-created", "Input-only selected-output guard reader armed on object \(device.id), generation \(state.generation), frames=\(next.measurements.frames)")
        if !failures.isEmpty { throw ProbeFailure(message: failures.joined(separator: "; ")) }
    }
    private func verifiedAppGroup(device: DeviceInfo) throws -> [AudioProcessInfo] {
        let catalog = try playbackPreflight(device: device, playback: .all)
        let group = appProcesses(catalog, bundleID: bundleID)
        guard !group.isEmpty, group.allSatisfy({ $0.identityNote == nil }) else {
            throw ProbeFailure(message: "Cannot protect the saved output without verified app process identities")
        }
        return group
    }
    private func releaseMuteGuards() throws {
        var pending: [StandbyMuteGuard] = [], failures: [String] = []
        for owner in holdingGuards {
            let measurements = owner.measurements
            do { try owner.stop() } catch { failures.append(error.localizedDescription) }
            if owner.hasResources { pending.append(owner) }
            else { guardHistory.append(measurements) }
        }
        holdingGuards = pending
        if pending.isEmpty { holdingBinding = nil; event("guard-released", "Standby mute released") }
        if !failures.isEmpty { throw ProbeFailure(message: failures.joined(separator: "; ")) }
    }
    // All release attempts happen before another route can be allocated. A real
    // cleanup error is terminal; uncertain callback memory remains owned by route.
    func teardown(releaseHold: Bool = false) throws {
        var failures: [String] = []
        if let route {
            do { try route.suspend() } catch { failures.append(error.localizedDescription) }
            do { try collectCaptures() } catch { failures.append(error.localizedDescription) }
            if let engine = route.engine {
                let count = probe_counters(engine)
                if count.frames < accounted.frames || count.invalidBuffers < accounted.invalidBuffers || count.nonfiniteSamples < accounted.nonfiniteSamples {
                    failures.append("Callback counters moved backwards during teardown")
                } else {
                    totals.frames += count.frames - accounted.frames
                    totals.invalidBuffers += count.invalidBuffers - accounted.invalidBuffers
                    totals.nonfiniteSamples += count.nonfiniteSamples - accounted.nonfiniteSamples
                    accounted.frames = count.frames; accounted.invalidBuffers = count.invalidBuffers; accounted.nonfiniteSamples = count.nonfiniteSamples
                }
                totals.maximumCallbackMicroseconds = max(totals.maximumCallbackMicroseconds, Double(count.maximumCallbackNanoseconds) / 1000)
            }
            do { try route.stop() } catch { failures.append(error.localizedDescription) }
            if !route.hasResources { self.route = nil; activeGeneration = nil; accounted = RecoveryTotals() }
        }
        if let reference {
            if reference.isRunning { reference.terminate() }
            reference.waitUntilExit(); self.reference = nil
        }
        segments = []
        if releaseHold { do { try releaseMuteGuards() } catch { failures.append(error.localizedDescription) } }
        if !failures.isEmpty { throw ProbeFailure(message: failures.joined(separator: "; ")) }
    }
    private func readControl() throws {
        let data: Data
        do { data = try Data(contentsOf: controlURL) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return }
        guard data.count <= 16384 else { throw ProbeFailure(message: "Recovery control file is too large") }
        guard data != lastControlData else { return }
        let desired = try JSONDecoder().decode(RecoveryControl.self, from: data)
        let controls = MixerControls(volume: desired.volume, muted: desired.muted); try controls.validate()
        lastControlData = data
        guard desired.revision > revision else {
            event("stale-control", "Ignoring revision \(desired.revision); current revision is \(revision)")
            return
        }
        revision = desired.revision
        let changed = controls != state.controls
        try state.setControls(controls)
        if desired.finish || !desired.enabled {
            desiredEnabled = false; state.stop(); try teardown(releaseHold: true)
            notice = desired.finish ? "Test finished" : "Stopped; reconnect will not resume processing"
            finishRequested = desired.finish; event("stop", notice)
        } else if !desiredEnabled {
            desiredEnabled = true; state.start(now: Date()); notice = "Waiting for the saved output"; event("start-request", notice)
        } else if changed, state.phase == .running, let engine = route?.engine {
            guard segments.count < Int(ProbeMaxPhases) else { throw ProbeFailure(message: "Diagnostic capture-phase capacity exceeded") }
            guard probe_set_gain(engine, 0, controls.gain), probe_set_phase(engine, UInt32(segments.count)) else {
                throw ProbeFailure(message: "The mixer rejected updated controls")
            }
            segments.append((controls, false)); event("controls", "volume=\(controls.volume), muted=\(controls.muted)")
        } else if changed { event("saved-controls", "volume=\(controls.volume), muted=\(controls.muted), state=\(state.phase.rawValue)") }
        try publish(force: true)
    }
    private func begin(_ device: DeviceInfo, token: UInt64) throws {
        guard epochs.count < 16 else { throw ProbeFailure(message: "Diagnostic route-generation capacity exceeded") }
        do {
            let group = try verifiedAppGroup(device: device)
            try retainMuteGuard(group: group.map(\.object), device: device)
            reference = try sourceProcess("B", frequency: 997, device: device, duration: max(5, deadline.timeIntervalSinceNow + 10))
            guard let reference else { throw ProbeFailure(message: "No reference source was created") }
            let peer = try HAL.process(reference.processIdentifier)
            let next = ProbeRoute(device: device); route = next
            try next.prepare(apps: [group.map(\.object), [peer]], playback: .all)
            // Stop or newer controls can arrive while HAL is preparing. Reject a
            // cancelled generation before IO begins; prime the latest saved gain.
            try readControl()
            guard state.accepts(token) else { try teardown(); event("cancelled-start", "Discarded stale generation \(token)"); return }
            guard let engine = next.engine, probe_prime_gain(engine, 0, state.controls.gain), probe_capture_on_signal(engine, 0) else { throw ProbeFailure(message: "Cannot restore the initial app gain") }
            activeGeneration = token; accounted = RecoveryTotals()
            segments = [(state.controls, false)]
            try next.start()
            guard state.started(token) else { try teardown(); event("cancelled-start", "Discarded stale generation \(token)"); return }
            epochs.append(RecoveryEpoch(generation: token, startedAt: Date(), output: device, appProcesses: group, aggregate: next.aggregate))
            notice = "Processing on \(device.name)"; event(epochs.count == 1 ? "running" : "resumed", "\(device.name), gain=\(state.controls.gain)")
            try publish(force: true)
        } catch {
            let original = error
            do { try teardown() } catch { throw ProbeFailure(message: original.localizedDescription + " Cleanup: " + error.localizedDescription) }
            guard state.accepts(token) else { throw original }
            let retryable = (original as? HALFailure).map { $0.status != kAudioDevicePermissionsError } ?? false
            state.startFailed(token, retryable: retryable, reason: original.localizedDescription, now: Date())
            event(state.phase == .waiting ? "retry" : "error", original.localizedDescription)
        }
    }
    func tick() throws {
        try readControl()
        guard !finishRequested, state.phase != .stopped else { try publish(); return }
        if state.phase == .failed { throw ProbeFailure(message: state.error ?? "Recovery failed") }
        let readiness = try readOutputReadiness(uid: state.outputUID)
        switch readiness {
        case .waiting(let reason):
            if state.phase == .running || state.phase == .starting {
                try teardown(); disconnects += 1; state.lostOutput(now: Date()); event("disconnected", reason)
            }
            _ = state.nextStart(availableUIDs: [], now: Date())
            if reason != lastAvailability { event("waiting", reason); lastAvailability = reason }
            notice = "Waiting for the saved output: " + reason
        case .ready(let device):
            lastAvailability = nil
            if state.phase == .running, let current = route {
                if current.device.id != device.id || current.device.rate != device.rate {
                    try teardown()
                    guard state.formatChanged(now: Date()) else { throw ProbeFailure(message: state.error ?? "Route restart limit exceeded") }
                    event("format-change", "Rebuilding the saved output at \(device.rate) Hz")
                } else {
                    do { try current.validateStreamMap() } catch {
                        let reason = error.localizedDescription; try teardown()
                        guard state.formatChanged(now: Date()) else { throw ProbeFailure(message: reason) }
                        event("stream-change", reason)
                    }
                }
                if let engine = route?.engine {
                    let count = probe_counters(engine)
                    guard count.invalidBuffers == 0 && count.nonfiniteSamples == 0 else { throw ProbeFailure(message: "Callback fault during recovery; processing stopped") }
                    guard reference?.isRunning == true else { throw ProbeFailure(message: "Reference source exited unexpectedly") }
                    try collectCaptures()
                }
            }
            if state.phase == .waiting,
               holdingGuards.count != 1 || holdingBinding?.targets(generation: state.generation, outputObject: device.id, outputUID: device.uid) != true {
                // Protect the new endpoint on its first readable snapshot. The
                // route's one-second readiness delay must not delay this guard.
                // A failed guard is an explicit terminal error, never a claim
                // that saved mute is applied while dry playback is exposed.
                let group = try verifiedAppGroup(device: device)
                try retainMuteGuard(group: group.map(\.object), device: device)
                try readControl()
            }
            if let token = state.nextStart(availableUIDs: [device.uid], now: Date()) { try begin(device, token: token) }
        }
        try publish()
    }
    func finish(error: Error?) throws {
        if let error { state.fail(error.localizedDescription); event("error", error.localizedDescription) }
        else { state.stop(); notice = "Test finished" }
        do { try teardown(releaseHold: true) } catch { state.fail(error.localizedDescription); event("cleanup-error", error.localizedDescription); throw error }
        try publish(force: true)
    }
}

@MainActor func recoverySession(_ options: Options) throws {
    guard let uid = options.values["--output"], !uid.isEmpty, !["default", "builtin"].contains(uid),
          let bundle = options.values["--bundle"], !bundle.isEmpty, bundle != Bundle.main.bundleIdentifier,
          let control = options.values["--control"], let status = options.values["--status"] else {
        throw ProbeFailure(message: "recover-test requires an exact --output UID, --bundle, --control path and --status path")
    }
    let duration = try options.number("--duration", default: 300, range: 3...600)
    let gain = Float(try options.number("--gain", default: 0.5, range: 0...1))
    let mute = options.values["--muted"] ?? "off"
    guard ["on", "off"].contains(mute) else { throw ProbeFailure(message: "--muted must be on or off") }
    let required = try options.number("--min-reconnects", default: 1, range: 0...8)
    guard required.rounded() == required else { throw ProbeFailure(message: "--min-reconnects must be an integer") }
    let deadline = Date().addingTimeInterval(duration)
    let owner = try RecoveringMixer(uid: uid, bundleID: bundle, controls: MixerControls(volume: gain, muted: mute == "on"),
                                    controlPath: control, statusPath: status, deadline: deadline)
    var failure: Error?
    do {
        repeat { try owner.tick(); wait(0.1) } while !owner.finishRequested && Date() < deadline
        if owner.state.phase == .waiting { throw ProbeFailure(message: "Diagnostic duration ended while waiting for the saved output") }
    } catch { failure = error }
    do { try owner.finish(error: failure) } catch { failure = ProbeFailure(message: (failure.map { $0.localizedDescription + " Cleanup: " } ?? "") + error.localizedDescription) }
    let gates = [
        Gate(name: "Automatic recovery", passed: owner.epochs.count >= Int(required) + 1 && owner.disconnects >= Int(required) && !owner.events.contains(where: { $0.kind == "start-request" }), detail: "Required \(Int(required)) reconnects; observed \(owner.disconnects), without a new Start command"),
        Gate(name: "Settled controls", passed: owner.epochs.allSatisfy { epoch in owner.captures.contains { $0.generation == epoch.generation && $0.passed } }, detail: "Every started route has a completed same-sample gain/mute measurement; transition continuity requires a separate hardware check"),
        Gate(name: "Standby reader activity", passed: !owner.guardHistory.isEmpty && owner.guardHistory.allSatisfy { $0.readerEnabled && $0.frames > 0 && $0.invalidBuffers == 0 }, detail: "Every retained selected-output guard delivered input frames without buffer faults; listening still establishes audible continuity"),
        Gate(name: "Callback faults", passed: owner.totals.frames > 0 && owner.totals.invalidBuffers == 0 && owner.totals.nonfiniteSamples == 0, detail: "No malformed buffers or nonfinite samples across route generations")]
    if failure == nil, gates.contains(where: { !$0.passed }) { failure = ProbeFailure(message: "A recovery measurement gate failed; inspect the report") }
    let report = RecoveryReport(outcome: failure == nil ? "passed" : "failed", error: failure?.localizedDescription, finalState: owner.snapshot,
                                events: owner.events, epochs: owner.epochs, captures: owner.captures, totals: owner.totals,
                                gates: gates, guardReaders: owner.guardHistory)
    try writeJSON(report, to: options.values["--report"])
    if let failure { throw failure }
}
