import CoreAudio
import Foundation
import DSP
import OSLog

struct CoreAudioFailure: LocalizedError {
    let status: OSStatus
    let action: String
    var errorDescription: String? {
        "\(action) failed (Core Audio \(status)). If access was denied, enable Aural in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen it."
    }
}

func check(_ status: OSStatus, _ action: String) throws {
    guard status == noErr else { throw CoreAudioFailure(status: status, action: action) }
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
    private static let logger = Logger(subsystem: "local.aural.equalizer", category: "AudioRoute")
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    private var dsp: OpaquePointer?
    private var inputStreams: [AudioObjectID] = []
    private var outputStreams: [AudioObjectID] = []
    private var inputOffset: UInt32 = 0
    private(set) var device: OutputDevice?
    private(set) var sampleRate = 48000.0
    /// Loudness compensation, after the profile's filters. The next update or start applies it.
    var loudness: [EQFilter] = []
    var hasResources: Bool { tap != 0 || aggregate != 0 || proc != nil }
    func readMeter() -> AudioMeterReading {
        guard let dsp else { return AudioMeterReading() }
        let reading = eq_read_meter(dsp)
        return AudioMeterReading(peak: reading.peak, reductionDB: reading.reductionDB)
    }
    var faults: UInt32 { dsp.map(eq_faults) ?? 0 }
    private var loggedSignalFaults: UInt32 = 0

    static func devices() throws -> [OutputDevice] {
        try ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
            do {
                let streams = try ids(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
                guard !streams.isEmpty else { return nil }
                let uid = try audioString(id, kAudioDevicePropertyDeviceUID)
                guard !uid.hasPrefix("local.aural.") else { return nil }
                // Supports one stereo output stream; never discard surround channels.
                guard streams.count == 1 else { return nil }
                let format = try scalar(streams[0], kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
                guard format.mChannelsPerFrame == 2 else { return nil }
                return OutputDevice(id: id, uid: uid, name: try audioString(id, kAudioObjectPropertyName))
            } catch let failure as CoreAudioFailure where failure.status == kAudioHardwareBadDeviceError || failure.status == kAudioHardwareBadObjectError {
                // Device/stream IDs can expire between enumeration and property
                // reads. A disconnected device must not hide the healthy outputs.
                logger.warning("Skipped unavailable audio device \(id, privacy: .public): \(failure.localizedDescription, privacy: .public)")
                return nil
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func defaultOutput() throws -> AudioObjectID {
        try scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
    }
    /// The macOS default output, including outputs Aural cannot equalize.
    static func systemOutput() throws -> OutputDevice? {
        let id = try defaultOutput()
        guard id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return OutputDevice(id: id, uid: try audioString(id, kAudioDevicePropertyDeviceUID), name: try audioString(id, kAudioObjectPropertyName))
    }
    /// The output's volume in dB: its main control, or the average of its two channels.
    /// Nil when macOS cannot change the output's volume, as with many HDMI outputs.
    static func volume(of id: AudioObjectID) -> Double? {
        func read(_ element: AudioObjectPropertyElement) -> Double? {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
            var value: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectHasProperty(id, &a), AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, !value.isNaN else { return nil }
            return Double(value)
        }
        if let main = read(kAudioObjectPropertyElementMain) { return main }
        let channels = [1, 2].compactMap { read(AudioObjectPropertyElement($0)) }
        return channels.isEmpty ? nil : channels.reduce(0, +) / Double(channels.count)
    }
    static func validateStereoFormat(_ format: AudioStreamBasicDescription, rate: Double? = nil) throws {
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size) * (planar ? 1 : 2)
        guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == kAudioFormatFlagsNativeEndian,
              format.mChannelsPerFrame == 2, format.mFramesPerPacket == 1,
              format.mBytesPerFrame == bytesPerFrame, format.mBytesPerPacket == bytesPerFrame,
              format.mSampleRate.isFinite, (32000...192000).contains(format.mSampleRate),
              rate == nil || format.mSampleRate == rate else {
            throw AudioFailure(message: "The audio route requires native 32-bit float stereo at 32–192 kHz. The output format changed or is unsupported; select an output and start again.")
        }
    }
    func start(_ output: OutputDevice, profile: Profile, bypass: Bool, peakProtectionEnabled: Bool, levelMatch: LevelMatch = .none) throws {
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
            try Self.validateStereoFormat(format)
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
                try Self.validateStereoFormat(f, rate: sampleRate)
            }
            guard let engine = eq_create(sampleRate, inputOffset) else { throw AudioFailure(message: "Cannot allocate the equalizer for this sample rate.") }
            dsp = engine
            loggedSignalFaults = 0
            setPeakProtection(peakProtectionEnabled)
            try update(profile, bypass: bypass, levelMatch: levelMatch)
            try check(AudioDeviceCreateIOProcID(aggregate, eq_callback, UnsafeMutableRawPointer(engine), &proc), "Create audio callback")
            guard let proc else { throw AudioFailure(message: "Core Audio returned no audio callback.") }
            // With a tap-only input there is nothing to disable. Avoid a redundant HAL
            // stream-usage mutation, which can block on some built-in output routes.
            if inputStreams.count > 1 {
                try check(eq_enable_tap_input(aggregate, proc, UInt32(inputStreams.count)), "Enable only system audio input")
            }
            try check(AudioDeviceStart(aggregate, proc), "Start equalization")
            self.inputStreams = inputStreams
            self.outputStreams = outputStreams
            self.inputOffset = inputOffset
            device = output
        } catch {
            let original = error.localizedDescription
            do { try stop() } catch { throw AudioFailure(message: original + " Cleanup: " + error.localizedDescription + " Quit Aural to release its route.") }
            throw AudioFailure(message: original)
        }
    }
    func setPeakProtection(_ enabled: Bool) {
        if let dsp { eq_set_peak_protection(dsp, enabled) }
    }
    func update(_ profile: Profile, bypass: Bool, levelMatch: LevelMatch = .none) throws {
        _ = try profile.validated()
        if dsp != nil, let filters = profile.filters, filters.contains(where: { $0.enabled && $0.frequency >= sampleRate * 0.49 }) {
            throw AudioFailure(message: "An imported filter is too close to this output's Nyquist frequency. Choose a higher sample rate in Audio MIDI Setup before using this profile.")
        }
        let filters = profile.dspFilters(rate: sampleRate) + loudness
        var stereo = profile.dspStereo
        // A/B matching lowers playback only; the saved preamp is unchanged.
        let preamp = max(-60, profile.preamp + levelMatch.eqOffsetDB)
        if let dsp, !eq_update_filters_matched(dsp, filters, UInt32(filters.count), preamp, bypass, &stereo, levelMatch.bypassGainDB) {
            throw AudioFailure(message: "The equalizer rejected this setting because a value is out of range.")
        }
    }
    /// Releases everything it can and throws the first failure at the end, so one
    /// Core Audio error cannot leave the tap muting system audio. Whatever failed
    /// stays recorded, and the next stop or start retries it.
    func stop() throws {
        var failure: Error?
        func attempt(_ step: () throws -> Void) -> Bool {
            do { try step(); return true } catch { if failure == nil { failure = error }; return false }
        }
        var callbackStopped = true
        if let proc {
            callbackStopped = attempt { try check(AudioDeviceStop(aggregate, proc), "Stop audio") }
            if attempt({ try check(AudioDeviceDestroyIOProcID(aggregate, proc), "Release audio callback") }) { self.proc = nil }
        }
        // A callback that may still be running keeps its engine: leak it rather than free it.
        if let dsp { if callbackStopped { eq_destroy(dsp) }; self.dsp = nil }
        if aggregate != 0, attempt({ try check(AudioHardwareDestroyAggregateDevice(aggregate), "Release private route") }) {
            aggregate = 0; proc = nil // The callback belonged to the destroyed device.
        }
        if tap != 0 {
            if #available(macOS 14.2, *) {
                if attempt({ try check(AudioHardwareDestroyProcessTap(tap), "Release audio tap") }) { tap = 0 }
            } else { tap = 0 }
        }
        inputStreams = []; outputStreams = []; inputOffset = 0
        device = nil
        if let failure { throw failure }
    }
    #if AURAL_TESTING
    /// A running route whose device has gone, so stopping its callback fails.
    func adoptForTesting(tap: AudioObjectID, aggregate: AudioObjectID, device: OutputDevice) {
        self.tap = tap; self.aggregate = aggregate; self.device = device
        proc = eq_callback; dsp = eq_create(48000, 0)
    }
    #endif
    func verify() throws {
        guard let device else { return }
        // The callback replaces bad samples from a playing app without stopping
        // EQ, so they are only logged. Malformed buffers mean a broken route.
        if let dsp {
            let signalFaults = eq_signal_faults(dsp)
            if signalFaults != loggedSignalFaults {
                let replaced = signalFaults &- loggedSignalFaults
                Self.logger.warning("Replaced \(replaced, privacy: .public) non-finite or overflowing audio samples")
                loggedSignalFaults = signalFaults
            }
        }
        let alive = try scalar(device.id, kAudioDevicePropertyDeviceIsAlive, UInt32(0))
        let rate = try scalar(device.id, kAudioDevicePropertyNominalSampleRate, Double(0))
        guard alive == 1, abs(rate - sampleRate) < 1, faults == 0 else {
            throw AudioFailure(message: "The output disconnected or its audio format changed. Processing stopped; select an output and start again.")
        }
        let inputs = try ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        let outputs = try ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard inputs == inputStreams, outputs == outputStreams, let tapStream = inputs.last else {
            throw AudioFailure(message: "The audio route's streams changed. Processing stopped; select an output and start again.")
        }
        var offset: UInt32 = 0
        for stream in inputs.dropLast() {
            let format = try scalar(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
            offset += format.mChannelsPerFrame
        }
        guard offset == inputOffset else {
            throw AudioFailure(message: "The audio route's channel layout changed. Processing stopped; select an output and start again.")
        }
        try Self.validateStereoFormat(try scalar(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription()), rate: sampleRate)
        for stream in [tapStream] + outputs {
            try Self.validateStereoFormat(try scalar(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()), rate: sampleRate)
        }
    }
}
