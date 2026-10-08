import AppKit
import CoreAudio
import Foundation
import Combine

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
    stopped.meter.update(0.2, reductionDB: 6)
    let profile = stopped.profile, revision = stopped.editRevision
    stopped.toggleProcessing { submissions.submitActive() != .rejected }
    require(!stopped.running && stopped.meter.peak == 0 && stopped.meter.reductionDB == 0 && submissionCount == 0,
            "Stop must release processing without submitting a rejected numeric draft")
    require(stopped.profile == profile && stopped.editRevision == revision && stopped.error == "Correct the pending number.",
            "Stopping must preserve the numeric editing context and validation notice")
    stopped.toggleProcessing { submissions.submitActive() != .rejected }
    require(!stopped.running && !stopped.route.hasResources && submissionCount == 1,
            "Start must still reject invalid pending input before touching audio")
    print("PASS native interleaved/planar audio formats, byte layout and rate rejection, transactional settings, and Stop with rejected numeric input")
}

@MainActor func checkPeakProtectionSettings() throws {
    let legacy = try JSONDecoder().decode(Settings.self, from: Data(#"{"devices":{},"presets":{},"selectedUID":""}"#.utf8))
    require(Settings().peakProtectionEnabled && legacy.peakProtectionEnabled,
            "Peak protection must remain enabled for new and existing installations")
    for invalid in [#""off""#, "0", "{}"] {
        let data = Data("{\"devices\":{},\"presets\":{},\"selectedUID\":\"\",\"peakProtectionEnabled\":\(invalid)}".utf8)
        do {
            _ = try JSONDecoder().decode(Settings.self, from: data)
            fatalError("Malformed peak-protection preferences must be rejected")
        } catch is DecodingError { }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-protection-checks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("settings.json")
    var settings = legacy
    settings.selectedUID = "fixture-output"
    settings.devices[settings.selectedUID] = Profile(gains: [1,2,3,4,5,6,7,8,9,10], preamp: -12.3456789)
    settings.presets["Fixture"] = settings.devices[settings.selectedUID]
    settings.selectedPresets = [settings.selectedUID: "Fixture"]
    settings.favoritePresets = ["Fixture"]
    try JSONEncoder().encode(settings).write(to: file)
    let model = Model(settingsFile: file, readLoginStatus: { .notRegistered })
    model.select(settings.selectedUID)
    model.setPreamp(-13.1234567)
    model.captureComparison()
    model.setBypass(true)
    model.running = true // No hardware route is opened in this control-state test.
    model.error = "Correct the pending number."
    let before = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
    let profile = model.profile, revision = model.editRevision, title = model.currentPresetTitle
    let undo = model.undoLabel, comparison = model.comparisonLabel
    let published = model.$peakProtectionEnabled.dropFirst().sink { enabled in
        let saved = try! JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
        require(saved.peakProtectionEnabled == enabled, "Save protection before publishing or changing live audio")
    }
    for enabled in [false, true, false] {
        model.meter.update(0.5, reductionDB: 6)
        model.setPeakProtection(enabled)
        require(model.peakProtectionEnabled == enabled, "Protection must be changeable while running or bypassed")
        require(enabled || model.meter.reductionDB == 0, "Off must immediately clear stale gain reduction")
        let saved = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
        require(saved.peakProtectionEnabled == enabled && saved.devices == before.devices && saved.presets == before.presets
                && saved.selectedUID == before.selectedUID && saved.selectedPresets == before.selectedPresets
                && saved.favoritePresets == before.favoritePresets && saved.startEQAutomatically == before.startEQAutomatically,
                "Protection must preserve saved profiles, preset identity, favorites, outputs and startup")
        require(model.profile == profile && model.editRevision == revision && model.currentPresetTitle == title
                && model.undoLabel == undo && model.comparisonLabel == comparison && model.running && model.bypass
                && model.error == "Correct the pending number.",
                "Protection must preserve edits, history, comparison, bypass, playback and draft validation")
    }
    published.cancel()
    let restored = Model(settingsFile: file, readLoginStatus: { .notRegistered })
    require(!restored.peakProtectionEnabled && !restored.running && !restored.route.hasResources,
            "Saved Off must survive restart without starting a route")
    model.undoProfile()
    require(!model.peakProtectionEnabled, "Undoing EQ must not change global protection")
    model.selectComparison(.b)
    require(!model.peakProtectionEnabled, "A/B must not change global protection")
    model.select("other-output")
    require(!model.peakProtectionEnabled, "Changing outputs must retain protection")
    model.apply("Fixture") // The invented output is disconnected, so no audio can start.
    require(!model.peakProtectionEnabled, "Applying a preset must not re-enable protection")

    let blockedParent = directory.appendingPathComponent("file-as-directory")
    try Data("fixture".utf8).write(to: blockedParent)
    let blocked = Model(settingsFile: blockedParent.appendingPathComponent("settings.json"), readLoginStatus: { .notRegistered })
    blocked.setPeakProtection(false)
    require(blocked.peakProtectionEnabled && blocked.error?.contains("Could not save peak protection:") == true,
            "A failed save must keep protection enabled and display the failure")
    print("PASS protection defaults, migration, malformed settings, persistence, save failure, meter reset, and independence from presets, output, history and A/B")
}

@MainActor func checkOutputFollowingAndLevelMatching() throws {
    for key in ["followSystemOutput", "matchLevels"] {
        let data = Data("{\"devices\":{},\"presets\":{},\"selectedUID\":\"\",\"\(key)\":\"on\"}".utf8)
        do {
            _ = try JSONDecoder().decode(Settings.self, from: data)
            fatalError("Malformed \(key) preferences must be rejected")
        } catch is DecodingError { }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-follow-checks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("settings.json")
    var settings = Settings()
    settings.selectedUID = "fixture-output"
    settings.devices[settings.selectedUID] = Profile(preamp: -6)
    try JSONEncoder().encode(settings).write(to: file)
    let model = Model(settingsFile: file, readLoginStatus: { .notRegistered })
    model.select(settings.selectedUID)
    require(!model.matchLevels && model.levelMatch == .none, "Level matching must start off")

    let published = model.$matchLevels.dropFirst().sink { enabled in
        let saved = try! JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
        require(saved.matchLevels == enabled, "Save level matching before publishing or changing live audio")
    }
    model.setMatchLevels(true)
    require(model.levelMatch.eqOffsetDB == 0 && abs(model.levelMatch.bypassGainDB + 6) < 0.01, "Bypass must match the EQ's estimated loudness")
    model.setBypass(true)
    require(model.bypass && abs(model.levelMatch.bypassGainDB + 6) < 0.01, "Bypass must keep the matched level")
    model.setBypass(false)
    model.captureComparison()
    model.setPreamp(-12)
    require(model.levelMatch.eqOffsetDB == 0 && abs(model.levelMatch.bypassGainDB + 12) < 0.01, "The quieter A/B version plays unchanged")
    model.selectComparison(model.comparisonSlot == .a ? .b : .a)
    require(abs(model.profile.preamp + 6) < 0.0001 && abs(model.levelMatch.eqOffsetDB + 6) < 0.01
            && abs(model.levelMatch.bypassGainDB + 12) < 0.01, "The louder A/B version must play at the quieter one's level")
    let saved = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
    require(saved.devices["fixture-output"]?.preamp == model.profile.preamp, "Level matching must never change the saved preamp")
    model.undoProfile()
    require(model.levelMatch == LevelMatch(current: model.profile, comparedWith: model.otherComparisonProfile), "Undo must recalculate matching")
    model.setMatchLevels(false)
    require(model.levelMatch == .none, "Off must restore unmatched playback")
    published.cancel()
    model.setMatchLevels(true)
    let restored = Model(settingsFile: file, readLoginStatus: { .notRegistered })
    require(restored.matchLevels && !restored.followSystemOutput && !restored.running && !restored.route.hasResources,
            "Saved level matching must survive restart without starting a route")

    // Sleep releases running EQ and waits to resume on the same output; Stop ends the wait.
    model.running = true // No hardware route is opened in this control-state test.
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    require(!model.running && model.waitingForOutput && model.startupNotice?.contains("paused for sleep") == true,
            "Sleep must pause running EQ and wait to resume it")
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    require(model.waitingForOutput && model.startupNotice?.contains("Resuming EQ") == true, "Wake must schedule the resume")
    model.toggleProcessing()
    require(!model.running && !model.waitingForOutput && model.startupNotice == nil, "Stop must cancel a pending resume")
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    require(!model.waitingForOutput, "Sleep must not start EQ that was off")

    // Following moves to the current macOS output without starting stopped EQ.
    let followed = model.$followSystemOutput.dropFirst().sink { enabled in
        let saved = try! JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
        require(saved.followSystemOutput == enabled, "Save following before publishing or switching outputs")
    }
    model.setFollowSystemOutput(true)
    if let system = try AudioRoute.systemOutput(), model.devices.contains(where: { $0.uid == system.uid }) {
        require(model.selectedUID == system.uid, "Following must select the current macOS output")
    } else {
        require(model.selectedUID == "fixture-output", "An unsupported macOS output must not replace the selected output")
    }
    require(!model.running && !model.route.hasResources, "Following must not start EQ that was off")
    model.setFollowSystemOutput(false)
    followed.cancel()

    let blockedParent = directory.appendingPathComponent("file-as-directory")
    try Data("fixture".utf8).write(to: blockedParent)
    let blocked = Model(settingsFile: blockedParent.appendingPathComponent("settings.json"), readLoginStatus: { .notRegistered })
    blocked.setMatchLevels(true)
    blocked.setFollowSystemOutput(true)
    require(!blocked.matchLevels && !blocked.followSystemOutput && blocked.error?.contains("Could not save output following:") == true,
            "A failed save must keep both options off and display the failure")
    print("PASS output following and level matching defaults, malformed settings, persistence, A/B offsets, sleep pause, wake, Stop, and save failure")
}
