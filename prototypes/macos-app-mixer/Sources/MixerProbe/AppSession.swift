import CoreAudio
import Foundation
import ProbeCore

struct AppPhase: Encodable {
    let name: String
    let requestedGain: Float
    let capturedFrames: UInt32
    let inputRMS: Double?
    let outputRMS: Double?
    let observedGain: Double?
    let normalizedRenderError: Double?
    let relativeUnityError: Double?
    let referenceToneAmplitude: Double?
}
struct AppMeasurements: Encodable {
    let initialAppProcesses: [AudioProcessInfo]
    let finalAppProcesses: [AudioProcessInfo]
    let inventoryIssues: [InventoryIssue]
    let referenceProcess: AudioProcessInfo
    let lanes: [Lane]
    let phases: [AppPhase]
    let callbacks: UInt64
    let frames: UInt64
    let invalidBuffers: UInt64
    let nonfiniteSamples: UInt64
    let maximumCallbackMicroseconds: Double
    let gates: [Gate]
}
struct AppReport: Encodable {
    let schemaVersion = 2
    let date: Date
    let outcome: String
    let bundleID: String
    let playback: String
    let output: DeviceInfo
    let measurements: AppMeasurements?
    let error: String?
    let ownershipPolicy: OwnershipPolicy
    let initialProcessGroup: [AudioProcessInfo]
    let latestProcessGroup: [AudioProcessInfo]
    let limitations = ["Rendered samples do not independently establish physical output or absence of a direct playback path",
                       "Only the recorded app processes, output, and time windows are represented",
                       "No audio recordings are saved; sample captures exist only in RAM"]
}

@MainActor private func waitForHealthyRoute(_ route: ProbeRoute, engine: OpaquePointer, seconds: Double,
    bundleID: String, expected: [AudioProcessInfo], ownership: OwnershipPolicy,
    observe: ([AudioProcessInfo]) -> Void) throws {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        let current = try DeviceInfo.selected(route.device.uid)
        guard current.id == route.device.id, current.rate == route.device.rate else {
            throw ProbeFailure(message: "The selected output changed identity or sample rate during the test")
        }
        try route.validateStreamMap()
        let catalog = try inventory(ownership: ownership)
        let group = appProcesses(catalog, bundleID: bundleID)
        observe(group)
        guard catalog.issues.isEmpty, sameAppProcessIdentities(expected, group) else {
            throw ProbeFailure(message: "App/helper ownership changed during playback; diagnostic stopped before applying further controls to stale identities")
        }
        let counters = probe_counters(engine)
        guard counters.invalidBuffers == 0, counters.nonfiniteSamples == 0 else {
            throw ProbeFailure(message: "Audio callback reported invalid buffers or nonfinite samples; stopping the test")
        }
        wait(min(0.25, max(0, deadline.timeIntervalSinceNow)))
    } while Date() < deadline
}

@MainActor func realAppSession(_ options: Options, device: DeviceInfo) throws {
    guard let bundleID = options.values["--bundle"], !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else {
        throw ProbeFailure(message: "app-test requires the exact application --bundle identifier, excluding the probe")
    }
    guard let playback = Playback(rawValue: options.values["--playback"] ?? "owned") else { throw ProbeFailure(message: "Invalid playback mode") }
    let phaseSeconds = try options.number("--phase-seconds", default: 8, range: 2...20)
    let route = ProbeRoute(device: device)
    var reference: Process?, measurements: AppMeasurements?, failure: Error?
    var initialGroup: [AudioProcessInfo] = [], latestGroup: [AudioProcessInfo] = []
    do {
        let before = try playbackPreflight(device: device, playback: playback, ownership: options.ownershipPolicy)
        let group = appProcesses(before, bundleID: bundleID)
        initialGroup = group; latestGroup = group
        guard !group.isEmpty, group.allSatisfy({ $0.identityNote == nil }) else {
            throw ProbeFailure(message: "Cannot establish the requested app's process identities")
        }
        guard group.contains(where: { $0.runningOutput && $0.outputDevices.contains(device.id) }) else {
            throw ProbeFailure(message: "Play the requested app directly through the selected physical output before testing; no matching active stream was found")
        }
        let child = try sourceProcess("B", frequency: 997, device: device, duration: phaseSeconds * 5 + 15)
        reference = child
        let peer = try AudioProcessInfo.read(HAL.process(child.processIdentifier))
        try route.prepare(apps: [group.map(\.object), [peer.object]], playback: playback)
        let topology = route.lanes
        try route.start()
        guard let engine = route.engine else { throw ProbeFailure(message: "Missing prepared engine") }
        let steps: [(String, Float)] = [("Music at 100%", 1), ("Music at 50%", 0.5), ("Music at 25%", 0.25),
                                      ("Music muted; reference tone remains", 0), ("Music restored to 100%", 1)]
        for (index, step) in steps.enumerated() {
            guard child.isRunning else { throw ProbeFailure(message: "The independent reference source stopped unexpectedly") }
            guard probe_set_gain(engine, 0, step.1), probe_set_phase(engine, UInt32(index)) else {
                throw ProbeFailure(message: "Engine rejected real-app controls")
            }
            fputs("\(step.0) — \(phaseSeconds) seconds\(playback == .monitor ? " (monitor only; direct playback unchanged)" : "")\n", stderr)
            try waitForHealthyRoute(route, engine: engine, seconds: phaseSeconds, bundleID: bundleID,
                                    expected: group, ownership: options.ownershipPolicy) { latestGroup = $0 }
        }
        try route.suspend()
        let after = try inventory(ownership: options.ownershipPolicy), finalGroup = appProcesses(after, bundleID: bundleID)
        latestGroup = finalGroup
        let counters = probe_counters(engine)
        let phases = steps.enumerated().map { index, step -> AppPhase in
            let gains: [Float] = playback == .monitor ? [0, 0, 0, 0] : [step.1, 1, playback == .all ? 1 : 0, 0]
            let check = probe_render_check(engine, UInt32(index), gains, UInt32(gains.count), 0)
            let left = probe_rms(engine, UInt32(index), 3, 0), right = probe_rms(engine, UInt32(index), 3, 1)
            let referenceRMS = sqrt((left * left + right * right) / 2)
            return AppPhase(name: step.0, requestedGain: step.1, capturedFrames: probe_capture_count(engine, UInt32(index)),
                            inputRMS: check.valid ? finite(check.inputRMS) : nil,
                            outputRMS: check.valid ? finite(check.outputRMS) : nil,
                            observedGain: check.valid ? finite(check.observedGain) : nil,
                            normalizedRenderError: check.valid && check.inputRMS > 0 ? finite(check.errorRMS / check.inputRMS) : nil,
                            relativeUnityError: referenceRMS > 0 ? finite(probe_unity_error(engine, UInt32(index), 7, 3, 0) / referenceRMS) : nil,
                            referenceToneAmplitude: finite(probe_tone_amplitude(engine, UInt32(index), 1, 0, 997)))
        }
        var gates = [
            Gate(name: "Real-app capture", passed: phases.allSatisfy { $0.capturedFrames >= 16000 && ($0.inputRMS ?? 0) > 0.0001 },
                 detail: "Audible app samples in every settled capture window"),
            Gate(name: "Stable app ownership", passed: after.issues.isEmpty && sameAppProcessIdentities(group, finalGroup),
                 detail: "The verified app/helper identities remain stable across this test; churn requires a separate ownership test"),
            Gate(name: "Callback buffers", passed: counters.frames > 0 && counters.invalidBuffers == 0 && counters.nonfiniteSamples == 0,
                 detail: "Callbacks render without malformed buffers or nonfinite samples"),
            Gate(name: "Unity reconstruction", passed: phases.allSatisfy { ($0.relativeUnityError ?? .infinity) < 0.001 },
                 detail: "Same-frame sum of app + reference source + remaining audio matches the unmuted reference"),
            Gate(name: "Independent reference", passed: phases.allSatisfy { ($0.referenceToneAmplitude ?? 0) > 0.0001 },
                 detail: "The separate diagnostic process remains observable during all app levels")]
        if playback != .monitor {
            gates.append(Gate(name: "Same-sample attenuation and mute", passed: phases.allSatisfy {
                abs(($0.observedGain ?? .infinity) - Double($0.requestedGain)) < ($0.requestedGain == 0 ? 0.00001 : 0.005) &&
                    ($0.normalizedRenderError ?? .infinity) < 0.00001
            }, detail: "Rendered output matches the requested app gain plus unchanged peers using exactly the same input samples"))
        }
        measurements = AppMeasurements(initialAppProcesses: group, finalAppProcesses: finalGroup, inventoryIssues: before.issues + after.issues,
            referenceProcess: peer, lanes: topology, phases: phases, callbacks: counters.callbacks, frames: counters.frames,
            invalidBuffers: counters.invalidBuffers, nonfiniteSamples: counters.nonfiniteSamples,
            maximumCallbackMicroseconds: Double(counters.maximumCallbackNanoseconds) / 1000, gates: gates)
        if gates.contains(where: { !$0.passed }) { throw ProbeFailure(message: "One or more real-app routing gates failed; inspect the report") }
    } catch { failure = error }
    do { try route.stop() } catch {
        failure = ProbeFailure(message: (failure.map { $0.localizedDescription + " Cleanup: " } ?? "") + error.localizedDescription)
    }
    if let reference {
        if reference.isRunning { reference.terminate() }
        reference.waitUntilExit()
    }
    let report = AppReport(date: Date(), outcome: failure == nil ? "passed" : "failed", bundleID: bundleID, playback: playback.rawValue,
                           output: device, measurements: measurements, error: failure?.localizedDescription,
                           ownershipPolicy: options.ownershipPolicy, initialProcessGroup: initialGroup, latestProcessGroup: latestGroup)
    do { try writeJSON(report, to: options.values["--report"]) } catch {
        throw ProbeFailure(message: (failure.map { $0.localizedDescription + " Report: " } ?? "") + error.localizedDescription)
    }
    if let failure { throw failure }
}
