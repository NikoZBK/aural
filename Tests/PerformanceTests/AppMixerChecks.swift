import Foundation
import Combine
import CoreAudio

func mixerProcess(_ id: Int, owner: String? = nil, bundle: String? = nil, playing: Bool = true) -> AppAudioProcess {
    let app = owner ?? "com.example.Player\(id)"
    return AppAudioProcess(object: UInt32(100 + id), pid: Int32(200 + id), bundleID: bundle ?? app,
        ownerID: owner == "unknown" ? nil : app, name: "Player \(id)", appPath: nil,
        birth: AppProcessBirth(pid: Int32(200 + id), uid: 501, seconds: UInt64(id + 1), microseconds: 0),
        responsibleBirth: nil, outputs: playing ? [77] : [], playing: playing, experimental: app == "com.apple.Safari", issue: nil)
}

@MainActor func checkAppMixer() async throws {
    if #available(macOS 14.2, *) {
        let protectedOutput = OutputDevice(id: 77, uid: "headphones-only", name: "Headphones")
        let description = AppMixerGuard.tapDescription(output: protectedOutput, ownProcess: 123)
        require(description.deviceUID == protectedOutput.uid && description.processes == [123] && description.isExclusive,
                "Reconnect protection must exclude Aural and remain scoped to the selected physical output")
        require(description.muteBehavior == .muted,
                "Protection must not release mute when physical reconnect temporarily stops reader callbacks")
        let reader = AppMixerGuard.readerConfiguration(tapUID: "test-tap")
        require(reader[kAudioAggregateDeviceTapAutoStartKey] as? Bool == false && reader[kAudioAggregateDeviceSubDeviceListKey] == nil,
                "The input-only standby reader must start without waiting for a playing source or adding hardware outputs")
    }
    let sources = (0..<12).map { mixerProcess($0) }
    let catalog = AppAudioCatalog(processes: sources, incomplete: false)
    let neutral = try AppMixerPlan(catalog: catalog, previous: [], preferences: AppMixerPreferences(), ownPID: -1, outputObject: 77)
    require(neutral.slots.compactMap { $0 }.count == 8 && neutral.others.count == 4, "Neutral overflow must stay at unity in Other audio")
    require(Set(neutral.groups.flatMap { $0 }.map(\.object) + neutral.others.map(\.object)).count == 12, "Each process has exactly one replay lane")
    var preferences = AppMixerPreferences()
    for source in sources.prefix(9) { preferences.apps[source.ownerID!] = AppVolumeSetting(volume: 0.25, muted: true, name: source.name) }
    do {
        _ = try AppMixerPlan(catalog: catalog, previous: neutral.slots, preferences: preferences, ownPID: -1, outputObject: 77)
        fatalError("Nine active nonneutral apps must fail explicitly, never leak a saved mute into unity playback")
    } catch let error as AudioFailure { require(error.message.contains("eight"), "Capacity error must explain the limit") }
    let quiet = AppAudioCatalog(processes: (0..<9).map { mixerProcess($0, playing: false) }, incomplete: false)
    let quietPlan = try AppMixerPlan(catalog: quiet, previous: [], preferences: preferences, ownPID: -1, outputObject: 77)
    require(quietPlan.pending.count == 1 && quietPlan.others.isEmpty, "An unbound remembered mute must wait outside replay until capacity is available")

    let safari = mixerProcess(20, owner: "com.apple.Safari", bundle: "com.apple.WebKit.GPU")
    let peer = mixerProcess(21, owner: "com.example.Other", bundle: "com.apple.WebKit.GPU")
    let unknown = mixerProcess(22, owner: "unknown", bundle: "com.apple.WebKit.GPU")
    preferences = AppMixerPreferences(apps: ["com.apple.Safari": AppVolumeSetting(volume: 0.42, muted: true, name: "Safari")])
    let shared = try AppMixerPlan(catalog: AppAudioCatalog(processes: [safari, peer, unknown], incomplete: false), previous: [], preferences: preferences, ownPID: -1, outputObject: 77)
    require(shared.pending.map(\.object) == [unknown.object], "An unknown shared helper cannot escape Safari's remembered mute")
    require(shared.groups.flatMap { $0 }.filter { $0.ownerID == "com.apple.Safari" }.map(\.object) == [safari.object], "Shared bundle IDs must not combine unrelated app helpers")
    // A source with no owner and no bundle ID waits briefly beside a muted
    // app, then plays in Other audio. One that names a muted app keeps waiting.
    let nameless = AppAudioProcess(object: 140, pid: 240, bundleID: "", ownerID: nil, name: "afplay", appPath: nil, birth: nil,
                                   responsibleBirth: nil, outputs: [77], playing: true, experimental: false, issue: nil)
    let claimed = mixerProcess(41, owner: "unknown", bundle: "com.apple.Safari.helper")
    let loose = AppAudioCatalog(processes: [safari, nameless, claimed], incomplete: false)
    let waitingPlan = try AppMixerPlan(catalog: loose, previous: [], preferences: preferences, ownPID: -1, outputObject: 77)
    require(Set(waitingPlan.pending.map(\.object)) == [nameless.object, claimed.object] && waitingPlan.others.isEmpty,
            "An unidentified source first waits for ownership")
    let releasedPlan = try AppMixerPlan(catalog: loose, previous: waitingPlan.slots, preferences: preferences, ownPID: -1, outputObject: 77,
                                        released: [nameless.object, claimed.object])
    require(releasedPlan.pending.map(\.object) == [claimed.object] && releasedPlan.others.map(\.object) == [nameless.object],
            "After its grace an unidentified source plays in Other audio; a muted app's unverified helper never does")
    do {
        _ = try AppMixerPlan(catalog: AppAudioCatalog(processes: [safari, safari], incomplete: false), previous: [], preferences: preferences, ownPID: -1, outputObject: 77)
        fatalError("Duplicate process objects must be rejected")
    } catch is AudioFailure { }
    do { _ = try AppMixerPreferences(version: 99).validated(); fatalError("Unsupported preference versions must fail") } catch is AudioFailure { }
    do { _ = try AppVolumeSetting(volume: .nan, name: "Bad").validated(); fatalError("Nonfinite volume must fail") } catch is AudioFailure { }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-app-mixer-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("settings.json")
    let model = Model(settingsFile: file, readLoginStatus: { .notRegistered })
    let store = model.appMixer, output = OutputDevice(id: 77, uid: "test-output", name: "Test output")
    store.adoptCatalogForTesting(catalog, output: output)
    let original = model.profile, revision = model.editRevision
    var publications = 0
    let subscription = model.objectWillChange.sink { publications += 1 }
    let started = ProcessInfo.processInfo.systemUptime
    for value in 0..<400 { store.setVolume("com.example.Player0", percent: Double(value % 101)) }
    store.setVolume("com.example.Player0", percent: 42, final: true)
    store.setMuted("com.example.Player0", true)
    require(publications == 0 && model.profile == original && model.editRevision == revision,
            "App gestures must never publish or alter the EQ document, presets or response revision")
    subscription.cancel()
    print("App mixer: 400 control edits in \((ProcessInfo.processInfo.systemUptime - started) * 1000) ms; zero EQ publications")
    store.setVisible(true)
    store.updateRouting(slots: ["com.example.Player0"], peaks: [0.5])
    require(store.rows.first { $0.id == "com.example.Player0" }?.peak == 0.5, "A visible bound app receives activity")
    store.updateRouting(slots: [], peaks: [])
    require(store.rows.first { $0.id == "com.example.Player0" }?.peak == 0, "A departed app must not retain stale activity")
    store.setVisible(false)
    try await store.flush()
    require(!FileManager.default.fileExists(atPath: file.path), "App levels must not create or change EQ settings")
    let restored = AppMixerStore(file: directory.appendingPathComponent("app-mixer.json"), discoveryEnabled: false)
    require(restored.preferences.apps["com.example.Player0"]?.volume == 0.42 && restored.preferences.apps["com.example.Player0"]?.muted == true,
            "Volume and separate mute must survive relaunch independently of EQ settings")
    restored.setMuted("com.example.Player0", false)
    require(restored.preferences.apps["com.example.Player0"]?.gain == 0.42, "Unmute restores the saved level")
    try await restored.flush()
    // Reset forgets the app, and a quit with nothing new leaves the file alone.
    let mixerFile = directory.appendingPathComponent("app-mixer.json")
    restored.reset("com.example.Player0")
    require(restored.preferences.apps["com.example.Player0"] == nil && restored.error == nil
            && !restored.rows.contains { $0.id == "com.example.Player0" }, "Reset must forget an app that is not playing")
    try await restored.flush()
    let forgotten = AppMixerStore(file: mixerFile, discoveryEnabled: false)
    require(forgotten.preferences.apps.isEmpty, "A forgotten app must stay forgotten after relaunch")
    try FileManager.default.removeItem(at: mixerFile)
    try await forgotten.flush()
    require(!FileManager.default.fileExists(atPath: mixerFile.path), "Quitting without changes must not rewrite app levels")

    let route = AudioRoute()
    var deliveries = 0
    route.onMixerState = { _, _ in deliveries += 1 }
    route.adoptMixerTokenForTesting(1); route.deliverMixerStateForTesting(1)
    try route.stop(); route.deliverMixerStateForTesting(1)
    route.adoptMixerTokenForTesting(2); route.deliverMixerStateForTesting(1); route.deliverMixerStateForTesting(2)
    require(deliveries == 2, "Stop and newer sessions must reject stale mixer completions")
    try route.stop()
    // A standalone app nested in another bundle's Applications folder is its
    // own app; a helper elsewhere in a bundle belongs to the enclosing app.
    let bundles = directory.appendingPathComponent("Applications")
    func makeApp(_ path: String, id: String) throws -> URL {
        let app = bundles.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
    let outer = try makeApp("Outer.app", id: "com.example.Outer")
    let nested = try makeApp("Outer.app/Contents/Developer/Applications/Inner.app", id: "com.example.Inner")
    let helper = try makeApp("Outer.app/Contents/Frameworks/Outer Helper.app", id: "com.example.Outer.helper")
    require(AppAudioCatalog.enclosingApp(of: nested.appendingPathComponent("Contents/MacOS/Inner"))?.lastPathComponent == "Inner.app",
            "An app in a nested Applications folder must be identified as itself")
    require(AppAudioCatalog.enclosingApp(of: helper.appendingPathComponent("Contents/MacOS/Outer Helper"))?.lastPathComponent == "Outer.app"
            && AppAudioCatalog.enclosingApp(of: outer.appendingPathComponent("Contents/MacOS/Outer"))?.lastPathComponent == "Outer.app",
            "A bundled helper must still be attributed to its enclosing app")
    // A level drag stays on the gain-only path; anything that can move an app
    // between lanes (mute, leaving or reaching 100%, a new app) does not.
    var quieter = AppMixerPreferences(), louder = quieter, muted = quieter, full = quieter
    quieter.apps["com.example.A"] = AppVolumeSetting(volume: 0.4, name: "A")
    louder.apps["com.example.A"] = AppVolumeSetting(volume: 0.7, name: "A")
    muted.apps["com.example.A"] = AppVolumeSetting(volume: 0.7, muted: true, name: "A")
    full.apps["com.example.A"] = AppVolumeSetting(volume: 1, name: "A")
    var added = louder; added.apps["com.example.B"] = AppVolumeSetting(volume: 1, name: "B")
    require(AppMixerTopology.sameRouting(quieter, louder) && AppMixerTopology.sameRouting(quieter, muted),
            "Level changes on an already adjusted app must not rebuild lanes")
    require(!AppMixerTopology.sameRouting(louder, full) && !AppMixerTopology.sameRouting(full, muted) && !AppMixerTopology.sameRouting(louder, added)
            && !AppMixerTopology.sameRouting(AppMixerPreferences(), louder),
            "Reaching or leaving 100%, and newly remembered apps, must rebuild lanes")
    // A failure releasing one tap must not skip its peers or the independent
    // protection callback. Retain uncertain resources, then release on retry.
    let protection = AppMixerGuard(output: output)
    protection.adoptForTesting(tap: 90, aggregate: 91)
    let topology = AppMixerTopology()
    topology.adoptForTesting(taps: [80, 81, 82], protection: protection)
    var released: [UInt32] = [], stopped = 0, callbacks = 0, aggregates = 0
    let failingCleanup = AudioRouteCleanup(stop: { _, _ in stopped += 1; return 0 },
        destroyCallback: { _, _ in callbacks += 1; return 0 },
        destroyAggregate: { _ in aggregates += 1; return 0 },
        destroyTap: { id in released.append(id); return id == 81 ? -1 : 0 })
    do { try topology.release(keepingGuard: false, cleanup: failingCleanup); fatalError("A failed tap release must be reported") }
    catch is AudioFailure { }
    require(released == [80, 81, 82, 90] && stopped == 1 && callbacks == 1 && aggregates == 1,
            "Cleanup must attempt all app taps and protection resources after a peer failure")
    require(topology.hasResources && !protection.hasResources, "Only uncertain resources survive failed cleanup")
    released = []
    let retryCleanup = AudioRouteCleanup(stop: { _, _ in 0 }, destroyCallback: { _, _ in 0 }, destroyAggregate: { _ in 0 },
                                        destroyTap: { id in released.append(id); return 0 })
    try topology.release(keepingGuard: false, cleanup: retryCleanup)
    require(released == [81] && !topology.hasResources, "Cleanup retries only the retained failed tap")
    // A wait keeps the selected output muted for its return. A start that
    // fails before building a route must release that mute with everything else.
    let quietCleanup = AudioRouteCleanup(stop: { _, _ in 0 }, destroyCallback: { _, _ in 0 }, destroyAggregate: { _ in 0 }, destroyTap: { _ in 0 })
    let waitingRoute = AudioRoute(cleanup: quietCleanup)
    let kept = AppMixerGuard(output: output)
    kept.adoptForTesting(tap: 92, aggregate: 93)
    waitingRoute.adoptMixerGuardForTesting(kept)
    try waitingRoute.stop(keepingMixerGuard: true)
    require(waitingRoute.hasResources && kept.hasResources, "Waiting for an output keeps its protection")
    let vanishedOutput = OutputDevice(id: 0x7fff_fff3, uid: output.uid, name: output.name)
    do {
        try await waitingRoute.start(vanishedOutput, profile: Profile(), bypass: false, peakProtectionEnabled: false)
        fatalError("A vanished output cannot start")
    } catch is CoreAudioFailure { }
    require(!waitingRoute.hasResources && !kept.hasResources, "A failed start must not leave the selected output muted")
    // Unreadable app levels are preserved and leave every app neutral, so EQ
    // can still start; quitting must not rewrite the file either.
    let damagedFile = FileManager.default.temporaryDirectory.appendingPathComponent("aural-damaged-\(UUID().uuidString).json")
    let damagedData = Data("{ not app levels".utf8)
    try damagedData.write(to: damagedFile)
    defer { try? FileManager.default.removeItem(at: damagedFile) }
    let damaged = AppMixerStore(file: damagedFile, discoveryEnabled: false)
    require(damaged.loadFailed && damaged.error != nil && damaged.preferences == AppMixerPreferences(),
            "A damaged settings file is reported and starts from neutral levels")
    try await damaged.flush()
    let keptData = try Data(contentsOf: damagedFile)
    require(keptData == damagedData, "A damaged settings file is preserved for repair")
    print("PASS app mixer capacity, partition isolation, experimental Safari ownership, quarantine, persistence, unmute, EQ isolation and stale generation rejection")
}
