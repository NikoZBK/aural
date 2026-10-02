import SwiftUI
import DSP
import UniformTypeIdentifiers
import ServiceManagement

@MainActor final class Model: ObservableObject {
    @Published var devices: [OutputDevice] = []
    @Published var selectedUID = ""
    @Published var profile = Profile()
    @Published var bypass = false
    @Published var running = false
    @Published var peak: Float = 0
    @Published var error: String?
    @Published var presetName = ""
    @Published var customPresets: [String] = []
    @Published private(set) var selectedPresetName: String?
    @Published var importNotice: String?
    @Published private(set) var deletedPreset: (name: String, profile: Profile, favorite: Bool)?
    @Published private(set) var favoritePresets: Set<String> = []
    @Published private(set) var startEQAutomatically = false
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var startupNotice: String?
    @Published private(set) var editRevision = 0
    @Published private var workspace = ProfileWorkspace()
    private var committedProfile = ProfileSnapshot(profile: Profile(), selectedPresetName: nil)
    var canUndo: Bool { workspace.canUndo }
    var canRedo: Bool { workspace.canRedo }
    var undoLabel: String { "Undo " + workspace.undoLabel }
    var redoLabel: String { "Redo " + workspace.redoLabel }
    var comparisonSlot: ComparisonSlot { workspace.comparisonSlot }
    var comparisonAvailable: Bool { workspace.comparisonAvailable }
    var comparisonLabel: String { "\(comparisonSlot.rawValue) · \(workspace.comparisonTitle(for: comparisonSlot))" }
    var otherComparisonProfile: Profile? {
        guard let other = workspace.otherComparison?.profile, !other.hasSameEQ(as: profile) else { return nil }
        return other
    }
    private var pendingStartup: StartupPlan?
    private var startGeneration = 0
    let route = AudioRoute()
    private var settings = Settings()
    private var timer: Timer?
    private var ticks = 0
    private var observers: [NSObjectProtocol] = []
    private let file: URL
    var selected: OutputDevice? { devices.first { $0.uid == selectedUID } }
    var responseRate: Double { running ? route.sampleRate : 48000 }
    let factory = Profile.builtInPresets
    func presetProfile(named name: String) -> Profile? { settings.preset(named: name) }
    var isPresetModified: Bool {
        guard let name = selectedPresetName, let saved = settings.preset(named: name) else { return false }
        return !profile.hasSameEQ(as: saved)
    }
    var currentPresetTitle: String {
        guard let selectedPresetName else { return "Custom EQ" }
        return selectedPresetName + (isPresetModified ? " · Modified" : "")
    }
    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aural/settings.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
                for p in Array(settings.devices.values) + Array(settings.presets.values) { _ = try p.validated() }
            }
            settings.migratePresetSelections()
            devices = try AudioRoute.devices()
            let defaultID = try AudioRoute.defaultOutput()
            startEQAutomatically = settings.startEQAutomatically ?? false
            selectedUID = devices.first(where: { $0.uid == settings.selectedUID })?.uid ?? devices.first(where: { $0.id == defaultID })?.uid ?? devices.first?.uid ?? ""
            if startEQAutomatically {
                selectedUID = settings.selectedUID
                pendingStartup = StartupPlan(outputUID: selectedUID, deadline: Date().addingTimeInterval(60))
                startupNotice = "Waiting for the saved output to start EQ…"
            }
            profile = settings.devices[selectedUID] ?? Profile()
            selectedPresetName = settings.selectedPresetName(forOutput: selectedUID)
            customPresets = settings.presets.keys.sorted()
            favoritePresets = settings.favoritePresets ?? []
        } catch { pendingStartup = nil; startupNotice = nil; self.error = error.localizedDescription }
        committedProfile = ProfileSnapshot(profile: profile, selectedPresetName: selectedPresetName)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
        })
    }
    var launchAtLoginRequested: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }
    func refreshLoginStatus() { loginStatus = SMAppService.mainApp.status }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            self.error = "Could not update Launch at login: " + error.localizedDescription
        }
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func setStartAutomatically(_ enabled: Bool) {
        if enabled, selected == nil { error = "Select a connected output before enabling automatic EQ."; return }
        let previous = startEQAutomatically
        settings.startEQAutomatically = enabled
        if persist() { startEQAutomatically = enabled }
        else { settings.startEQAutomatically = previous }
        if !startEQAutomatically { startGeneration += 1; pendingStartup = nil; startupNotice = nil }
    }
    func select(_ uid: String) {
        stop()
        guard !route.hasResources else { return }
        importNotice = nil
        selectedUID = uid
        profile = settings.devices[uid] ?? Profile()
        selectedPresetName = settings.selectedPresetName(forOutput: uid)
        workspace = ProfileWorkspace()
        committedProfile = ProfileSnapshot(profile: profile, selectedPresetName: selectedPresetName)
        editRevision += 1
        bypass = false
        persist()
    }
    func change() {
        // Legacy SwiftUI bindings may already have changed the visible value. The
        // last accepted snapshot remains the source of truth for undo and rollback.
        _ = commitProfile(ProfileSnapshot(profile: profile, selectedPresetName: selectedPresetName), label: "Adjust EQ")
    }
    func setBypass(_ value: Bool) {
        do {
            try route.update(profile, bypass: value)
            bypass = value
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func apply(_ name: String) {
        guard let p = factory[name] ?? settings.presets[name] else { error = "The preset no longer exists."; return }
        if commitProfile(ProfileSnapshot(profile: p, selectedPresetName: name), label: "Apply \(name)", nextBypass: false), !running { start() }
    }
    func importAutoEQ() {
        let panel = NSOpenPanel()
        panel.title = "Import AutoEQ profile"
        panel.message = "Choose an AutoEQ ParametricEQ.txt or FixedBandEQ.txt file. Import stops processing; click Start EQ when ready."
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size <= 65536 else { throw AudioFailure(message: "The profile exceeds the 64 KB limit.") }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { throw AudioFailure(message: "Use a UTF-8 AutoEQ text export.") }
            let base = url.deletingPathExtension().lastPathComponent
            try importProfile(text, name: base)
        } catch { self.error = error.localizedDescription }
    }
    func pasteEQ() {
        do {
            guard let text = NSPasteboard.general.string(forType: .string) else {
                throw AudioFailure(message: "The clipboard does not contain text. Copy Equalizer APO settings first.")
            }
            try importProfile(text, name: "Clipboard EQ")
        } catch { self.error = error.localizedDescription }
    }
    func copyEQ() {
        do {
            let text = try AutoEQ.export(profile)
            let clipboard = NSPasteboard.general
            clipboard.clearContents()
            guard clipboard.setString(text, forType: .string) else {
                throw AudioFailure(message: "Could not write EQ settings to the clipboard. Try copying again.")
            }
            error = nil
            importNotice = "Copied EQ settings in Equalizer APO format."
        } catch { self.error = error.localizedDescription }
    }
    private func importProfile(_ text: String, name base: String) throws {
        let imported = try AutoEQ.parse(text, name: base)
        // Validate everything before changing the profile or stopping audio.
        startGeneration += 1
        pendingStartup = nil; startupNotice = nil
        try route.stop(); running = false; peak = 0
        let name = settings.availablePresetName(base)
        let previous = committedProfile
        profile = imported
        bypass = false
        settings.presets[name] = imported
        selectedPresetName = name
        committedProfile = ProfileSnapshot(profile: imported, selectedPresetName: name)
        editRevision += 1
        workspace.endGesture()
        workspace.record(before: previous, after: committedProfile, label: "Import EQ")
        customPresets = settings.presets.keys.sorted()
        error = nil
        if persist() {
            importNotice = "Imported \(name). Saved in Presets. Click Start EQ to apply."
        } else { importNotice = nil }
    }
    @discardableResult func replaceProfile(_ next: Profile, selectingPreset name: String? = nil) -> Bool {
        commitProfile(ProfileSnapshot(profile: next, selectedPresetName: name ?? selectedPresetName), label: "Edit filters")
    }

    // Route validation must succeed before publishing a new document. Saving is
    // explicit: if disk persistence fails, the accepted live edit stays visible
    // and undoable, and the user receives a save error rather than a false success.
    @discardableResult private func commitProfile(_ proposed: ProfileSnapshot, label: String,
                                                 nextBypass: Bool? = nil,
                                                 nextWorkspace: ProfileWorkspace? = nil) -> Bool {
        do {
            var snapshot = proposed
            snapshot.profile = try snapshot.profile.validated()
            if let name = snapshot.selectedPresetName, settings.preset(named: name) == nil {
                throw AudioFailure(message: "The selected preset no longer exists.")
            }
            var candidate = settings
            candidate.selectedUID = selectedUID
            if !selectedUID.isEmpty {
                candidate.devices[selectedUID] = snapshot.profile
                try candidate.setSelectedPreset(snapshot.selectedPresetName, forOutput: selectedUID)
            }
            try route.update(snapshot.profile, bypass: nextBypass ?? bypass)
            if let nextWorkspace { workspace = nextWorkspace }
            else { workspace.record(before: committedProfile, after: snapshot, label: label) }
            profile = snapshot.profile
            selectedPresetName = snapshot.selectedPresetName
            committedProfile = snapshot
            editRevision += 1
            workspace.updateComparison(snapshot)
            if let nextBypass { bypass = nextBypass }
            settings = candidate
            importNotice = nil
            error = nil
            return persist()
        } catch {
            profile = committedProfile.profile
            selectedPresetName = committedProfile.selectedPresetName
            editRevision += 1
            self.error = error.localizedDescription
            return false
        }
    }

    func beginProfileGesture(label: String) { workspace.beginGesture(label: label) }
    func endProfileGesture() { workspace.endGesture() }
    func undoProfile() {
        var next = workspace
        do {
            let previous = try next.undo(current: committedProfile)
            _ = commitProfile(previous, label: "Undo", nextWorkspace: next)
        } catch { self.error = error.localizedDescription }
    }
    func redoProfile() {
        var next = workspace
        do {
            let following = try next.redo(current: committedProfile)
            _ = commitProfile(following, label: "Redo", nextWorkspace: next)
        } catch { self.error = error.localizedDescription }
    }
    func comparisonTitle(for slot: ComparisonSlot) -> String { workspace.comparisonTitle(for: slot) }
    func captureComparison() {
        workspace.captureComparison(committedProfile)
        importNotice = "A and B captured. Edit either version, then switch to compare."
    }
    func selectComparison(_ slot: ComparisonSlot) {
        var next = workspace
        if !next.comparisonAvailable { next.captureComparison(committedProfile) }
        do {
            let snapshot = try next.selectComparison(slot, current: committedProfile)
            next.record(before: committedProfile, after: snapshot, label: "Compare \(slot.rawValue)",
                        previousComparisonSlot: workspace.comparisonSlot)
            _ = commitProfile(snapshot, label: "Compare \(slot.rawValue)", nextWorkspace: next)
        } catch { self.error = error.localizedDescription }
    }
    func copyComparisonToOther() {
        do {
            try workspace.copyComparisonToOther(committedProfile)
            importNotice = "Copied \(comparisonSlot.rawValue) to \(comparisonSlot.other.rawValue)."
        } catch { self.error = error.localizedDescription }
    }
    private func editProfile(_ label: String, _ edit: (Profile) throws -> Profile) {
        do {
            let next = try edit(profile)
            _ = commitProfile(ProfileSnapshot(profile: next, selectedPresetName: selectedPresetName), label: label)
        } catch { self.error = error.localizedDescription }
    }
    func setPreamp(_ value: Double) {
        editProfile("Adjust preamp") { var next = $0; next.preamp = value; return next }
    }
    func setGraphicGain(at index: Int, to value: Double) {
        editProfile("Adjust graphic band") {
            guard $0.filters == nil, $0.gains.indices.contains(index) else {
                throw AudioFailure(message: "This graphic band no longer exists.")
            }
            var next = $0; next.gains[index] = value; return next
        }
    }
    func setStereoSettings(_ value: StereoSettings) {
        editProfile("Adjust stereo") { var next = $0; next.stereo = value.isNeutral ? nil : value; return next }
    }
    func resetStereoSettings() {
        editProfile("Reset stereo") { var next = $0; next.stereo = nil; return next }
    }
    func useGraphicTemplate(bands: Int) {
        editProfile("\(bands)-band template") { try ProfileTools.graphicTemplate(bands: bands, preserving: $0) }
    }
    func transformGains(scale: Double, offset: Double) {
        editProfile("Transform gains") { try ProfileTools.transformGains($0, scale: scale, offset: offset) }
    }
    func shiftFrequencies(octaves: Double) {
        editProfile("Shift frequencies") { try ProfileTools.shiftFrequencies($0, octaves: octaves) }
    }
    func setFilterEnabled(at index: Int, enabled: Bool) {
        editProfile(enabled ? "Enable filter" : "Disable filter") {
            let parametric = try ProfileTools.parametric($0)
            guard let filters = parametric.filters, filters.indices.contains(index) else {
                throw AudioFailure(message: "The filter no longer exists.")
            }
            var filter = filters[index]
            filter.enabled = enabled
            return try ProfileTools.updateFilter($0, at: index, with: filter)
        }
    }
    func updateFilter(at index: Int, with filter: ImportedFilter) {
        editProfile("Edit filter") { try ProfileTools.updateFilter($0, at: index, with: filter) }
    }
    func duplicateFilter(at index: Int) {
        editProfile("Duplicate filter") { try ProfileTools.duplicateFilter($0, at: index) }
    }
    func deleteFilter(at index: Int) {
        editProfile("Delete filter") { try ProfileTools.deleteFilter($0, at: index) }
    }
    func addFilter() { editProfile("Add filter") { try ProfileTools.addFilter($0) } }
    func editGraphicAsFilters() { editProfile("Parametric view") { try ProfileTools.parametric($0) } }

    func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, factory[name] == nil else { error = "Choose a preset name other than a built-in preset."; return }
        let saved = profile
        if updateLibrary({
            _ = try saved.validated()
            $0.presets[name] = saved
            if !selectedUID.isEmpty { try $0.setSelectedPreset(name, forOutput: selectedUID) }
        }) {
            selectedPresetName = name
            committedProfile.selectedPresetName = name
            workspace.updateComparison(committedProfile)
            editRevision += 1
            presetName = ""
        }
    }
    @discardableResult private func updateLibrary(_ edit: (inout Settings) throws -> Void) -> Bool {
        var next = settings
        do {
            try edit(&next)
            // Persist the candidate before publishing the library mutation.
            try writeSettings(next)
            settings = next
            let selection = next.selectedPresetName(forOutput: selectedUID)
            if selectedPresetName != selection { editRevision += 1 }
            selectedPresetName = selection
            committedProfile.selectedPresetName = selectedPresetName
            workspace.updateComparison(committedProfile)
            customPresets = next.presets.keys.sorted()
            favoritePresets = next.favoritePresets ?? []
            error = nil
            return true
        } catch { self.error = "Could not update presets: " + error.localizedDescription; return false }
    }
    @discardableResult func renamePreset(_ name: String, to newName: String) -> Bool {
        let changed = updateLibrary { try $0.renamePreset(name, to: newName) }
        if changed { workspace.renamePreset(name, to: newName.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return changed
    }
    func duplicatePreset(_ name: String) {
        _ = updateLibrary { try $0.duplicatePreset(name) }
    }
    func deletePreset(_ name: String) {
        guard let saved = settings.presets[name] else { error = "The preset no longer exists."; return }
        let favorite = favoritePresets.contains(name)
        if updateLibrary({
            try $0.deletePreset(name)
        }) {
            workspace.renamePreset(name, to: nil)
            deletedPreset = (name, saved, favorite)
        }
    }
    func restoreDeletedPreset() {
        guard let deletedPreset else { error = "There is no deleted preset to restore."; return }
        if updateLibrary({
            let name = $0.availablePresetName(deletedPreset.name)
            $0.presets[name] = deletedPreset.profile
            if deletedPreset.favorite {
                var favorites = $0.favoritePresets ?? []
                favorites.insert(name)
                $0.favoritePresets = favorites
            }
        }) {
            self.deletedPreset = nil
        }
    }
    func toggleFavorite(_ name: String) {
        _ = updateLibrary { try $0.toggleFavorite(name) }
    }
    func adjustPreamp(_ delta: Double) {
        guard delta.isFinite else { error = "Preamp adjustment must be a finite number."; return }
        setPreamp(min(profile.preampRange.upperBound, max(profile.preampRange.lowerBound, profile.preamp + delta)))
    }
    func exportEQ() {
        let panel = NSSavePanel()
        panel.title = "Export Equalizer APO settings"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Aural EQ.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AutoEQ.export(profile).write(to: url, atomically: true, encoding: .utf8)
            error = nil; importNotice = "Exported EQ settings."
        } catch { self.error = "Could not export EQ: " + error.localizedDescription }
    }
    func backupPresets() {
        let panel = NSSavePanel()
        panel.title = "Back up custom presets"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Aural presets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(PresetBackup(presets: settings.presets, favorites: settings.favoritePresets))
            _ = try PresetBackup.decode(data)
            try data.write(to: url, options: .atomic)
            error = nil; importNotice = "Backed up custom presets."
        } catch { self.error = "Could not back up presets: " + error.localizedDescription }
    }
    func restorePresets() {
        let panel = NSOpenPanel()
        panel.title = "Restore custom presets"
        panel.message = "Adds presets without replacing existing names or changing the current EQ."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size <= 4 * 1024 * 1024 else { throw AudioFailure(message: "Preset backups must be smaller than 4 MB.") }
            let backup = try PresetBackup.decode(Data(contentsOf: url))
            if updateLibrary({ $0.mergePresets(backup) }) {
                importNotice = "Restored \(backup.presets.count) presets. Current EQ unchanged."
            }
        } catch { self.error = "Could not restore presets: " + error.localizedDescription }
    }
    func headroom() {
        var maximum = 0.0
        for i in 0...1000 {
            let f = 20 * pow(min(20000, responseRate * 0.48)/20, Double(i)/1000)
            maximum = max(maximum, profile.response(f, rate: responseRate, preamp: 0))
        }
        maximum = max(0, maximum + profile.stereoSettings.headroomGainDB)
        let preamp = min(profile.preampRange.upperBound, max(profile.preampRange.lowerBound, -ceil(maximum * 10)/10))
        editProfile("Calculate headroom") { var next = $0; next.preamp = preamp; return next }
    }
    func start() {
        pendingStartup = nil; startupNotice = nil
        guard let selected else { error = "Connect and select a stereo audio output."; return }
        startGeneration += 1
        let generation = startGeneration
        // Leave SwiftUI's synchronous accessibility action before entering HAL.
        // Core Audio may synchronously consult the app while registering its IO callback.
        DispatchQueue.main.async { [self] in
            guard generation == startGeneration else { return }
            do { try route.start(selected, profile: profile, bypass: bypass); running = true; error = nil; importNotice = nil }
            catch { running = false; self.error = error.localizedDescription }
        }
    }
    func stop() {
        startGeneration += 1
        pendingStartup = nil; startupNotice = nil
        do { try route.stop(); running = false; peak = 0 }
        catch { self.error = error.localizedDescription }
    }
    func refresh() {
        do { devices = try AudioRoute.devices() } catch { fail(error) }
    }
    private func fail(_ failure: Error) {
        pendingStartup = nil; startupNotice = nil
        let reason = failure.localizedDescription
        do { try route.stop(); running = false; peak = 0; error = reason }
        catch { self.error = reason + " Cleanup: " + error.localizedDescription + " Quit Aural to release its route." }
    }
    private func poll() {
        peak = route.peak
        ticks += 1
        guard ticks % 10 == 0 else { return }
        do {
            if running { try route.verify() }
            let current = try AudioRoute.devices()
            if current != devices { devices = current }
            refreshLoginStatus()
            if let plan = pendingStartup {
                switch plan.decision(availableUIDs: current.map(\.uid), now: Date()) {
                case .wait: break
                case .start:
                    pendingStartup = nil
                    bypass = false
                    start()
                case .unavailable, .missingOutput:
                    pendingStartup = nil; startupNotice = nil
                    error = "Automatic EQ could not find the saved output within 60 seconds. Connect it, select it, and click Start EQ."
                }
            }
            if running, selected == nil { throw AudioFailure(message: "The selected device disconnected. Choose an output and start again.") }
        } catch { fail(error) }
    }
    @discardableResult private func persist() -> Bool {
        settings.selectedUID = selectedUID
        do {
            if !selectedUID.isEmpty {
                settings.devices[selectedUID] = profile
                try settings.setSelectedPreset(selectedPresetName, forOutput: selectedUID)
            }
            try writeSettings(settings)
            return true
        } catch { self.error = "Could not save settings: " + error.localizedDescription; return false }
    }
    private func writeSettings(_ value: Settings) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
    }

}
