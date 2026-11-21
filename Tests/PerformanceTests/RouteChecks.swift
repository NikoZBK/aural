import CoreAudio
import Foundation

@MainActor private final class CleanupFixture {
    var statuses: [String: OSStatus] = [:]
    var calls: [String] = []
    static let steps = ["Stop audio", "Release audio callback", "Release private route", "Release audio tap"]
    func result(_ action: String) -> OSStatus {
        calls.append(action)
        return statuses[action] ?? noErr
    }
    var operations: AudioRouteCleanup {
        AudioRouteCleanup(stop: { [self] _, _ in result(Self.steps[0]) },
                          destroyCallback: { [self] _, _ in result(Self.steps[1]) },
                          destroyAggregate: { [self] _ in result(Self.steps[2]) },
                          destroyTap: { [self] _ in result(Self.steps[3]) })
    }
}

@MainActor private func adoptMissingOutput(_ route: AudioRoute) {
    route.adoptForTesting(tap: 0x7fff_fff1, aggregate: 0x7fff_fff2,
                          device: OutputDevice(id: 0x7fff_fff0, uid: "missing", name: "Missing output"))
}

@MainActor func checkAudioRouteCleanup() throws {
    require(kAudioHardwareBadDeviceError == 560227702, "The reported error must identify a vanished device")
    let disconnected = CoreAudioFailure(status: kAudioHardwareBadDeviceError, action: "Stop audio")
    require(disconnected.statusDescription == "560227702 ('!dev')" && disconnected.isUnavailableObject,
            "Diagnostics must include the numeric and four-character status")
    for status in [kAudioHardwareBadDeviceError, kAudioHardwareBadObjectError, kAudioHardwareUnspecifiedError] {
        require(!CoreAudioFailure(status: status, action: "Stop audio").localizedDescription.contains("Privacy"),
                "A route failure must not be presented as denied recording permission")
    }
    require(CoreAudioFailure(status: kAudioDevicePermissionsError, action: "Start equalization").localizedDescription.contains("Screen & System Audio Recording"),
            "Permission failures must retain actionable recording settings advice")
    require(CoreAudioFailure(status: -1, action: "Start equalization").statusDescription == "-1",
            "Non-printable status bytes must use the numeric code")

    // Exercise real HAL responses to expired IDs, without opening hardware.
    let vanished = AudioRoute()
    adoptMissingOutput(vanished)
    try vanished.stop()
    require(!vanished.hasResources && !vanished.hasEngineForTesting && vanished.device == nil,
            "A vanished route must release its handles and engine gracefully")
    try vanished.stop()

    for status in [noErr, kAudioHardwareBadDeviceError, kAudioHardwareBadObjectError] {
        let fixture = CleanupFixture()
        fixture.statuses = Dictionary(uniqueKeysWithValues: CleanupFixture.steps.map { ($0, status) })
        let route = AudioRoute(cleanup: fixture.operations)
        adoptMissingOutput(route)
        try route.stop()
        require(fixture.calls == CleanupFixture.steps && !route.hasResources && !route.hasEngineForTesting,
                "Cleanup must attempt every step and accept objects that are already gone")
        fixture.calls = []
        try route.stop()
        require(fixture.calls.isEmpty, "Repeated cleanup must not reuse released handles")
    }
    let stopped = CleanupFixture()
    stopped.statuses["Stop audio"] = kAudioHardwareNotRunningError
    let stoppedRoute = AudioRoute(cleanup: stopped.operations)
    adoptMissingOutput(stoppedRoute)
    try stoppedRoute.stop()
    require(stopped.calls == CleanupFixture.steps && !stoppedRoute.hasResources, "An already stopped callback still needs full destruction")

    // An unexpected error at any step must be surfaced after subsequent steps.
    // 'stop' is benign only for stopping, never for destroying resources.
    for status in [kAudioHardwareUnspecifiedError, kAudioHardwareNotRunningError] {
        for step in CleanupFixture.steps where !(status == kAudioHardwareNotRunningError && step == "Stop audio") {
            let fixture = CleanupFixture()
            fixture.statuses[step] = status
            let route = AudioRoute(cleanup: fixture.operations)
            adoptMissingOutput(route)
            do { try route.stop(); fatalError("Unexpected cleanup errors must be reported") }
            catch let failure as CoreAudioFailure {
                require(failure.action == step && failure.status == status, "Cleanup must retain its first genuine failure")
            }
            require(fixture.calls == CleanupFixture.steps && route.device == nil, "One failure must never skip later cleanup steps")
            let retainsHandle = step == "Release private route" || step == "Release audio tap"
            require(route.hasResources == retainsHandle && !route.hasEngineForTesting,
                    "Only unsuccessful releases stay pending after the callback is removed")
            fixture.statuses = [:]; fixture.calls = []
            try route.stop()
            require(fixture.calls == (retainsHandle ? [step] : []) && !route.hasResources, "Cleanup must retry exactly the remaining handles")
        }
    }

    let uncertain = CleanupFixture()
    uncertain.statuses = Dictionary(uniqueKeysWithValues: CleanupFixture.steps.prefix(3).map { ($0, kAudioHardwareUnspecifiedError) })
    let uncertainRoute = AudioRoute(cleanup: uncertain.operations)
    adoptMissingOutput(uncertainRoute)
    do { try uncertainRoute.stop(); fatalError("An uncertain callback must report its failure") }
    catch let failure as CoreAudioFailure { require(failure.action == "Stop audio", "Report the first failure") }
    require(uncertain.calls == CleanupFixture.steps && uncertainRoute.hasResources && uncertainRoute.hasEngineForTesting,
            "Keep the engine alive for an uncertain callback, but still release the muting tap")
    uncertain.statuses = [:]; uncertain.calls = []
    try uncertainRoute.stop()
    require(uncertain.calls == Array(CleanupFixture.steps.prefix(3)) && !uncertainRoute.hasResources && !uncertainRoute.hasEngineForTesting,
            "A later retry must reclaim the retained engine after the callback is gone")
    print("PASS expired HAL IDs, decoded status codes, permission-specific advice, complete cleanup, genuine failures, retained callback context, and safe retries")
}

@MainActor func checkDisconnectedOutputRecovery() throws {
    let vanishedProperty = CoreAudioFailure(status: kAudioHardwareUnknownPropertyError, action: "Read audio property", objectID: 94)
    let removedOutput = try AudioRoute.outputSnapshotExpired(93, failure: vanishedProperty, readDevices: { [81] }, readStreams: { _ in [] })
    require(removedOutput,
            "An unknown property on a removed output must be treated as an expired discovery snapshot")
    let removedStream = try AudioRoute.outputSnapshotExpired(93, failure: vanishedProperty, readDevices: { [93] }, readStreams: { _ in [95] })
    require(removedStream,
            "A stream can vanish before its device leaves the HAL list")
    let stableStream = try AudioRoute.outputSnapshotExpired(93, failure: vanishedProperty, readDevices: { [93] }, readStreams: { _ in [94] })
    require(!stableStream,
            "A genuinely unsupported property on a current stream must remain an error")
    do {
        _ = try AudioRoute.outputSnapshotExpired(93, failure: vanishedProperty, readDevices: { throw CoreAudioFailure(status: kAudioDevicePermissionsError, action: "Read devices") })
        fatalError("A permission failure during discovery revalidation must propagate")
    } catch let error as CoreAudioFailure { require(error.status == kAudioDevicePermissionsError, "Keep the original revalidation error") }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-route-checks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let model = Model(settingsFile: directory.appendingPathComponent("settings.json"), readLoginStatus: { .notRegistered })
    let discoveryTime = Date()
    let unsettled = try model.readAvailableOutputsForTesting(now: discoveryTime, read: { throw vanishedProperty })
    require(unsettled == nil && model.error == nil, "A stale HAL list must get a bounded incomplete-snapshot interval")
    let stillUnsettled = try model.readAvailableOutputsForTesting(now: discoveryTime.addingTimeInterval(1), read: { throw vanishedProperty })
    require(stillUnsettled == nil, "The incomplete snapshot must never masquerade as no devices")
    do {
        _ = try model.readAvailableOutputsForTesting(now: discoveryTime.addingTimeInterval(2), read: { throw vanishedProperty })
        fatalError("Persistent unsupported properties must not be hidden by retry")
    } catch let error as CoreAudioFailure { require(error.status == kAudioHardwareUnknownPropertyError, "Preserve the persistent error") }
    let recovered = try model.readAvailableOutputsForTesting(now: discoveryTime.addingTimeInterval(3), read: { [] })
    require(recovered == [], "Only a complete successful snapshot may report no devices")
    do {
        _ = try model.readAvailableOutputsForTesting(now: discoveryTime, read: { throw CoreAudioFailure(status: kAudioDevicePermissionsError, action: "Discover outputs") })
        fatalError("Permission failures must not receive metadata grace")
    } catch let error as CoreAudioFailure { require(error.status == kAudioDevicePermissionsError, "Preserve permission advice") }
    model.select("missing")
    model.setPreamp(-6)
    model.setBypass(true)
    let profile = model.profile, revision = model.editRevision
    adoptMissingOutput(model.route)
    model.running = true
    model.meter.update(AudioMeterReading(peak: 0.2, reductionDB: 6, inputPeak: 0.5, postEQPeak: 2))
    model.pollOutputForTesting()
    require(!model.running && model.waitingForOutput && model.error == nil && !model.route.hasResources,
            "Unplugging must pause EQ and wait for the same output without a cleanup error")
    require(model.startupNotice == "Missing output disconnected. EQ resumes when it reconnects." && model.selectedUID == "missing",
            "A disconnected output must retain its identity and explain reconnection")
    model.pollOutputForTesting()
    require(model.waitingForOutput && model.meter.reading == AudioMeterReading() &&
            model.meter.overloadPeak == 0 && model.meter.heldReductionDB == 0 && model.error == nil,
            "A disconnected route must clear all live levels and holds")
    require(model.profile == profile && model.bypass && model.editRevision == revision,
            "Disconnect recovery must preserve the profile, Bypass, and editing state")
    model.toggleProcessing()
    model.pollOutputForTesting()
    require(!model.running && !model.waitingForOutput && model.startupNotice == nil && model.error == nil,
            "Stop must cancel the reconnect wait without a misleading failure")

    // HAL may invalidate an ID before enumeration drops it. Repeated physical
    // disconnects must not consume the format-restart limit or turn into errors.
    for _ in 0..<2 {
        adoptMissingOutput(model.route)
        model.devices = [model.route.device!]
        model.running = true
        model.checkRunningRouteForTesting()
        require(!model.running && model.waitingForOutput && model.error == nil && !model.route.hasResources
                && model.startupNotice?.contains("disconnected") == true,
                "A stale enumeration must recover as a disconnect, even twice within the restart window")
        model.stop()
    }
    adoptMissingOutput(model.route)
    model.devices = []
    model.running = true
    model.route.onMixerFailure?(CoreAudioFailure(status: kAudioHardwareBadObjectError, action: "Check mixer tap", objectID: 123))
    require(!model.running && model.waitingForOutput && model.appMixer.waiting && model.error == nil,
            "Asynchronous mixer loss must use the same saved-output recovery instead of releasing all protection as a fatal error")
    model.stop()
    adoptMissingOutput(model.route)
    model.devices = [model.route.device!]
    model.running = true
    model.pollOutputForTesting(readOutputs: { throw vanishedProperty })
    require(!model.running && model.waitingForOutput && model.error == nil,
            "Incomplete device discovery must still verify the running route and enter saved-output recovery")
    model.stop()
    for _ in 0..<3 {
        adoptMissingOutput(model.route)
        model.devices = [model.route.device!]
        model.running = true
        _ = try model.readAvailableOutputsForTesting(now: discoveryTime, read: { throw vanishedProperty })
        model.route.onMixerFailure?(CoreAudioFailure(status: kAudioHardwareUnknownPropertyError, action: "Check output", objectID: model.route.device!.id))
        require(model.waitingForOutput && model.startupNotice?.contains("disconnected") == true && model.error == nil,
                "A vanished output during incomplete discovery must not consume the format-restart budget")
        model.stop()
    }
    model.running = true
    model.route.onMixerFailure?(AudioFailure(message: "App mixer capacity exceeded"))
    require(!model.running && !model.waitingForOutput && model.error == "App mixer capacity exceeded",
            "Capacity and ownership failures must remain explicit errors, not enter hardware reconnect retries")

    let failed = CleanupFixture()
    failed.statuses["Stop audio"] = kAudioHardwareUnspecifiedError
    let failedRoute = AudioRoute(cleanup: failed.operations)
    let failedModel = Model(settingsFile: directory.appendingPathComponent("failed.json"), readLoginStatus: { .notRegistered }, route: failedRoute)
    adoptMissingOutput(failedRoute)
    failedModel.running = true
    failedModel.meter.update(0.5, reductionDB: 3)
    failedModel.stop()
    require(!failedModel.running && failedModel.meter.peak == 0 && failedModel.meter.reductionDB == 0 && !failedRoute.hasResources,
            "A genuine stop failure must not leave the UI showing active EQ after cleanup")
    require(failedModel.error?.contains("Stop audio failed") == true && failedModel.error?.contains("Privacy") == false,
            "Unexpected stop errors must remain visible without recording-permission advice")
    print("PASS disconnect pause, exact-output wait, stale enumeration races, repeated polling, preserved profile/Bypass, Stop cancellation, and truthful stop-failure state")
}
