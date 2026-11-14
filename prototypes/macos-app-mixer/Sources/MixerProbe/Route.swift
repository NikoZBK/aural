import CoreAudio
import Foundation
import ProbeCore

enum Playback: String { case monitor, owned, all }
struct Lane: Codable {
    let name: String
    let tap: AudioObjectID
    let uid: String
    let processes: [AudioObjectID]
    let excluding: Bool
    let stream: AudioObjectID
    let reportedStartingChannel: UInt32
    let channelOffset: UInt32
}

// CLI control-thread owner. The callback only uses the separate C engine.
final class ProbeRoute {
    private(set) var lanes: [Lane] = []
    private var own: AudioObjectID = 0
    private var appGroups: [[AudioObjectID]] = []
    private var descriptions: [CATapDescription] = []
    private var taps: [AudioObjectID] = []
    private(set) var aggregate: AudioObjectID = 0
    private var callback: AudioDeviceIOProcID?
    private(set) var engine: OpaquePointer?
    private var inputStreams: [AudioObjectID] = []
    let device: DeviceInfo
    var hasResources: Bool { aggregate != 0 || callback != nil || engine != nil || !taps.isEmpty }

    init(device: DeviceInfo) { self.device = device }

    func prepare(apps: [[AudioObjectID]], playback: Playback, restore: Bool = false,
                 passthrough: [AudioObjectID]? = nil) throws {
        guard apps.count == 2, apps.allSatisfy({ !$0.isEmpty }), Set(apps.flatMap { $0 }).count == apps.flatMap({ $0 }).count else {
            throw ProbeFailure(message: "Two nonempty, disjoint process groups are required")
        }
        own = try HAL.process(getpid()); appGroups = apps
        guard !apps.flatMap({ $0 }).contains(own) else { throw ProbeFailure(message: "The probe cannot tap itself") }
        if let passthrough {
            guard playback == .all, !restore, Set(passthrough).count == passthrough.count,
                  !passthrough.contains(where: { $0 == own || apps.flatMap({ $0 }).contains($0) }) else {
                throw ProbeFailure(message: "Quarantined playback requires disjoint explicit processes and no bundle restoration")
            }
        }
        let composition: [String: Any] = [kAudioAggregateDeviceNameKey: "Aural Mixer Diagnostic",
            kAudioAggregateDeviceUIDKey: "local.aural.mixer-probe.\(UUID().uuidString)", kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]]]
        try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Create diagnostic aggregate")
        inputStreams = try HAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        let specs: [(String, [AudioObjectID], Bool, Bool)] = [
            ("App A", apps[0], false, playback != .monitor), ("App B", apps[1], false, playback != .monitor),
            ("Remaining audio", passthrough ?? (apps.flatMap { $0 } + [own]), passthrough == nil, playback == .all),
            ("Unity reference", [own], true, passthrough != nil)]
        for (name, processes, excluding, mute) in specs {
            let description = excluding ? CATapDescription(excludingProcesses: processes, deviceUID: device.uid, stream: 0)
                : CATapDescription(processes: processes, deviceUID: device.uid, stream: 0)
            if restore {
                if #available(macOS 26, *) { description.isProcessRestoreEnabled = true }
                else { throw ProbeFailure(message: "Native process restoration requires macOS 26 or newer") }
            }
            description.name = "Aural Mixer Probe: \(name)"
            description.isPrivate = true; description.muteBehavior = mute ? .mutedWhenTapped : .unmuted
            var tap: AudioObjectID = 0
            try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "Create \(name) tap")
            taps.append(tap); descriptions.append(description)
            let format = try HAL.scalar(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
            try HAL.validate(format, rate: device.rate)
            let uid = try HAL.string(tap, kAudioTapPropertyUID)
            guard uid == description.uuid.uuidString else { throw ProbeFailure(message: "Tap UID does not match its description") }
            let previous = inputStreams
            let uuids = try taps.map { try HAL.string($0, kAudioTapPropertyUID) } as CFArray
            try HAL.check(probe_set_taps(aggregate, uuids), "Append \(name) to aggregate", aggregate)
            let deadline = Date().addingTimeInterval(2)
            repeat {
                inputStreams = try HAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
                if inputStreams.count == previous.count + 1 { break }
                wait(0.02)
            } while Date() < deadline
            let added = inputStreams.filter { !previous.contains($0) }
            guard inputStreams.count == previous.count + 1, added.count == 1, previous.allSatisfy(inputStreams.contains) else {
                throw ProbeFailure(message: "Cannot prove tap ownership after append: before=\(previous), after=\(inputStreams)")
            }
            let stream = added[0]; try HAL.validate(HAL.format(stream), rate: device.rate)
            let start = try HAL.scalar(stream, kAudioStreamPropertyStartingChannel, UInt32(0))
            guard start > 0 else { throw ProbeFailure(message: "Tap stream has no starting channel") }
            lanes.append(Lane(name: name, tap: tap, uid: uid, processes: processes, excluding: excluding, stream: stream, reportedStartingChannel: start, channelOffset: 0))
        }
        // StreamConfiguration describes the IOProc's buffer list. StartingChannel
        // on these tap streams is not a valid IOProc offset on macOS 27 (e.g.
        // starts 7/9/11/13 for an eight-channel list). Establish a candidate map
        // from the verified stream identities and validate it with isolated tones.
        var channels = [UInt32](repeating: 0, count: 32), count: UInt32 = 0
        try HAL.check(probe_stream_channels(aggregate, true, &channels, UInt32(channels.count), &count), "Read callback stream configuration", aggregate)
        guard count == inputStreams.count else { throw ProbeFailure(message: "Stream list/configuration count differs") }
        var offsets: [AudioObjectID: UInt32] = [:], offset: UInt32 = 0
        for (index, stream) in inputStreams.enumerated() {
            let format = try HAL.format(stream)
            guard format.mChannelsPerFrame == channels[index] else { throw ProbeFailure(message: "Stream/configuration channels differ") }
            offsets[stream] = offset; offset += channels[index]
        }
        lanes = try lanes.map { lane in
            guard let offset = offsets[lane.stream] else { throw ProbeFailure(message: "Verified tap stream disappeared") }
            return Lane(name: lane.name, tap: lane.tap, uid: lane.uid, processes: lane.processes,
                        excluding: lane.excluding, stream: lane.stream,
                        reportedStartingChannel: try HAL.scalar(lane.stream, kAudioStreamPropertyStartingChannel, UInt32(0)), channelOffset: offset)
        }
        guard inputStreams == (try HAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)) else {
            throw ProbeFailure(message: "Stream topology changed during mapping")
        }
        guard Set(lanes.flatMap { [$0.channelOffset, $0.channelOffset + 1] }).count == lanes.count * 2 else {
            throw ProbeFailure(message: "Tap channel ranges overlap")
        }
        let sourceOffsets = lanes.map(\.channelOffset)
        let mask: UInt32 = playback == .monitor ? 0 : (playback == .owned ? 3 : 7)
        guard let context = probe_create(device.rate, sourceOffsets, UInt32(sourceOffsets.count), mask) else { throw ProbeFailure(message: "Cannot allocate bounded probe engine") }
        engine = context
    }

    // Deliberately sequential experiment: HAL has no documented transaction for
    // changing two taps together. The immediate capture measures the resulting
    // gap/overlap instead of hiding it behind a route restart or settling delay.
    func transferToFirstApp(_ additional: AudioObjectID, include: Bool) throws -> Double {
        guard descriptions.count == 4, !appGroups.flatMap({ $0 }).contains(additional), additional != own else {
            throw ProbeFailure(message: "Invalid handoff process or route state")
        }
        let start = Foundation.ProcessInfo.processInfo.systemUptime
        let first = appGroups[0] + (include ? [additional] : [])
        let remaining = first + appGroups[1] + [own]
        let updates: [(Int, [AudioObjectID])] = include ? [(2, remaining), (0, first)] : [(0, first), (2, remaining)]
        for (index, processes) in updates {
            let description = descriptions[index]
            description.processes = processes
            try HAL.check(probe_update_tap(taps[index], UnsafeRawPointer(Unmanaged.passUnretained(description).toOpaque())), "Update handoff tap \(index)", taps[index])
        }
        guard inputStreams == (try HAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)) else {
            throw ProbeFailure(message: "Handoff changed stream topology; cached channel map is no longer valid")
        }
        return (Foundation.ProcessInfo.processInfo.systemUptime - start) * 1000
    }

    func replaceFirstApp(_ process: AudioObjectID) throws {
        guard descriptions.count == 4, process != own, !appGroups[1].contains(process) else { throw ProbeFailure(message: "Invalid replacement source") }
        let first = [process]
        for (index, processes) in [(2, first + appGroups[1] + [own]), (0, first)] {
            let description = descriptions[index]; description.processes = processes
            try HAL.check(probe_update_tap(taps[index], UnsafeRawPointer(Unmanaged.passUnretained(description).toOpaque())), "Replace app process", taps[index])
        }
        appGroups[0] = first
        guard inputStreams == (try HAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)) else {
            throw ProbeFailure(message: "Process replacement changed stream topology")
        }
    }

    // The always-read, device-scoped reference tap suppresses every direct path.
    // Only positively partitioned processes enter replay. Unknown newcomers stay
    // on the reference input (which is never replayed) until attribution finishes.
    // Clear the old app binding before adding a new one; the C gain never resets.
    func rebindBrowser(first: [AudioObjectID], passthrough: [AudioObjectID], replaceFirst: Bool,
                       beforeBinding: () throws -> Void) throws {
        guard descriptions.count == 4, !descriptions[2].isExclusive,
              descriptions[3].muteBehavior == .mutedWhenTapped,
              Set(first + passthrough).count == first.count + passthrough.count,
              !(first + passthrough).contains(where: { $0 == own || appGroups[1].contains($0) }) else {
            throw ProbeFailure(message: "Invalid quarantined browser partition")
        }
        func update(_ index: Int, _ processes: [AudioObjectID]) throws {
            descriptions[index].processes = processes
            try HAL.check(probe_update_tap(taps[index], UnsafeRawPointer(Unmanaged.passUnretained(descriptions[index]).toOpaque())),
                          "Update browser partition \(index)", taps[index])
        }
        if replaceFirst { try update(0, []) }
        try update(2, passthrough)
        if replaceFirst {
            try beforeBinding()
            try update(0, first)
            appGroups[0] = first
        }
        try validateStreamMap()
    }

    func start() throws {
        guard let engine, callback == nil else { throw ProbeFailure(message: "Route is not prepared or already started") }
        try HAL.check(AudioDeviceCreateIOProcID(aggregate, probe_callback, UnsafeMutableRawPointer(engine), &callback), "Create probe callback", aggregate)
        guard let callback else { throw ProbeFailure(message: "HAL returned no callback") }
        // Enable precisely the four verified tap streams, never hardware inputs.
        if inputStreams.contains(where: { stream in !lanes.contains(where: { $0.stream == stream }) }) {
            try setInputUsage(callback)
        }
        try HAL.check(AudioDeviceStart(aggregate, callback), "Start probe capture", aggregate)
    }

    private func setInputUsage(_ callback: AudioDeviceIOProcID) throws {
        let flags: [UInt32] = inputStreams.map { stream in lanes.contains(where: { $0.stream == stream }) ? 1 : 0 }
        try HAL.check(probe_enable_inputs(aggregate, callback, flags, UInt32(flags.count)), "Enable verified tap inputs", aggregate)
    }

    func validateStreamMap() throws {
        guard aggregate != 0, inputStreams == (try HAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)) else {
            throw ProbeFailure(message: "The running aggregate's stream map changed; stopping before using stale offsets")
        }
    }

    func suspend() throws {
        guard let callback else { return }
        var failures: [String] = []
        let stop = AudioDeviceStop(aggregate, callback)
        if ![noErr, kAudioHardwareNotRunningError, kAudioHardwareBadDeviceError, kAudioHardwareBadObjectError].contains(stop) { failures.append("Stop callback: \(stop)") }
        let remove = AudioDeviceDestroyIOProcID(aggregate, callback)
        if remove == noErr || remove == kAudioHardwareBadDeviceError || remove == kAudioHardwareBadObjectError { self.callback = nil }
        else { failures.append("Remove callback: \(remove)") }
        if !failures.isEmpty { throw ProbeFailure(message: failures.joined(separator: "; ")) }
    }

    func stop() throws {
        var failures: [String] = []
        do { try suspend() } catch { failures.append(error.localizedDescription) }
        if aggregate != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregate)
            if status == noErr || status == kAudioHardwareBadDeviceError || status == kAudioHardwareBadObjectError { aggregate = 0; callback = nil }
            else { failures.append("Destroy aggregate: \(status)") }
        }
        // Release every tap even when another cleanup step failed. Keep callback
        // context alive if HAL has not confirmed its callback/device is gone.
        var remaining: [AudioObjectID] = []
        for tap in taps {
            let status = AudioHardwareDestroyProcessTap(tap)
            if status != noErr && status != kAudioHardwareBadObjectError && status != kAudioHardwareBadDeviceError {
                remaining.append(tap); failures.append("Destroy tap \(tap): \(status)")
            }
        }
        taps = remaining
        if callback == nil, let engine { probe_destroy(engine); self.engine = nil }
        if !failures.isEmpty { throw ProbeFailure(message: failures.joined(separator: "; ")) }
    }
}
