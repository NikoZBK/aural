import CoreAudio
import Foundation
import Mixer

// Owned only by AppMixerTopology's serial control queue. The independent reader
// survives physical playback teardown and never renders or retains PCM.
final class AppMixerGuard {
    let output: OutputDevice
    private(set) var tap: UInt32 = 0
    private var aggregate: UInt32 = 0
    private var callback: AudioDeviceIOProcID?
    private var drain: OpaquePointer?
    var hasResources: Bool { tap != 0 || aggregate != 0 || callback != nil || drain != nil }
    init(output: OutputDevice) { self.output = output }
    func start(ownProcess: UInt32) throws {
        guard #available(macOS 14.2, *), !hasResources else { throw AudioFailure(message: "The mixer guard cannot start in this state.") }
        let description = Self.tapDescription(output: output, ownProcess: ownProcess)
        // Establish the reader before persistent suppression, including when
        // all sources are quiet. The reader remains independent of playback.
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tap), "Create mixer protection tap")
        let uid = try audioString(tap, kAudioTapPropertyUID)
        guard uid == description.uuid.uuidString else { throw AudioFailure(message: "Mixer protection tap identity changed.") }
        let config = Self.readerConfiguration(tapUID: uid)
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "Create mixer protection reader")
        let inputs = try ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        let outputs = try ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard inputs.count == 1, outputs.isEmpty else { throw AudioFailure(message: "Mixer protection must contain one input and no hardware output.") }
        guard let context = am_drain_create() else { throw AudioFailure(message: "Cannot allocate the mixer protection reader.") }
        drain = context
        try check(AudioDeviceCreateIOProcID(aggregate, am_drain_callback, UnsafeMutableRawPointer(context), &callback), "Create mixer protection callback")
        guard let callback else { throw AudioFailure(message: "No mixer protection callback was returned.") }
        try check(AudioDeviceStart(aggregate, callback), "Start mixer protection reader")
        description.muteBehavior = .muted
        try check(am_update_tap(tap, UnsafeRawPointer(Unmanaged.passUnretained(description).toOpaque())), "Hold selected-output mute", objectID: tap)
        AuralLog.audio.notice("Selected-output protection armed: device=\(self.output.id, privacy: .public), tap=\(self.tap, privacy: .public), reader=\(self.aggregate, privacy: .public)")
    }
    @available(macOS 14.2, *)
    static func readerConfiguration(tapUID: String) -> [String: Any] {
        [kAudioAggregateDeviceNameKey: "Aural selected-output reader",
         kAudioAggregateDeviceUIDKey: "local.aural.mixer-guard.\(UUID().uuidString)", kAudioAggregateDeviceIsPrivateKey: true,
         // true makes AudioDeviceStart block until a tapped app produces audio.
         // A standby reader must instead be ready before the next source plays.
         kAudioAggregateDeviceTapAutoStartKey: false,
         kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]]
    }
    @available(macOS 14.2, *)
    static func tapDescription(output: OutputDevice, ownProcess: UInt32) -> CATapDescription {
        let description = CATapDescription(excludingProcesses: [ownProcess], deviceUID: output.uid, stream: 0)
        description.name = "Aural selected-output protection"; description.isPrivate = true
        // Reconnect temporarily stops tap reads. Conditional mute would expose
        // the original app stream until the replacement reader starts. Keep
        // suppression scoped to this physical UID even while reads are idle.
        description.muteBehavior = .muted
        if #available(macOS 26, *) { description.isProcessRestoreEnabled = false }
        return description
    }
    func verify() throws {
        guard tap != 0, let drain, am_drain_counters(drain).faults == 0 else { throw AudioFailure(message: "The mixer protection reader is unavailable.") }
        _ = try audioString(tap, kAudioTapPropertyUID)
    }
    #if AURAL_TESTING
    func adoptForTesting(tap: UInt32, aggregate: UInt32) {
        self.tap = tap; self.aggregate = aggregate
        drain = am_drain_create(); precondition(drain != nil)
        callback = am_drain_callback
    }
    #endif
    func stop(cleanup: AudioRouteCleanup) throws {
        if let drain {
            let counters = am_drain_counters(drain)
            AuralLog.audio.notice("Releasing selected-output protection: device=\(self.output.id, privacy: .public), frames=\(counters.frames, privacy: .public), faults=\(counters.faults, privacy: .public)")
        }
        var failures: [String] = []
        func accepted(_ status: OSStatus, _ action: String, stopped: Bool = false) -> Bool {
            if status == noErr || status == kAudioHardwareBadObjectError || status == kAudioHardwareBadDeviceError || (stopped && status == kAudioHardwareNotRunningError) { return true }
            failures.append(CoreAudioFailure(status: status, action: action).localizedDescription); return false
        }
        if let callback {
            _ = accepted(cleanup.stop(aggregate, callback), "Stop mixer protection", stopped: true)
            if accepted(cleanup.destroyCallback(aggregate, callback), "Release mixer protection callback") { self.callback = nil }
        }
        if aggregate != 0, accepted(cleanup.destroyAggregate(aggregate), "Release mixer protection reader") { aggregate = 0; callback = nil }
        if callback == nil, let drain { am_drain_destroy(drain); self.drain = nil }
        if tap != 0, accepted(cleanup.destroyTap(tap), "Release mixer protection tap") { tap = 0 }
        if !failures.isEmpty { throw AudioFailure(message: failures.joined(separator: " ")) }
    }
}
