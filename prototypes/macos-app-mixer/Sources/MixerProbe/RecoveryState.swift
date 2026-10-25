import Foundation

struct MixerControls: Codable, Equatable {
    let volume: Float
    let muted: Bool
    var gain: Float { muted ? 0 : volume }
    func validate() throws {
        guard volume.isFinite, (0...1).contains(volume) else { throw RecoveryPolicyFailure(message: "App volume must be finite and between 0 and 1") }
    }
}
struct RecoveryPolicyFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// A tap object can remain readable after its hardware device is replaced. Its
// UID alone therefore does not prove that it still mutes the current endpoint.
struct StandbyMuteBinding: Equatable, Codable {
    let generation: UInt64
    let outputObject: UInt32
    let outputUID: String
    let processes: [UInt32]

    func targets(generation: UInt64, outputObject: UInt32, outputUID: String) -> Bool {
        self.generation == generation && self.outputObject == outputObject && self.outputUID == outputUID
    }
}

// Uses Aural's exact StartupPlan and RouteRecovery sources, materialized by the
// build script. HAL ownership and callback memory remain with the route owner.
struct MixerRecoveryState {
    enum Phase: String, Codable { case stopped, waiting, starting, running, failed }
    let outputUID: String
    let outputName: String
    private(set) var controls: MixerControls
    private(set) var phase: Phase = .stopped
    private(set) var generation: UInt64 = 0
    private(set) var error: String?
    private var plan: StartupPlan?
    private var readySince: Date?
    private var restarts = RouteRecovery()

    init(outputUID: String, outputName: String, controls: MixerControls) throws {
        guard !outputUID.isEmpty else { throw RecoveryPolicyFailure(message: "Recovery requires an exact output UID") }
        try controls.validate()
        self.outputUID = outputUID; self.outputName = outputName; self.controls = controls
    }
    mutating func setControls(_ controls: MixerControls) throws { try controls.validate(); self.controls = controls }
    mutating func start(now: Date) {
        generation += 1; phase = .waiting; error = nil; readySince = nil
        plan = .resume(outputUID: outputUID, outputName: outputName, after: 1, now: now)
    }
    mutating func stop() {
        generation += 1; phase = .stopped; plan = nil; readySince = nil; error = nil
    }
    mutating func fail(_ reason: String) {
        generation += 1; phase = .failed; plan = nil; readySince = nil; error = reason
    }
    mutating func lostOutput(now: Date) {
        guard phase == .running || phase == .starting else { return }
        start(now: now)
    }
    mutating func formatChanged(now: Date) -> Bool {
        guard restarts.allowRestart(now: now) else { fail("The audio route keeps changing; automatic recovery stopped"); return false }
        lostOutput(now: now); return true
    }
    mutating func nextStart(availableUIDs: [String], now: Date) -> UInt64? {
        guard phase == .waiting, var plan else { return nil }
        guard availableUIDs.contains(outputUID) else { readySince = nil; return nil }
        if readySince == nil {
            readySince = now
            plan.notBefore = max(plan.notBefore ?? now, now.addingTimeInterval(1))
            self.plan = plan
        }
        guard plan.decision(availableUIDs: availableUIDs, now: now) == .start else { return nil }
        phase = .starting
        return generation
    }
    func accepts(_ token: UInt64) -> Bool { phase == .starting && generation == token }
    mutating func started(_ token: UInt64) -> Bool {
        guard accepts(token) else { return false }
        phase = .running; plan = nil; readySince = nil; error = nil; return true
    }
    mutating func startFailed(_ token: UInt64, retryable: Bool, reason: String, now: Date) {
        guard accepts(token) else { return }
        if retryable, let retry = plan?.retry(now: now) {
            generation += 1; plan = retry; phase = .waiting; error = reason
        } else { fail(reason) }
    }
}
