import AppKit
import Combine

@MainActor func checkPerformanceIsolation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-performance-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("settings.json")
    let queryStarted = DispatchSemaphore(value: 0)
    let releaseQuery = DispatchSemaphore(value: 0)
    let model = Model(settingsFile: file, readLoginStatus: {
        require(!Thread.isMainThread, "Login-status XPC must never run on the UI thread")
        queryStarted.signal()
        releaseQuery.wait()
        return .enabled
    })
    require(model.loginStatus == nil, "An unfinished service query must be shown as pending")
    let deadline = Date().addingTimeInterval(5)
    while queryStarted.wait(timeout: .now()) == .timedOut {
        require(Date() < deadline, "The background login-status query did not start")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    // Hold the service indefinitely while exercising the UI; a synchronous read
    // would deadlock here instead of letting metering, timers, and modes proceed.
    defer { releaseQuery.signal() }
    var documentChanges = 0
    var meterChanges = 0
    let documentObservation = model.objectWillChange.sink { documentChanges += 1 }
    let meterObservation = model.meter.objectWillChange.sink { meterChanges += 1 }
    for _ in 0..<100 {
        for peak in [Float(0), 0.1, 0.1, 0.2, 0.2, 0] { model.meter.update(peak) }
    }
    require(documentChanges == 0 && meterChanges == 300,
            "Audio peaks must update only the meter, and identical readings must not publish")
    for reading in [AudioMeterReading(peak: 0.1), AudioMeterReading(peak: 0.1, reductionDB: 6),
                    AudioMeterReading(peak: 0.1, reductionDB: 6), AudioMeterReading(peak: 0.1, reductionDB: 3),
                    AudioMeterReading(peak: 0.2, reductionDB: 0)] { model.meter.update(reading) }
    require(documentChanges == 0 && meterChanges == 304 && model.meter.reductionDB == 0,
            "Gain reduction must refresh with unchanged peaks, publish a reading once, and leave the document alone")
    let overload = AudioMeterReading(peak: 0.98, reductionDB: 8, inputPeak: 0.5, postEQPeak: 2)
    model.meter.update(overload)
    model.meter.update(AudioMeterReading(peak: 0.75, inputPeak: 0.25, postEQPeak: 1))
    require(model.meter.overloadPeak == 2 && model.meter.heldReductionDB == 8,
            "The holds must retain the maximum across quieter readings")
    model.meter.update(overload)
    model.resetLevelHolds()
    require(model.meter.reading == overload && model.meter.overloadPeak == 0 && model.meter.heldReductionDB == 0,
            "Reset must clear the holds while preserving the live reading")
    model.meter.update(overload)
    require(model.meter.overloadPeak == 2 && model.meter.heldReductionDB == 8,
            "A new interval with identical peaks must be able to re-arm both holds")
    model.meter.clearLiveReduction()
    require(model.meter.reading.inputPeak == 0.5 && model.meter.reading.postEQPeak == 2 &&
            model.meter.reductionDB == 0 && model.meter.heldReductionDB == 8,
            "Turning protection off must clear only the live reduction")
    model.meter.clear()
    model.meter.update(AudioMeterReading(peak: 0.98, reductionDB: 0.2, inputPeak: 1, postEQPeak: 1))
    require(model.meter.overloadPeak == 0 && model.meter.heldReductionDB == 0.2 && documentChanges == 0,
            "Limiter action at full scale must not count as overload or publish a document change")
    for _ in 0..<40 { model.endProfileGesture() }
    require(documentChanges == 0, "Disappearing editors must not invalidate the document when no gesture is active")
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    require(documentChanges == 0, "Idle polling must not continually rebuild windows or menus")

    let profile = model.profile
    let revision = model.editRevision
    let output = model.selectedUID
    var publishedModes: [InterfaceMode] = []
    let modes = model.$interfaceMode.dropFirst().sink { mode in
        let saved = try! JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
        require(saved.interfaceMode == mode, "Mode changes must be saved before the panel swaps")
        publishedModes.append(mode)
    }
    for mode in [InterfaceMode.professional, .easy, .professional, .easy] {
        model.setInterfaceMode(mode)
        require(model.interfaceMode == mode && model.error == nil, "Modes must change while the service is blocked")
        require(model.profile == profile && model.editRevision == revision && model.selectedUID == output,
                "Mode switching must preserve EQ and the editing session")
        require(!model.running && !model.route.hasResources, "Mode switching must never create an audio route")
    }
    model.setInterfaceMode(.easy)
    require(publishedModes == [.professional, .easy, .professional, .easy], "Re-selecting a mode must not publish")
    modes.cancel()
    documentObservation.cancel()
    meterObservation.cancel()
    releaseQuery.signal()
    let completion = Date().addingTimeInterval(5)
    while model.loginStatus != .enabled {
        require(Date() < completion, "The login-status result did not reach the main actor")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    let restored = Model(settingsFile: file, readLoginStatus: { .notRegistered })
    require(restored.interfaceMode == .easy, "The chosen interface mode must survive restart")

    let blockedParent = directory.appendingPathComponent("file-as-directory")
    try Data("fixture".utf8).write(to: blockedParent)
    let blocked = Model(settingsFile: blockedParent.appendingPathComponent("settings.json"), readLoginStatus: { .notRegistered })
    blocked.setInterfaceMode(.professional)
    require(blocked.interfaceMode == .easy && blocked.error?.contains("Could not save interface mode:") == true,
            "A failed mode save must keep the accepted panel and display the failure")
    print("PASS meter publication isolation, idle polling, nonblocking service status, mode persistence, save failure, and sound-neutral switching")
}
