import Foundation
import CoreAudio

@main struct RecoveryChecks {
    static func main() throws {
        precondition(isTransientOutputRead(kAudioHardwareNotRunningError))
        precondition(isTransientOutputRead(kAudioHardwareUnknownPropertyError))
        precondition(!isTransientOutputRead(kAudioDevicePermissionsError))
        precondition(!isTransientOutputRead(kAudioHardwareBadPropertySizeError))
        precondition(!isTransientOutputRead(kAudioHardwareIllegalOperationError))
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var state = try MixerRecoveryState(outputUID: "bose", outputName: "Bose", controls: MixerControls(volume: 0.5, muted: false))
        state.start(now: now)
        precondition(state.nextStart(availableUIDs: ["speakers"], now: now.addingTimeInterval(100)) == nil)
        precondition(state.phase == .waiting)
        precondition(state.nextStart(availableUIDs: ["bose"], now: now) == nil)
        let first = state.nextStart(availableUIDs: ["bose"], now: now.addingTimeInterval(1))!
        precondition(state.started(first) && state.controls.gain == 0.5)
        let oldGuard = StandbyMuteBinding(generation: first, outputObject: 104, outputUID: "bose", processes: [124, 125])
        state.lostOutput(now: now.addingTimeInterval(2))
        try state.setControls(MixerControls(volume: 0.25, muted: true))
        precondition(state.phase == .waiting && state.controls.gain == 0 && state.controls.volume == 0.25)
        precondition(state.nextStart(availableUIDs: ["speakers"], now: now.addingTimeInterval(3)) == nil)
        precondition(state.nextStart(availableUIDs: ["bose"], now: now.addingTimeInterval(4)) == nil)
        // The replacement needs a fresh guard while the route is still settling,
        // even if process objects (or a reused hardware object ID) stay the same.
        precondition(!oldGuard.targets(generation: state.generation, outputObject: 159, outputUID: "bose"))
        precondition(!oldGuard.targets(generation: state.generation, outputObject: 104, outputUID: "bose"))
        let reboundGuard = StandbyMuteBinding(generation: state.generation, outputObject: 159, outputUID: "bose", processes: [124, 125])
        precondition(reboundGuard != oldGuard)
        precondition(reboundGuard.targets(generation: state.generation, outputObject: 159, outputUID: "bose"))
        precondition(!reboundGuard.targets(generation: state.generation, outputObject: 159, outputUID: "speakers"))
        precondition(reboundGuard != StandbyMuteBinding(generation: state.generation, outputObject: 159, outputUID: "bose", processes: [126]))
        let resumed = state.nextStart(availableUIDs: ["bose"], now: now.addingTimeInterval(5))!
        precondition(resumed != first && !state.started(first) && state.started(resumed))
        precondition(state.controls.muted && state.controls.volume == 0.25)
        try state.setControls(MixerControls(volume: 0.25, muted: false))
        precondition(state.controls.gain == 0.25)
        state.lostOutput(now: now.addingTimeInterval(6)); state.stop()
        precondition(state.nextStart(availableUIDs: ["bose"], now: now.addingTimeInterval(20)) == nil && state.phase == .stopped)
        state.start(now: now)
        _ = state.nextStart(availableUIDs: ["bose"], now: now)
        let cancelled = state.nextStart(availableUIDs: ["bose"], now: now.addingTimeInterval(1))!
        state.stop(); precondition(!state.started(cancelled) && !state.accepts(cancelled))
        print("PASS exact-output recovery, guard rebinding while settling, readiness delay, retained volume/mute, waiting edits, Stop cancellation and stale completion rejection")

        state.start(now: now); _ = state.nextStart(availableUIDs: ["bose"], now: now)
        var time = now.addingTimeInterval(1)
        var previousAttempt: UInt64?
        for attempt in 0...3 {
            let token = state.nextStart(availableUIDs: ["bose"], now: time)!
            if let previousAttempt { precondition(token != previousAttempt && !state.started(previousAttempt)) }
            previousAttempt = token
            state.startFailed(token, retryable: true, reason: "not ready", now: time)
            precondition(state.phase == (attempt < 3 ? .waiting : .failed))
            time = time.addingTimeInterval(2)
        }
        precondition(state.nextStart(availableUIDs: ["bose"], now: time) == nil)
        state.start(now: now); _ = state.nextStart(availableUIDs: ["bose"], now: now)
        let denied = state.nextStart(availableUIDs: ["bose"], now: now.addingTimeInterval(1))!
        state.startFailed(denied, retryable: false, reason: "permission", now: now)
        precondition(state.phase == .failed && state.error == "permission")
        state.start(now: now); _ = state.nextStart(availableUIDs: ["bose"], now: now)
        let changed = state.nextStart(availableUIDs: ["bose"], now: now.addingTimeInterval(1))!; _ = state.started(changed)
        precondition(state.formatChanged(now: now.addingTimeInterval(2)))
        _ = state.nextStart(availableUIDs: ["bose"], now: now.addingTimeInterval(3))
        let repeated = state.nextStart(availableUIDs: ["bose"], now: now.addingTimeInterval(4))!; _ = state.started(repeated)
        precondition(!state.formatChanged(now: now.addingTimeInterval(5)) && state.phase == .failed)
        do { try state.setControls(MixerControls(volume: .nan, muted: false)); preconditionFailure("Invalid volume accepted") }
        catch is RecoveryPolicyFailure {}
        print("PASS bounded transient retries, permission hard stop, format-restart budget and invalid controls")
    }
}
