import AppKit

@MainActor private func waitForWorker(_ message: String, until complete: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !complete() {
        require(Date() < deadline, message)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

@MainActor func checkAnalysisWorker() throws {
    let worker = EQAnalysisWorker()
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var completed = false
    let first = Task {
        let value = await worker.calculate {
            require(!Thread.isMainThread, "EQ analysis must run outside the main thread")
            started.signal()
            release.wait()
            return 42
        }
        require(value == 42, "Analysis must return its unmodified result")
        completed = true
    }
    waitForWorker("The analysis worker did not start") { started.wait(timeout: .now()) == .success }
    var cancelledCompleted = false
    let cancelled = Task {
        let value: Int? = await worker.calculate { fatalError("A cancelled queued analysis must never run") }
        require(value == nil, "Cancelled analyses must not return a result")
        cancelledCompleted = true
    }
    cancelled.cancel()
    release.signal()
    waitForWorker("Worker completion was not delivered") { completed && cancelledCompleted }
    first.cancel()

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-headroom-worker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let model = Model(settingsFile: directory.appendingPathComponent("settings.json"), readLoginStatus: { .notRegistered })
    let advancedStereo = StereoSettings(leftTrimDB: -3, rightTrimDB: 2, balance: -0.3, width: 1.5,
                                       crossfeed: 0.4, leftDelayMS: 7, rightDelayMS: 11,
                                       invertLeft: true, invertRight: true, mono: true)
    model.setStereoSettings(advancedStereo)
    let beforeReset = model.profile
    model.setStereoSettings(model.profile.stereoSettings.resettingListeningControls())
    let reset = model.profile.stereoSettings
    require(reset.balance == 0 && reset.width == 1 && !reset.mono && reset.crossfeed == 0,
            "Simple Reset must restore the visible listening controls")
    require(reset.leftTrimDB == -3 && reset.rightTrimDB == 2 && reset.leftDelayMS == 7 && reset.rightDelayMS == 11 && reset.invertLeft && reset.invertRight,
            "Simple Reset must preserve advanced trims, delays, and polarity")
    model.undoProfile()
    require(model.profile.hasSameEQ(as: beforeReset), "Simple listening edits must use the shared undo path")
    model.resetStereoSettings()
    model.setGraphicGain(at: 5, to: 8)
    model.bypass = true

    // An occupied worker makes the race deterministic: input remains responsive
    // and a later EQ edit must win over the calculation's captured snapshot.
    let occupied = DispatchSemaphore(value: 0)
    let unblock = DispatchSemaphore(value: 0)
    let blocker = Task {
        _ = await EQAnalysisWorker.shared.calculate {
            occupied.signal()
            unblock.wait()
            return true
        }
    }
    waitForWorker("The shared worker did not start") { occupied.wait(timeout: .now()) == .success }
    model.headroom()
    require(model.calculatingHeadroom, "Auto preamp must show its pending state")
    model.setPreamp(-3)
    let edited = model.profile
    unblock.signal()
    waitForWorker("Headroom did not finish") { !model.calculatingHeadroom }
    require(model.profile == edited && model.error?.contains("The EQ changed while calculating headroom") == true,
            "A late headroom result must preserve the newer edit and explain the conflict")
    blocker.cancel()

    model.setPreamp(-4)
    let expected = Headroom.preamp(for: model.profile, rate: model.responseRate)
    let before = model.profile
    model.headroom()
    model.headroom() // Supersede a queued request; only the current task may apply.
    waitForWorker("Auto preamp did not complete") { !model.calculatingHeadroom }
    require(model.profile.preamp == expected && model.error == nil,
            "The current calculation must apply through the usual validated edit path")
    require(model.bypass && !model.running && !model.route.hasResources && model.canUndo,
            "Auto preamp must preserve bypass and stopped audio and remain undoable")
    model.undoProfile()
    require(model.profile.hasSameEQ(as: before), "Undo must restore the pre-calculation EQ")
    print("PASS background analysis, queued cancellation, pending state, stale headroom protection, supersession, undo, and audio neutrality")
}
