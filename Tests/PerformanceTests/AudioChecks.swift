import CoreAudio
import Foundation

@MainActor func checkAudioFormatsAndSettings() throws {
    func stereoFormat(rate: Double, planar: Bool) -> AudioStreamBasicDescription {
        let bytes: UInt32 = planar ? 4 : 8
        return AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    }
    for rate in [32000.0, 44100, 48000, 96000, 192000] {
        for planar in [false, true] {
            var format = stereoFormat(rate: rate, planar: planar)
            try AudioRoute.validateStereoFormat(format, rate: rate)
            // HAL may omit Packed when the frame byte size already implies it.
            format.mFormatFlags &= ~kAudioFormatFlagIsPacked
            try AudioRoute.validateStereoFormat(format, rate: rate)
        }
    }
    let valid = stereoFormat(rate: 48000, planar: false)
    let mutations: [(inout AudioStreamBasicDescription) -> Void] = [
        { $0.mFormatID = kAudioFormatMPEG4AAC },
        { $0.mFormatFlags &= ~kAudioFormatFlagIsFloat },
        { $0.mFormatFlags ^= kAudioFormatFlagIsBigEndian },
        { $0.mBitsPerChannel = 64 },
        { $0.mBytesPerFrame = 16; $0.mBytesPerPacket = 16 },
        { $0.mBytesPerPacket = 16 },
        { $0.mFramesPerPacket = 2 },
        { $0.mChannelsPerFrame = 1 },
        { $0.mChannelsPerFrame = 6 },
        { $0.mFormatFlags |= kAudioFormatFlagIsNonInterleaved },
        { $0.mSampleRate = .nan },
        { $0.mSampleRate = .infinity },
        { $0.mSampleRate = 22050 },
        { $0.mSampleRate = 192001 }
    ]
    for mutate in mutations {
        var format = valid
        mutate(&format)
        do {
            try AudioRoute.validateStereoFormat(format)
            fatalError("Unsupported audio format was accepted")
        } catch let failure as AudioFailure {
            require(failure.message.contains("output format"), "Format rejection must explain how to recover")
        }
    }
    do {
        try AudioRoute.validateStereoFormat(valid, rate: 44100)
        fatalError("A changed stream sample rate was accepted")
    } catch is AudioFailure { }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-audio-checks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    for invalidDevice in [false, true] {
        let file = directory.appendingPathComponent("\(invalidDevice).json")
        var settings = Settings()
        settings.selectedUID = "fixture-output"
        settings.startEQAutomatically = true
        settings.devices[settings.selectedUID] = Profile()
        settings.presets["Valid fixture"] = Profile()
        var invalid = Profile()
        invalid.preamp = 24 // Graphic profiles only permit -24...0 dB.
        if invalidDevice { settings.devices[settings.selectedUID] = invalid }
        else { settings.presets["Broken fixture"] = invalid }
        try JSONEncoder().encode(settings).write(to: file)
        let model = Model(settingsFile: file, readLoginStatus: { .notRegistered })
        require(model.error?.contains("invalid gain or preamp") == true, "Corrupt saved profiles must report validation failure")
        require(model.presetProfile(named: "Valid fixture") == nil && model.presetProfile(named: "Broken fixture") == nil,
                "A rejected settings file must not leave its library available to later actions")
        require(!model.startEQAutomatically && !model.running && !model.route.hasResources,
                "A rejected settings file must never arm automatic audio startup")
        model.select("fixture-output")
        require(model.profile == Profile(), "Output selection must not retrieve a rejected saved profile")
    }
    let stopped = Model(settingsFile: directory.appendingPathComponent("stop.json"), readLoginStatus: { .notRegistered })
    let submissions = PrecisionSubmissionCoordinator()
    var submissionCount = 0
    submissions.activate(UUID()) { submissionCount += 1; return .rejected }
    stopped.running = true // No hardware route is opened in this control-state test.
    stopped.error = "Correct the pending number."
    stopped.meter.update(0.2)
    let profile = stopped.profile, revision = stopped.editRevision
    stopped.toggleProcessing { submissions.submitActive() != .rejected }
    require(!stopped.running && stopped.meter.peak == 0 && submissionCount == 0,
            "Stop must release processing without submitting a rejected numeric draft")
    require(stopped.profile == profile && stopped.editRevision == revision && stopped.error == "Correct the pending number.",
            "Stopping must preserve the numeric editing context and validation notice")
    stopped.toggleProcessing { submissions.submitActive() != .rejected }
    require(!stopped.running && !stopped.route.hasResources && submissionCount == 1,
            "Start must still reject invalid pending input before touching audio")
    print("PASS native interleaved/planar audio formats, byte layout and rate rejection, transactional settings, and Stop with rejected numeric input")
}
