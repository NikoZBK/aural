import CoreAudio
import Foundation
import DSP

func check(_ status: OSStatus, _ action: String) throws {
    guard status == noErr else { throw AudioFailure(message: "\(action) failed (Core Audio \(status)). If access was denied, enable Aural in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen it.") }
}
func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
    var value = initial, size = UInt32(MemoryLayout<T>.size), a = address(selector, scope)
    try withUnsafeMutablePointer(to: &value) { pointer in
        try check(AudioObjectGetPropertyData(id, &a, 0, nil, &size, pointer), "Read audio property")
    }
    return value
}
func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
    var a = address(selector, scope), size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size), "Read audio list size")
    var result = [AudioObjectID](repeating: 0, count: Int(size)/MemoryLayout<AudioObjectID>.size)
    if size > 0 { try check(AudioObjectGetPropertyData(id, &a, 0, nil, &size, &result), "Read audio list") }
    return result
}
func audioString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size), a = address(selector)
    try check(AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value), "Read device name")
    guard let value else { throw AudioFailure(message: "Core Audio returned an empty device name.") }
    return value.takeRetainedValue() as String
}
struct OutputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

@MainActor final class AudioRoute {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    private var dsp: OpaquePointer?
    private(set) var device: OutputDevice?
    private(set) var sampleRate = 48000.0
    var hasResources: Bool { tap != 0 || aggregate != 0 || proc != nil }
    var peak: Float { dsp.map(eq_peak) ?? 0 }
    var faults: UInt32 { dsp.map(eq_faults) ?? 0 }

    static func devices() throws -> [OutputDevice] {
        try ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
            let streams = try ids(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            guard !streams.isEmpty else { return nil }
            let uid = try audioString(id, kAudioDevicePropertyDeviceUID)
            guard !uid.hasPrefix("local.aural.") else { return nil }
            // Initial release supports a single stereo output stream; do not discard surround channels.
            guard streams.count == 1 else { return nil }
            let format = try scalar(streams[0], kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
            guard format.mChannelsPerFrame == 2 else { return nil }
            return OutputDevice(id: id, uid: uid, name: try audioString(id, kAudioObjectPropertyName))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func defaultOutput() throws -> AudioObjectID {
        try scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
    }
    func start(_ output: OutputDevice, profile: Profile, bypass: Bool) throws {
        try stop()
        guard #available(macOS 14.2, *) else { throw AudioFailure(message: "Aural requires macOS 14.2 or newer.") }
        do {
            var pid = getpid(), ownProcess: AudioObjectID = 0
            var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess), "Identify Aural's audio process")
            guard ownProcess != 0 else { throw AudioFailure(message: "Core Audio did not provide Aural's process identity. Reopen the app before starting.") }
            let description = CATapDescription(excludingProcesses: [ownProcess], deviceUID: output.uid, stream: 0)
            description.name = "Aural EQ"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try check(AudioHardwareCreateProcessTap(description, &tap), "Create audio tap")
            let format = try scalar(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
            guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mChannelsPerFrame == 2 else {
                throw AudioFailure(message: "This output's tap does not provide 32-bit stereo audio. Select another output.")
            }
            sampleRate = format.mSampleRate
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Aural Private Audio",
                kAudioAggregateDeviceUIDKey: "local.aural.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "Create private audio route")
            // Hardware input streams precede tap streams in the aggregate. Locate and validate the trailing tap.
            let inputStreams = try ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            let outputStreams = try ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            guard let tapStream = inputStreams.last, !outputStreams.isEmpty else { throw AudioFailure(message: "The private audio route has no usable streams.") }
            var inputOffset: UInt32 = 0
            for stream in inputStreams.dropLast() {
                let f = try scalar(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
                inputOffset += f.mChannelsPerFrame
            }
            for stream in [tapStream] + outputStreams {
                let f = try scalar(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
                guard f.mFormatID == kAudioFormatLinearPCM, f.mBitsPerChannel == 32,
                      f.mFormatFlags & kAudioFormatFlagIsFloat != 0, f.mSampleRate == sampleRate,
                      f.mChannelsPerFrame == 2 else { throw AudioFailure(message: "The audio route changed format. Use a stereo output at 32–192 kHz.") }
            }
            guard let engine = eq_create(sampleRate, inputOffset) else { throw AudioFailure(message: "Cannot allocate the equalizer for this sample rate.") }
            dsp = engine
            try update(profile, bypass: bypass)
            try check(AudioDeviceCreateIOProcID(aggregate, eq_callback, UnsafeMutableRawPointer(engine), &proc), "Create audio callback")
            guard let proc else { throw AudioFailure(message: "Core Audio returned no audio callback.") }
            // With a tap-only input there is nothing to disable. Avoid a redundant HAL
            // stream-usage mutation, which can block on some built-in output routes.
            if inputStreams.count > 1 {
                try check(eq_enable_tap_input(aggregate, proc, UInt32(inputStreams.count)), "Enable only system audio input")
            }
            try check(AudioDeviceStart(aggregate, proc), "Start equalization")
            device = output
        } catch {
            let original = error.localizedDescription
            do { try stop() } catch { throw AudioFailure(message: original + " Cleanup: " + error.localizedDescription + " Quit Aural to release its route.") }
            throw AudioFailure(message: original)
        }
    }
    func update(_ profile: Profile, bypass: Bool) throws {
        _ = try profile.validated()
        if dsp != nil, let filters = profile.filters, filters.contains(where: { $0.enabled && $0.frequency >= sampleRate * 0.49 }) {
            throw AudioFailure(message: "An imported filter is too close to this output's Nyquist frequency. Choose a higher sample rate in Audio MIDI Setup before using this profile.")
        }
        let filters = profile.dspFilters
        if let dsp, !eq_update_filters(dsp, filters, UInt32(filters.count), profile.preamp, bypass) {
            throw AudioFailure(message: "The equalizer could not accept this setting. Stop and start processing to retry.")
        }
    }
    func stop() throws {
        if let proc {
            try check(AudioDeviceStop(aggregate, proc), "Stop audio")
            try check(AudioDeviceDestroyIOProcID(aggregate, proc), "Release audio callback")
            self.proc = nil
        }
        if let dsp { eq_destroy(dsp); self.dsp = nil }
        if aggregate != 0 { try check(AudioHardwareDestroyAggregateDevice(aggregate), "Release private route"); aggregate = 0 }
        if tap != 0 {
            if #available(macOS 14.2, *) { try check(AudioHardwareDestroyProcessTap(tap), "Release audio tap") }
            tap = 0
        }
        device = nil
    }
    func verify() throws {
        guard let device else { return }
        let alive = try scalar(device.id, kAudioDevicePropertyDeviceIsAlive, UInt32(0))
        let rate = try scalar(device.id, kAudioDevicePropertyNominalSampleRate, Double(0))
        guard alive == 1, abs(rate - sampleRate) < 1, faults == 0 else {
            throw AudioFailure(message: "The output disconnected or its audio format changed. Processing stopped; select an output and start again.")
        }
    }
}

extension Profile {
    var dspFilters: [EQFilter] {
        if let filters {
            return filters.map { filter in
                let type: UInt32
                switch filter.kind { case .peak: type = 0; case .lowShelf: type = 1; case .highShelf: type = 2 }
                return EQFilter(frequency: filter.frequency, gain: filter.enabled ? filter.gain : 0, q: filter.q, type: type)
            }
        }
        let frequencies: [Double] = [31.5,63,125,250,500,1000,2000,4000,8000,16000]
        return zip(frequencies, gains).map { EQFilter(frequency: $0.0, gain: $0.1, q: 1.4, type: 0) }
    }
    func response(_ frequency: Double, rate: Double, preamp: Double? = nil) -> Double {
        let filters = dspFilters
        return eq_response_filters(frequency, rate, filters, UInt32(filters.count), preamp ?? self.preamp)
    }
}
