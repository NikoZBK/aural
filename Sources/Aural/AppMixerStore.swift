import AppKit
import Combine
import Foundation

struct AppMixerRowState: Equatable {
    let id: String
    let name: String
    let path: String?
    let experimental: Bool
    let playing: Bool
    let available: Bool
    let controllable: Bool
    let applied: Bool
    /// Playing with a saved level or mute, but silenced because all eight lanes are taken.
    var held = false
}

@MainActor final class AppMixerRow: ObservableObject, Identifiable {
    let id: String
    @Published private(set) var state: AppMixerRowState
    @Published private(set) var setting: AppVolumeSetting
    @Published private(set) var peak: Float = 0
    @Published private(set) var icon: NSImage?
    init(state: AppMixerRowState, setting: AppVolumeSetting) {
        id = state.id; self.state = state; self.setting = setting
        icon = state.path.map { NSWorkspace.shared.icon(forFile: $0) }
    }
    func update(state: AppMixerRowState, setting: AppVolumeSetting) {
        if self.state.path != state.path { icon = state.path.map { NSWorkspace.shared.icon(forFile: $0) } }
        if self.state != state { self.state = state }
        if self.setting != setting { self.setting = setting }
    }
    func updatePeak(_ value: Float) { if peak != value { peak = value } }
}

private actor AppMixerWriter {
    let file: URL
    var revision: UInt64 = 0
    init(file: URL) { self.file = file }
    func save(_ preferences: AppMixerPreferences, revision: UInt64) throws {
        guard revision >= self.revision else { return }
        _ = try preferences.validated()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(preferences).write(to: file, options: .atomic)
        self.revision = revision
    }
}

/// App changes never publish the EQ document or schedule response analysis.
/// Only metadata/list changes publish this store; gestures publish their row.
@MainActor final class AppMixerStore: ObservableObject {
    @Published private(set) var rows: [AppMixerRow] = []
    @Published private(set) var error: String?
    @Published private(set) var active = false
    @Published private(set) var waiting = false
    @Published private(set) var outputName = "the selected output"
    @Published private(set) var unavailableCount = 0
    @Published private(set) var globalOnly = false
    @Published private(set) var starting = false
    @Published private(set) var bypassed = false
    @Published private(set) var lifecycleError: String?
    @Published private(set) var competingProcessor: String?
    @Published private(set) var capacityNotice: String?
    private(set) var preferences = AppMixerPreferences()
    private(set) var loadFailed = false
    var onControls: ((AppMixerPreferences) -> Void)?
    var onCatalog: ((AppAudioCatalog) -> Void)?
    var onDiscoveryFailure: ((Error) -> Void)?
    private var cached: [String: AppMixerRow] = [:]
    private var catalog = AppAudioCatalog(processes: [], incomplete: false)
    private var slots: Set<String> = []
    private var outputObject: UInt32 = 0
    private var visible = false
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0
    private var unsaved = false
    private var discoveryFailed = false
    private var refreshTask: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var changePending = false
    private var fastUntil = ContinuousClock.now
    private var lastDelivery = ContinuousClock.now
    private var idleNotices = 0
    private lazy var watcher = AppAudioWatcher { [weak self] in Task { @MainActor in self?.audioChanged() } }
    private var saveTask: Task<Void, Never>?
    private let writer: AppMixerWriter
    private let discoveryEnabled: Bool

    init(file: URL, discoveryEnabled: Bool = true) {
        writer = AppMixerWriter(file: file); self.discoveryEnabled = discoveryEnabled
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard data.count <= 512 * 1024 else { throw AudioFailure(message: "App mixer settings are too large.") }
                preferences = try JSONDecoder().decode(AppMixerPreferences.self, from: data).validated()
            }
        } catch { self.error = "Could not load app mixer settings: " + error.localizedDescription; loadFailed = true }
        rebuildRows()
    }

    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value; refreshScheduling()
    }
    func setSession(active: Bool, waiting: Bool = false, globalOnly: Bool = false, starting: Bool = false, output: OutputDevice?) {
        let flipped = self.active != active
        if flipped { self.active = active }
        if self.waiting != waiting { self.waiting = waiting }
        if self.globalOnly != globalOnly { self.globalOnly = globalOnly }
        if self.starting != starting { self.starting = starting }
        outputObject = output?.id ?? 0
        if let output, outputName != output.name { outputName = output.name }
        if !active { slots = []; for row in rows { row.updatePeak(0) } }
        rebuildRows(); refreshScheduling()
        // The first catalog of a session must not wait out a sleep, and the mixer settles on quick reads.
        if flipped { idleNotices = 0; fastUntil = .now + .seconds(6); audioChanged() }
    }
    func setBypassed(_ value: Bool) { if bypassed != value { bypassed = value } }
    func setLifecycleError(_ value: String?) { if lifecycleError != value { lifecycleError = value } }
    func flush() async throws {
        // Preserve an invalid file; no edited values were accepted. An unchanged file is left alone.
        guard !loadFailed, unsaved else { return }
        saveTask?.cancel(); revision &+= 1
        let token = revision
        try await writer.save(preferences, revision: token)
        if revision == token { unsaved = false }
    }
    /// Something about app audio may have changed: read soon. Core Audio also
    /// sends these notices when nothing the mixer uses changed, so a notice
    /// alone does not start quick reading; a read that finds a change does.
    private func audioChanged() {
        changePending = true; sleeper?.cancel()
    }
    /// The shortest wait before the next read. Notices that keep turning out
    /// to change nothing back off, so a chattering process cannot keep
    /// discovery busy; a real change restores the prompt re-read.
    static func noticeFloor(idleNotices: Int, active: Bool) -> Int {
        switch idleNotices { case 0: 50; case 1: 250; case 2: 500; default: active ? 500 : 2000 }
    }
    private func refreshScheduling() {
        let wanted = discoveryEnabled && (active || visible)
        guard wanted != (refreshTask != nil) else { return }
        generation &+= 1; refreshTask?.cancel(); refreshTask = nil; sleeper?.cancel(); sleeper = nil
        guard wanted else { watcher.stop(); return }
        watcher.start(); changePending = false; idleNotices = 0; fastUntil = .now + .seconds(6)
        let token = generation
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let result = await Task.detached(priority: .utility) { Result { try AppAudioCatalog.read() } }.value
                guard let self, !Task.isCancelled, self.generation == token else { return }
                var changed = false
                switch result {
                case .success(let catalog):
                    self.watcher.watch(catalog.processes.map(\.object))
                    if catalog.incomplete { changed = true }
                    else if self.catalog != catalog { self.catalog = catalog; self.rebuildRows(); changed = true }
                    // The mixer counts its grace periods (up to five seconds)
                    // on these reads, so they stay quick while a change settles.
                    if changed { self.fastUntil = .now + .seconds(6) }
                    if self.discoveryFailed { self.discoveryFailed = false; self.error = nil }
                    // An unchanged catalog still reaches the mixer while it
                    // settles, and once a second after that as its health check.
                    let now = ContinuousClock.now
                    if self.active, changed || now < self.fastUntil || now - self.lastDelivery >= .seconds(1) {
                        self.lastDelivery = now; self.onCatalog?(catalog)
                    }
                case .failure(let error):
                    self.discoveryFailed = true
                    self.error = "Could not discover app audio: " + error.localizedDescription
                    AuralLog.audio.error("App discovery failed: \(AuralLog.describe(error), privacy: .public)")
                    if self.active { self.onDiscoveryFailure?(error) }
                }
                // Wait out the floor first; a notice cannot shorten it. Then
                // sleep until the next poll unless a notice asks for a read.
                let noticed = self.changePending
                self.changePending = false
                if changed { self.idleNotices = 0 } else if noticed { self.idleNotices += 1 }
                let floor = Self.noticeFloor(idleNotices: self.idleNotices, active: self.active)
                let poll = ContinuousClock.now < self.fastUntil ? 250 : self.active ? 1000 : 2000
                do { try await Task.sleep(for: .milliseconds(min(floor, poll))) } catch { return }
                guard self.generation == token else { return }
                if !self.changePending, poll > floor {
                    let pause = Task { do { try await Task.sleep(for: .milliseconds(poll - floor)) } catch {} }
                    self.sleeper = pause
                    await withTaskCancellationHandler { await pause.value } onCancel: { pause.cancel() }
                    if self.generation == token { self.sleeper = nil }
                }
            }
        }
    }
    func updateRouting(slots: [String?], peaks: [Float]) {
        let next = Set(slots.compactMap { $0 })
        if self.slots != next {
            for id in self.slots.subtracting(next) { cached[id]?.updatePeak(0) }
            self.slots = next; rebuildRows()
        }
        guard visible else { return }
        for (index, id) in slots.enumerated() {
            if let id, peaks.indices.contains(index) { cached[id]?.updatePeak(peaks[index]) }
        }
    }
    func setVolume(_ id: String, percent: Double, final: Bool = false) {
        guard percent.isFinite, (0...100).contains(percent) else { error = "App volume must be between 0% and 100%."; return }
        change(id, volume: percent / 100, muted: nil, immediateSave: final)
    }
    func setMuted(_ id: String, _ muted: Bool) { change(id, volume: nil, muted: muted, immediateSave: true) }
    /// Reset also forgets the app: 100% and unmuted is what an app Aural has
    /// never seen gets, so the entry is dropped and stops counting toward the
    /// remembered-app limit. Its row leaves the list once it is not playing.
    func reset(_ id: String) { change(id, volume: 1, muted: false, immediateSave: true, forget: true) }
    private func change(_ id: String, volume: Double?, muted: Bool?, immediateSave: Bool, forget: Bool = false) {
        guard !loadFailed else { return } // The load error stays on screen; controls are disabled.
        guard let row = cached[id], row.state.controllable else {
            error = "This audio source cannot currently be controlled as an app."; return
        }
        var setting = preferences.apps[id] ?? AppVolumeSetting(name: row.state.name)
        if let volume { setting.volume = volume }
        if let muted { setting.muted = muted }
        do { _ = try setting.validated() }
        catch { self.error = error.localizedDescription; return }
        guard preferences.apps.count < 256 || preferences.apps[id] != nil else { error = "The remembered app limit has been reached."; return }
        // A ninth controlled app would have no lane and fall silent, so the edit is refused instead.
        if active, !forget, !setting.neutral, preferences.apps[id]?.neutral != false, row.state.playing,
           controlledPlaying(except: id) >= AppMixerPlan.capacity {
            error = "Aural can control eight apps at once. Reset another playing app to 100% first."; return
        }
        if forget {
            guard preferences.apps[id] != nil else { return }
            preferences.apps[id] = nil
        } else { preferences.apps[id] = setting }
        // An accepted edit supersedes whatever the last edit or save reported.
        if !discoveryFailed { error = nil }
        row.update(state: row.state, setting: setting)
        if forget { rebuildRows() }
        onControls?(preferences); unsaved = true
        revision &+= 1; let token = revision, snapshot = preferences, writer = writer
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                if !immediateSave { try await Task.sleep(for: .milliseconds(300)) }
                try Task.checkCancellation()
                try await writer.save(snapshot, revision: token)
                if let self, self.revision == token { self.unsaved = false; if !self.discoveryFailed { self.error = nil } }
            } catch is CancellationError { return }
            catch { self?.error = "App levels changed, but could not be saved: " + error.localizedDescription }
        }
    }
    /// How many other apps with a saved level or mute are playing on this output.
    private func controlledPlaying(except id: String) -> Int {
        Set(catalog.processes.compactMap { process -> String? in
            guard let owner = process.ownerID, owner != id, process.pid != getpid(), process.playing, process.outputs.contains(outputObject),
                  preferences.apps[owner]?.neutral == false else { return nil }
            return owner
        }).count
    }
    private func rebuildRows() {
        let groups = catalog.processes.reduce(into: [String: [AppAudioProcess]]()) { result, process in
            if let id = process.ownerID, process.pid != getpid() { result[id, default: []].append(process) }
        }
        let names = Set(groups.keys.filter { id in
            groups[id]?.contains { $0.playing && $0.outputs.contains(outputObject) } == true || preferences.apps[id] != nil || slots.contains(id)
        }).union(preferences.apps.keys)
        let ordered = names.sorted { ($0.localizedStandardCompare($1)) == .orderedAscending }
        // Every lane is held by an app that needs it: any further such app waits in silence.
        let full = active && slots.count == AppMixerPlan.capacity && slots.allSatisfy { id in
            preferences.apps[id]?.neutral == false && groups[id]?.contains { $0.playing && $0.outputs.contains(outputObject) } == true
        }
        var heldNames: [String] = []
        for id in ordered {
            let group = groups[id] ?? [], info = group.first
            let name = info?.name ?? preferences.apps[id]?.name ?? id
            var state = AppMixerRowState(id: id, name: name, path: info?.appPath,
                experimental: id == "com.apple.Safari",
                playing: group.contains { $0.playing && $0.outputs.contains(outputObject) }, available: !group.isEmpty,
                controllable: !loadFailed && !AppAudioCatalog.competingProcessors.contains(id) && (info == nil || group.allSatisfy { $0.birth != nil && $0.issue == nil }), applied: active && slots.contains(id))
            let setting = preferences.apps[id] ?? AppVolumeSetting(name: name)
            state.held = full && state.playing && !setting.neutral && !slots.contains(id)
            if state.held { heldNames.append(name) }
            if let row = cached[id] { row.update(state: state, setting: setting) }
            else { cached[id] = AppMixerRow(state: state, setting: setting) }
        }
        if rows.map(\.id) != ordered { rows = ordered.compactMap { cached[$0] } }
        let notice = heldNames.isEmpty ? nil : "Aural can control eight apps at once. \(heldNames.formatted(.list(type: .and))) will stay silent until another playing app is reset to 100% or stops."
        if capacityNotice != notice { capacityNotice = notice }
        let unknown = catalog.processes.filter { $0.ownerID == nil && $0.playing && $0.outputs.contains(outputObject) }
        if unavailableCount != unknown.count { unavailableCount = unknown.count }
        let competing = catalog.processes.first { $0.ownerID.map(AppAudioCatalog.competingProcessors.contains) == true && $0.playing && $0.outputs.contains(outputObject) }?.name
        if competingProcessor != competing { competingProcessor = competing }
    }
    #if AURAL_TESTING
    func adoptCatalogForTesting(_ catalog: AppAudioCatalog, output: OutputDevice) { self.catalog = catalog; outputObject = output.id; rebuildRows() }
    #endif
}
