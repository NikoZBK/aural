import CoreAudio
import Foundation
import DSP
import Mixer

struct CoreAudioFailure: LocalizedError {
    let status: OSStatus
    let action: String
    var objectID: AudioObjectID? = nil
    var isUnavailableObject: Bool { status == kAudioHardwareBadDeviceError || status == kAudioHardwareBadObjectError }
    var statusDescription: String {
        let code = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
        let fourCC = bytes.allSatisfy { (32...126).contains($0) } ? String(bytes: bytes, encoding: .ascii) : nil
        return fourCC.map { "\(status) ('\($0)')" } ?? String(status)
    }
    var diagnosticDescription: String {
        "\(action): Core Audio \(statusDescription)" + (objectID.map { ", object=\($0)" } ?? "")
    }
    var errorDescription: String? {
        let reason = "\(action) failed (Core Audio \(statusDescription))."
        if status == kAudioDevicePermissionsError {
            return reason + " Enable Aural in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen it."
        }
        if isUnavailableObject { return reason + " The audio device or route is no longer available. Reconnect the output or select another output and start EQ." }
        return reason
    }
}

func check(_ status: OSStatus, _ action: String, objectID: AudioObjectID? = nil) throws {
    guard status == noErr else { throw CoreAudioFailure(status: status, action: action, objectID: objectID) }
}
func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
    var value = initial, size = UInt32(MemoryLayout<T>.size), a = address(selector, scope)
    try withUnsafeMutablePointer(to: &value) { pointer in
        try check(AudioObjectGetPropertyData(id, &a, 0, nil, &size, pointer), "Read audio property", objectID: id)
    }
    return value
}
func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
    var a = address(selector, scope), size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size), "Read audio list size", objectID: id)
    var result = [AudioObjectID](repeating: 0, count: Int(size)/MemoryLayout<AudioObjectID>.size)
    if size > 0 { try check(AudioObjectGetPropertyData(id, &a, 0, nil, &size, &result), "Read audio list", objectID: id) }
    return result
}
func audioString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size), a = address(selector)
    try check(AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value), "Read device name", objectID: id)
    guard let value else { throw AudioFailure(message: "Core Audio returned an empty device name.") }
    return value.takeRetainedValue() as String
}
struct OutputDevice: Identifiable, Equatable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

/// Injectable HAL cleanup calls let regression tests exercise every failure path
/// without opening a real audio route or requiring recording permission.
struct AudioRouteCleanup {
    var stop: (AudioObjectID, AudioDeviceIOProcID) -> OSStatus
    var destroyCallback: (AudioObjectID, AudioDeviceIOProcID) -> OSStatus
    var destroyAggregate: (AudioObjectID) -> OSStatus
    var destroyTap: (AudioObjectID) -> OSStatus

    static let live = AudioRouteCleanup(
        stop: { AudioDeviceStop($0, $1) },
        destroyCallback: { AudioDeviceDestroyIOProcID($0, $1) },
        destroyAggregate: { AudioHardwareDestroyAggregateDevice($0) },
        destroyTap: { id in
            if #available(macOS 14.2, *) { return AudioHardwareDestroyProcessTap(id) }
            return kAudioHardwareUnsupportedOperationError
        })
}

@MainActor final class AudioRoute {
    private static let logger = AuralLog.audio
    private let cleanup: AudioRouteCleanup
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    private var dsp: OpaquePointer?
    private var mixer: OpaquePointer?
    private let mixerTopology = AppMixerTopology()
    private var mixerToken: UInt64?
    private var startSerial: UInt64 = 0
    private var mixerTapStreams: [AudioObjectID] = []
    private var mixerChannels: [UInt32] = []
    private(set) var appMixerAvailable = false
    var onMixerState: (([String?], [Float]) -> Void)?
    var onMixerFailure: ((Error) -> Void)?
    private var inputStreams: [AudioObjectID] = []
    private var outputStreams: [AudioObjectID] = []
    private var inputOffset: UInt32 = 0
    private(set) var device: OutputDevice?
    private(set) var sampleRate = 48000.0
    /// Loudness compensation, after the profile's filters. The next update or start applies it.
    var loudness: [EQFilter] = []
    /// The band playing alone, after everything else. The next update or start applies it; Stop ends it.
    var solo: Int?
    var hasResources: Bool { tap != 0 || aggregate != 0 || proc != nil || dsp != nil || mixer != nil || mixerTopology.hasResources }
    init(cleanup: AudioRouteCleanup = .live) {
        self.cleanup = cleanup
        mixerTopology.onState = { [weak self] token, slots, peaks in
            guard let self, self.mixerToken == token else { return }
            self.onMixerState?(slots, peaks)
        }
        mixerTopology.onFailure = { [weak self] token, error in
            guard let self, self.mixerToken == token else { return }
            self.onMixerFailure?(error)
        }
    }
    func setAppControls(_ preferences: AppMixerPreferences) { mixerTopology.controls(preferences) }
    func discoverAppAudio(_ catalog: AppAudioCatalog) { mixerTopology.discover(catalog) }
    /// What the engine runs for a profile: its filters and tilt, loudness compensation, then any solo.
    func engineFilters(for profile: Profile) -> [EQFilter] {
        var filters = profile.dspFilters(rate: sampleRate) + loudness
        if let solo, let filter = profile.soloFilter(band: solo, rate: sampleRate) { filters.append(filter) }
        return filters
    }
    func readMeter() -> AudioMeterReading {
        guard let dsp else { return AudioMeterReading() }
        let reading = eq_read_meter(dsp)
        return AudioMeterReading(peak: reading.peak, reductionDB: reading.reductionDB,
                                 inputPeak: reading.inputPeak, postEQPeak: reading.postEQPeak)
    }
    var faults: UInt32 { (dsp.map(eq_faults) ?? 0) &+ (mixer.map { am_counters($0).faults } ?? 0) }
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
            } catch let failure as CoreAudioFailure where failure.isUnavailableObject {
                // Device/stream IDs can expire between enumeration and property
                // reads. A disconnected device must not hide the healthy outputs.
                logger.notice("Skipped unavailable audio device \(id, privacy: .public): \(failure.diagnosticDescription, privacy: .public)")
                return nil
            } catch let failure as CoreAudioFailure where failure.status == kAudioHardwareUnknownPropertyError {
                // Hot unplug can remove a stream property before HAL reports
                // !obj/!dev. Do not reinterpret every unsupported property as a
                // disconnect: prove that this device or stream has vanished.
                if try outputSnapshotExpired(id, failure: failure) {
                    logger.notice("Skipped changed output snapshot \(id, privacy: .public): \(failure.diagnosticDescription, privacy: .public)")
                    return nil
                }
                throw failure
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func outputSnapshotExpired(_ output: AudioObjectID, failure: CoreAudioFailure,
                                      readDevices: () throws -> [AudioObjectID] = { try ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) },
                                      readStreams: (AudioObjectID) throws -> [AudioObjectID] = { try ids($0, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput) }) throws -> Bool {
        guard failure.status == kAudioHardwareUnknownPropertyError else { return false }
        do {
            let current = try readDevices()
            if !current.contains(output) { return true }
            guard let object = failure.objectID, object != output else { return false }
            return try !readStreams(output).contains(object)
        } catch let changed as CoreAudioFailure where changed.isUnavailableObject { return true }
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
    func start(_ output: OutputDevice, profile: Profile, bypass: Bool, peakProtectionEnabled: Bool, levelMatch: LevelMatch = .none,
               appPreferences: AppMixerPreferences = AppMixerPreferences()) async throws {
        let transport: UInt32
        do { transport = try scalar(output.id, kAudioDevicePropertyTransportType, UInt32(0)) }
        catch {
            // The caller reports audio as stopped, so nothing may survive this
            // failure: not the previous route, and not a kept protection mute.
            let original = error.localizedDescription
            do { try stop() } catch { throw AudioFailure(message: original + " Cleanup: " + error.localizedDescription) }
            throw error
        }
        if transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate {
            // Explicit capability path: retain existing global EQ on virtual
            // outputs, with app controls visibly inactive for this output.
            try startLegacy(output, profile: profile, bypass: bypass, peakProtectionEnabled: peakProtectionEnabled, levelMatch: levelMatch)
            return
        }
        guard #available(macOS 14.2, *) else { try stop(); throw AudioFailure(message: "Aural requires macOS 14.2 or newer.") }
        do { try stop(keepingMixerGuard: true) }
        catch {
            // A partial cleanup must not leave the protection mute armed.
            let original = error.localizedDescription
            do { try stop() } catch { throw AudioFailure(message: original + " Cleanup: " + error.localizedDescription) }
            throw error
        }
        startSerial &+= 1; let token = startSerial
        do {
            let formatStreams = try ids(output.id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            guard formatStreams.count == 1 else { throw AudioFailure(message: "App mixing requires one stereo output stream.") }
            let format = try scalar(formatStreams[0], kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
            try Self.validateStereoFormat(format); sampleRate = format.mSampleRate
            let config: [String: Any] = [kAudioAggregateDeviceNameKey: "Aural Private Audio",
                kAudioAggregateDeviceUIDKey: "local.aural.\(UUID().uuidString)", kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]]]
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "Create private mixer route")
            let layout = try await mixerTopology.prepare(aggregate: aggregate, output: output, preferences: appPreferences)
            guard startSerial == token else { throw CancellationError() }
            inputStreams = layout.inputStreams; mixerTapStreams = layout.tapStreams
            outputStreams = try ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            for stream in layout.tapStreams + outputStreams {
                try Self.validateStereoFormat(try scalar(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()), rate: sampleRate)
            }
            var channels = [UInt32](repeating: 0, count: 32), count: UInt32 = 0
            try check(am_stream_channels(aggregate, &channels, UInt32(channels.count), &count), "Validate mixer callback inputs")
            mixerChannels = Array(channels.prefix(Int(count)))
            guard let engine = eq_create(sampleRate, 0) else { throw AudioFailure(message: "Cannot allocate the equalizer.") }
            dsp = engine; loggedSignalFaults = 0
            setPeakProtection(peakProtectionEnabled); try update(profile, bypass: bypass, levelMatch: levelMatch)
            guard let context = am_create(sampleRate, engine, layout.offsets, UInt32(layout.offsets.count), layout.gains) else {
                throw AudioFailure(message: "Cannot allocate the bounded app mixer.")
            }
            mixer = context; mixerToken = try mixerTopology.install(context)
            try check(AudioDeviceCreateIOProcID(aggregate, am_callback, UnsafeMutableRawPointer(context), &proc), "Create app mixer callback")
            guard let proc else { throw AudioFailure(message: "Core Audio returned no mixer callback.") }
            if inputStreams.count > layout.tapStreams.count {
                let enabled: [UInt32] = inputStreams.map { layout.tapStreams.contains($0) ? 1 : 0 }
                try check(am_enable_inputs(aggregate, proc, enabled, UInt32(enabled.count)), "Exclude hardware inputs from app mixing")
            }
            try check(AudioDeviceStart(aggregate, proc), "Start app mixing and EQ")
            device = output; appMixerAvailable = true
        } catch {
            guard startSerial == token else { throw CancellationError() }
            let original = error.localizedDescription
            do { try stop() } catch { throw AudioFailure(message: original + " Cleanup: " + error.localizedDescription) }
            throw error
        }
    }
    private func startLegacy(_ output: OutputDevice, profile: Profile, bypass: Bool, peakProtectionEnabled: Bool, levelMatch: LevelMatch = .none) throws {
        try stop()
        guard #available(macOS 14.2, *) else { throw AudioFailure(message: "Aural requires macOS 14.2 or newer.") }
        Self.logger.notice("Starting EQ: output=\(output.name, privacy: .private), device=\(output.id, privacy: .public), bypass=\(bypass, privacy: .public)")
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
            Self.logger.notice("EQ started: device=\(output.id, privacy: .public), tap=\(self.tap, privacy: .public), aggregate=\(self.aggregate, privacy: .public), rate=\(self.sampleRate, privacy: .public)")
        } catch {
            let original = error.localizedDescription
            Self.logger.error("EQ start failed: device=\(output.id, privacy: .public), tap=\(self.tap, privacy: .public), aggregate=\(self.aggregate, privacy: .public): \(AuralLog.describe(error), privacy: .public)")
            do { try stop() } catch { throw AudioFailure(message: original + " Cleanup: " + error.localizedDescription + " Quit Aural to release its route.") }
            throw error
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
        let filters = engineFilters(for: profile)
        var stereo = profile.dspStereo
        // A/B matching lowers playback only; the saved preamp is unchanged.
        let preamp = max(-60, profile.preamp + levelMatch.eqOffsetDB)
        if let dsp, !eq_update_filters_matched(dsp, filters, UInt32(filters.count), preamp, bypass, &stereo, levelMatch.bypassGainDB) {
            throw AudioFailure(message: "The equalizer rejected this setting because a value is out of range.")
        }
    }
    /// Missing HAL objects are already released after a disconnect. Other errors
    /// are reported after all cleanup steps, with surviving handles and their
    /// callback engine kept for a safe retry on the next stop or start.
    func stop(keepingMixerGuard: Bool = false) throws {
        startSerial &+= 1; mixerToken = nil; mixerTopology.invalidate(); appMixerAvailable = false
        solo = nil
        let hadResources = hasResources
        if hadResources {
            Self.logger.notice("Stopping EQ: device=\(self.device?.id ?? 0, privacy: .public), tap=\(self.tap, privacy: .public), aggregate=\(self.aggregate, privacy: .public)")
        }
        var failure: CoreAudioFailure?
        func attempt(_ status: OSStatus, _ action: String, objectID: AudioObjectID, allowsStopped: Bool = false) -> Bool {
            guard status != noErr else { return true }
            let result = CoreAudioFailure(status: status, action: action, objectID: objectID)
            if result.isUnavailableObject || (allowsStopped && status == kAudioHardwareNotRunningError) {
                Self.logger.notice("Cleanup already satisfied: \(result.diagnosticDescription, privacy: .public)")
                return true
            }
            Self.logger.error("Cleanup failed: \(result.diagnosticDescription, privacy: .public)")
            if failure == nil { failure = result }
            return false
        }
        if let proc {
            _ = attempt(cleanup.stop(aggregate, proc), "Stop audio", objectID: aggregate, allowsStopped: true)
            if attempt(cleanup.destroyCallback(aggregate, proc), "Release audio callback", objectID: aggregate) { self.proc = nil }
        }
        if aggregate != 0, attempt(cleanup.destroyAggregate(aggregate), "Release private route", objectID: aggregate) {
            aggregate = 0; proc = nil // The callback belonged to the destroyed device.
        }
        // Free only after the callback is removed or its owning device is gone.
        // An uncertain callback keeps its context alive until cleanup can retry.
        if proc == nil {
            if let mixer { am_destroy(mixer); self.mixer = nil }
            if let dsp { eq_destroy(dsp); self.dsp = nil }
        }
        if tap != 0 {
            if #available(macOS 14.2, *) {
                if attempt(cleanup.destroyTap(tap), "Release audio tap", objectID: tap) { tap = 0 }
            } else { tap = 0 }
        }
        var mixerFailure: Error?
        do { try mixerTopology.release(keepingGuard: keepingMixerGuard, cleanup: cleanup) }
        catch {
            Self.logger.error("App mixer cleanup failed: \(AuralLog.describe(error), privacy: .public)")
            mixerFailure = error
        }
        inputStreams = []; outputStreams = []; inputOffset = 0
        mixerTapStreams = []; mixerChannels = []
        device = nil
        if keepingMixerGuard { mixerToken = mixerTopology.beginWaiting() }
        if hadResources { Self.logger.notice("EQ cleanup finished: resourcesRemaining=\(self.hasResources, privacy: .public)") }
        if let failure {
            if let mixerFailure { throw AudioFailure(message: failure.localizedDescription + " " + mixerFailure.localizedDescription) }
            throw failure
        }
        if let mixerFailure { throw mixerFailure }
    }
    #if AURAL_TESTING
    var hasEngineForTesting: Bool { dsp != nil }
    func adoptMixerTokenForTesting(_ token: UInt64) { mixerToken = token }
    func adoptMixerGuardForTesting(_ protection: AppMixerGuard) { mixerTopology.adoptForTesting(taps: [], protection: protection) }
    func deliverMixerStateForTesting(_ token: UInt64) { mixerTopology.onState?(token, [], []) }
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
            let signalFaults = eq_signal_faults(dsp) &+ (mixer.map { am_counters($0).signalFaults } ?? 0)
            if signalFaults != loggedSignalFaults {
                let replaced = signalFaults &- loggedSignalFaults
                Self.logger.warning("Replaced \(replaced, privacy: .public) non-finite or overflowing audio samples")
                loggedSignalFaults = signalFaults
            }
        }
        let alive = try scalar(device.id, kAudioDevicePropertyDeviceIsAlive, UInt32(0))
        guard alive == 1 else { throw CoreAudioFailure(status: kAudioHardwareBadDeviceError, action: "Check audio output", objectID: device.id) }
        let rate = try scalar(device.id, kAudioDevicePropertyNominalSampleRate, Double(0))
        guard abs(rate - sampleRate) < 1, faults == 0 else {
            throw AudioFailure(message: "The output disconnected or its audio format changed. Processing stopped; select an output and start again.")
        }
        let inputs = try ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        let outputs = try ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard inputs == inputStreams, outputs == outputStreams, let tapStream = inputs.last else {
            throw AudioFailure(message: "The audio route's streams changed. Processing stopped; select an output and start again.")
        }
        if mixer != nil {
            var channels = [UInt32](repeating: 0, count: 32), count: UInt32 = 0
            try check(am_stream_channels(aggregate, &channels, UInt32(channels.count), &count), "Check mixer callback layout")
            guard Array(channels.prefix(Int(count))) == mixerChannels else { throw AudioFailure(message: "The app mixer channel layout changed.") }
            for stream in mixerTapStreams + outputs {
                try Self.validateStereoFormat(try scalar(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()), rate: sampleRate)
            }
            return
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
