import CoreAudio
import Foundation
import ProbeCore

// Test the discovery gap deliberately: C starts after the route and is absent
// from both replay lists until assigned. The guarded reference must see C while
// the rendered mix excludes it. This avoids mistaking fast discovery for safety.
@MainActor func quarantineSession(_ options: Options, device: DeviceInfo) throws {
    let route = ProbeRoute(device: device)
    var children: [Process] = [], failure: Error?, gates: [Gate] = []
    var heldInput: Double?, heldOutput: Double?, assignedGain: Double?, assignedError: Double?
    do {
        _ = try playbackPreflight(device: device, playback: .all)
        for (suffix, frequency) in [("A", 431.0), ("B", 997.0)] {
            children.append(try sourceProcess(suffix, frequency: frequency, device: device, duration: 20))
        }
        let first = try HAL.process(children[0].processIdentifier), peer = try HAL.process(children[1].processIdentifier)
        let own = try HAL.process(getpid())
        let catalog = try inventory()
        guard catalog.issues.isEmpty else { throw ProbeFailure(message: "Incomplete quarantine test catalog") }
        let others = catalog.processes.map(\.object).filter { ![first, peer, own].contains($0) }
        try route.prepare(apps: [[first], [peer]], playback: .all, passthrough: others)
        guard let engine = route.engine, probe_prime_gain(engine, 0, 0.25) else {
            throw ProbeFailure(message: "Cannot prime quarantine test gain")
        }
        try route.start()
        children.append(try sourceProcess("C", frequency: 2467, device: device, duration: 15))
        let newcomer = try HAL.process(children[2].processIdentifier)
        guard probe_set_phase_immediate(engine, 1) else { throw ProbeFailure(message: "Cannot capture quarantined source") }
        wait(1.1); try route.validateStreamMap()
        guard probe_capture_ready(engine, 1) else { throw ProbeFailure(message: "Quarantine capture did not complete") }
        heldInput = finite(probe_tone_amplitude(engine, 1, 3, 0, 2467))
        heldOutput = finite(probe_tone_amplitude(engine, 1, 4, 0, 2467))
        gates.append(Gate(name: "Unassigned newcomer withheld", passed: (heldInput ?? 0) > 0.004 && (heldOutput ?? .infinity) < 0.00001,
                          detail: "The global device-scoped reference receives C; neither replay lane includes C"))
        try route.rebindBrowser(first: [first, newcomer], passthrough: others, replaceFirst: true) {
            guard probe_set_phase_immediate(engine, 2) else { throw ProbeFailure(message: "Cannot capture newcomer assignment") }
        }
        wait(1.1); try route.suspend()
        let gains: [Float] = [0.25, 1, 1, 0]
        let check = probe_render_check(engine, 2, gains, 4, 0)
        assignedGain = check.valid ? finite(check.observedGain) : nil
        assignedError = check.valid && check.inputRMS > 0 ? finite(check.errorRMS / check.inputRMS) : nil
        gates.append(Gate(name: "Retained assignment gain", passed: check.valid &&
            abs(check.observedGain - 0.25) < 0.00001 && (assignedError ?? .infinity) < 0.00001 &&
            probe_tone_amplitude(engine, 2, 0, 0, 2467) > 0.004,
            detail: "After explicit assignment, C joins the app lane with the existing 25% gain"))
        let counters = probe_counters(engine)
        gates.append(Gate(name: "Callback faults", passed: counters.frames > 0 && counters.invalidBuffers == 0 && counters.nonfiniteSamples == 0,
                          detail: "No malformed buffers or nonfinite samples"))
        if gates.contains(where: { !$0.passed }) { throw ProbeFailure(message: "A newcomer quarantine gate failed") }
    } catch { failure = error }
    do { try route.stop() } catch { failure = ProbeFailure(message: (failure.map { $0.localizedDescription + " Cleanup: " } ?? "") + error.localizedDescription) }
    for child in children { if child.isRunning { child.terminate() }; child.waitUntilExit() }
    struct Report: Encodable {
        let outcome: String; let error: String?; let output: DeviceInfo
        let heldInputAmplitude: Double?; let heldOutputAmplitude: Double?
        let assignedGain: Double?; let assignedNormalizedError: Double?; let gates: [Gate]
    }
    try writeJSON(Report(outcome: failure == nil ? "passed" : "failed", error: failure?.localizedDescription, output: device,
                         heldInputAmplitude: heldInput, heldOutputAmplitude: heldOutput, assignedGain: assignedGain,
                         assignedNormalizedError: assignedError, gates: gates), to: options.values["--report"])
    if let failure { throw failure }
}
