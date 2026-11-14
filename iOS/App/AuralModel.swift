import Foundation
import Combine
import DSP

@MainActor
final class AuralModel: ObservableObject {
    struct Snapshot { var profile: Profile; var selection: String? }
    struct Issue: Identifiable { let id = UUID(); let message: String }
    @Published private(set) var state = LibraryState()
    @Published private(set) var revision = 0
    @Published private(set) var history = EditHistory<Snapshot>()
    @Published private(set) var comparison: Snapshot?
    @Published private(set) var analysis = ResponseAnalysis(profile: Profile(), rate: 48000, bypass: false)
    @Published var issue: Issue?
    @Published private(set) var storageProblem: String?
    let audio = ProbeAudio(idleTimeout: nil, routeName: "Aural")
    private let file: LibraryFile
    private var canSave = true
    private var gestureStart: Snapshot?
    private var analysisTask: Task<Void, Never>?
    private var audioFailureSubscription: AnyCancellable?

    init(directory: URL? = nil) {
        let directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("Aural", isDirectory: true)
        file = LibraryFile(url: directory.appendingPathComponent("library.json"))
        do { state = try file.load() }
        catch {
            canSave = false
            storageProblem = "Saved settings could not be opened: \(error.localizedDescription) The original file has been preserved."
            issue = Issue(message: storageProblem ?? error.localizedDescription)
        }
#if AURAL_UI_PREVIEW
        // Only the offline preview accepts launch fixtures. Production ignores them.
        if ProcessInfo.processInfo.arguments.contains("--preview-fixture") {
            state = LibraryState(); state.completedSetup = true
            if let warm = Profile.builtInPresets["Warm"] { state.profile = warm; state.selectedPreset = "Warm" }
        }
#endif
        audio.bypass = state.bypass
        perform { try configure(state.profile, library: state.library) }
        refreshAnalysis()
        audioFailureSubscription = audio.$failure.compactMap { $0 }.sink { [weak self] message in
            self?.issue = Issue(message: message)
        }
    }

    var profile: Profile { state.profile }
    var title: String { state.selectedPreset ?? profile.sourceName ?? "Custom EQ" }
    var snapshot: Snapshot { Snapshot(profile: profile, selection: state.selectedPreset) }
    var presetNames: [String] { Set(Profile.builtInPresets.keys).union(state.library.presets.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    func perform(_ work: () throws -> Void) {
        do { try work() } catch { issue = Issue(message: error.localizedDescription) }
    }
    private func configure(_ profile: Profile, library: Settings) throws {
        let match = library.matchLevels ? LevelMatch(current: profile, comparedWith: comparison?.profile) : .none
        try audio.configure(.init(filters: profile.dspFilters(rate: 48000), preamp: profile.preamp + match.eqOffsetDB,
                                  stereo: profile.dspStereo, bypassGain: match.bypassGainDB,
                                  peakProtection: library.peakProtectionEnabled))
    }
    func apply(_ next: Profile, selection: String? = nil, expectedRevision: Int? = nil) throws {
        if let expectedRevision, expectedRevision != revision {
            throw AudioFailure(message: "The EQ changed while this editor was open. Cancel and reopen the editor to avoid overwriting those changes.")
        }
        let valid = try next.validated()
        try configure(valid, library: state.library)
        if gestureStart == nil { history.record(snapshot) }
        state.profile = valid; state.selectedPreset = selection
        revision += 1
        refreshAnalysis()
        if gestureStart == nil { persist() }
    }
    func edit(_ change: (inout Profile) -> Void) {
        perform { var next = profile; change(&next); try apply(next, selection: state.selectedPreset) }
    }
    func gesture(_ editing: Bool) {
        if editing {
            if gestureStart == nil { gestureStart = snapshot }
        } else if let start = gestureStart {
            gestureStart = nil
            if start.profile != profile { history.record(start) }
            persist()
        }
    }
    func undo(redo: Bool = false) {
        perform {
            var nextHistory = history
            let next = try redo ? nextHistory.redo(snapshot) : nextHistory.undo(snapshot)
            try configure(next.profile, library: state.library)
            history = nextHistory
            restore(next)
        }
    }
    private func restore(_ snapshot: Snapshot) {
        state.profile = snapshot.profile
        state.selectedPreset = snapshot.selection.flatMap { state.library.preset(named: $0) == nil ? nil : $0 }
        revision += 1; refreshAnalysis(); persist()
    }
    func captureComparison() {
        perform {
            let old = comparison; comparison = snapshot
            do { try configure(profile, library: state.library) }
            catch { comparison = old; throw error }
            refreshAnalysis()
        }
    }
    func swapComparison() {
        perform {
            guard let other = comparison else { throw AudioFailure(message: "Save a comparison first.") }
            let previous = snapshot
            // Matching is computed against the version that will become the alternate.
            comparison = previous
            do { try configure(other.profile, library: state.library) }
            catch { comparison = other; throw error }
            history.record(previous); restore(other)
        }
    }
    func setBypass(_ value: Bool) {
        state.bypass = value; audio.bypass = value
        revision += 1; refreshAnalysis(); persist()
    }
    func preference(_ change: (inout Settings) -> Void) {
        perform {
            var next = state.library; change(&next)
            try configure(profile, library: next)
            state.library = next; persist()
        }
    }
    func autoPreamp() { edit { $0.preamp = Headroom.preamp(for: $0, rate: 48000) } }
    func play() { audio.prepare() }
    func stop() { audio.stop() }
    func finishSetup() { state.completedSetup = true; persist() }

    func loadPreset(_ name: String) {
        perform {
            guard let next = state.library.preset(named: name) else { throw AudioFailure(message: "The preset no longer exists.") }
            try apply(next, selection: name)
            setBypass(false); play()
        }
    }
    func savePreset(_ proposed: String) throws {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AudioFailure(message: "Enter a preset name.") }
        guard state.library.preset(named: name) == nil else { throw AudioFailure(message: "That name is already in use. Choose a new name to preserve the saved preset.") }
        guard state.library.presets.count < 1000 else { throw AudioFailure(message: "The library can contain at most 1,000 saved presets.") }
        state.library.presets[name] = profile; state.selectedPreset = name; persist()
    }
    var canUpdatePreset: Bool {
        state.selectedPreset.map { state.library.presets[$0] != nil && Profile.builtInPresets[$0] == nil } == true && state.modified
    }
    func updateSelectedPreset() throws {
        guard let name = state.selectedPreset, canUpdatePreset else { throw AudioFailure(message: "Choose a modified saved preset to update. Built-in presets can be saved under a new name.") }
        state.library.presets[name] = try profile.validated(); persist()
    }
    func libraryEdit(_ change: (inout Settings) throws -> Void) throws {
        var next = state.library; try change(&next)
        var candidate = state; candidate.library = next
        if let selected = candidate.selectedPreset, next.preset(named: selected) == nil { candidate.selectedPreset = nil }
        _ = try candidate.validated()
        state = candidate; persist()
    }
    func renamePreset(_ old: String, to name: String) throws {
        var next = state.library; try next.renamePreset(old, to: name)
        state.library = next
        if state.selectedPreset == old { state.selectedPreset = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        persist()
    }
    func acceptImport(_ imported: ProfileImport) throws {
        switch imported {
        case .profile(let next):
            try apply(next)
            stop() // Import is explicit but does not unexpectedly start playback.
        case .library(let backup):
            try libraryEdit { $0.mergePresets(backup) }
        }
    }
    func acceptAutoEQ(_ preview: AutoEQPreview) throws {
        let valid = try preview.profile.validated()
        guard state.library.presets.count < 1000 else { throw AudioFailure(message: "The library can contain at most 1,000 saved presets.") }
        try configure(valid, library: state.library)
        let name = state.library.availablePresetName(preview.entry.presetName)
        history.record(snapshot)
        state.library.presets[name] = valid
        state.profile = valid; state.selectedPreset = name
        revision += 1; refreshAnalysis(); persist(); stop()
    }
    func exportProfile() throws -> Data { try JSONEncoder().encode(profile) }
    func exportLibrary() throws -> Data {
        try JSONEncoder().encode(PresetBackup(presets: state.library.presets, favorites: state.library.favoritePresets))
    }
    func persist() {
        guard canSave else { return } // A load failure is visible; never overwrite the unreadable source.
        do { try file.save(state); storageProblem = nil }
        catch {
            storageProblem = "Changes are active but could not be saved: \(error.localizedDescription)"
            issue = Issue(message: storageProblem ?? error.localizedDescription)
        }
    }
    func retryLoad() {
        perform {
            let recovered = try file.load()
            try configure(recovered.profile, library: recovered.library)
            state = recovered; audio.bypass = recovered.bypass
            canSave = true; storageProblem = nil; history = EditHistory(); comparison = nil
            revision += 1; refreshAnalysis()
        }
    }
    private func refreshAnalysis() {
        analysisTask?.cancel()
        let current = profile, alternate = comparison?.profile, bypass = state.bypass, token = revision
        analysisTask = Task { [weak self] in
            // Coalesce slider events before starting coefficient analysis.
            do { try await Task.sleep(for: .milliseconds(30)) }
            catch is CancellationError { return }
            catch { self?.issue = Issue(message: error.localizedDescription); return }
            let computed = await Task.detached(priority: .userInitiated) {
                ResponseAnalysis(profile: current, rate: 48000, bypass: bypass, comparisonProfile: alternate)
            }.value
            guard !Task.isCancelled, let self, self.revision == token else { return }
            self.analysis = computed
        }
    }
}
