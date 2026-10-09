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
    let meter = AudioMeter()
    @Published var error: String?
    @Published var presetName = ""
    @Published var customPresets: [String] = []
    @Published private(set) var selectedPresetName: String?
    @Published var importNotice: String?
    @Published private(set) var deletedPreset: (name: String, profile: Profile, favorite: Bool)?
    @Published private(set) var favoritePresets: Set<String> = []
    @Published private(set) var startEQAutomatically = false
    @Published private(set) var peakProtectionEnabled = true
    @Published private(set) var followSystemOutput = false
    @Published private(set) var matchLevels = false
    @Published private(set) var levelMatch = LevelMatch.none
    @Published private(set) var loudness = LoudnessSettings()
    /// The selected output's volume in dB while loudness compensation is on; nil when it has no volume control.
    @Published private(set) var outputVolume: Double?
    @Published private(set) var interfaceMode: InterfaceMode = .easy
    @Published private(set) var theme: AuralTheme = .dark
    @Published private(set) var interfaceZoom: AuralInterfaceZoom = .actualSize
    @Published private(set) var filterPanelPosition: FilterPanelPosition = .below
    @Published private(set) var loginStatus: SMAppService.Status?
    @Published private(set) var startupNotice: String?
    @Published private(set) var editRevision = 0
    @Published private(set) var calculatingHeadroom = false
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
    private var systemOutputFollower = SystemOutputFollower()
    private var routeRecovery = RouteRecovery()
    let route = AudioRoute()
    private var settings = Settings()
    private var timer: Timer?
    private var ticks = 0
    private var observers: [NSObjectProtocol] = []
    private var loginStatusRefresh: Task<Void, Never>?
    private let readLoginStatus: @Sendable () -> SMAppService.Status
    private var headroomTask: Task<Void, Never>?
    private var appliedLoudnessLevel: Double?
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
    init(settingsFile: URL? = nil, readLoginStatus: @escaping @Sendable () -> SMAppService.Status = { SMAppService.mainApp.status }) {
        self.readLoginStatus = readLoginStatus
        file = settingsFile ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aural/settings.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let loaded = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
                for p in Array(loaded.devices.values) + Array(loaded.presets.values) { _ = try p.validated() }
                settings = loaded
            }
            interfaceMode = settings.interfaceMode
            theme = settings.theme
            interfaceZoom = settings.interfaceZoom
            filterPanelPosition = settings.filterPanelPosition
            peakProtectionEnabled = settings.peakProtectionEnabled
            followSystemOutput = settings.followSystemOutput
            matchLevels = settings.matchLevels
            loudness = settings.loudness
            settings.migratePresetSelections()
            devices = try AudioRoute.devices()
            let defaultID = try AudioRoute.defaultOutput()
            let systemOutput = devices.first(where: { $0.id == defaultID })
            systemOutputFollower = SystemOutputFollower(current: try? AudioRoute.systemOutput()?.uid)
            startEQAutomatically = settings.startEQAutomatically ?? false
            let followed = followSystemOutput ? systemOutput?.uid : nil
            selectedUID = followed ?? devices.first(where: { $0.uid == settings.selectedUID })?.uid ?? systemOutput?.uid ?? devices.first?.uid ?? ""
            if startEQAutomatically {
                // Following starts on the current macOS output with its own saved EQ.
                selectedUID = followed ?? settings.selectedUID
                pendingStartup = .launch(outputUID: selectedUID)
                startupNotice = "Waiting for the saved output to start EQ…"
            }
            profile = settings.devices[selectedUID] ?? Profile()
            selectedPresetName = settings.selectedPresetName(forOutput: selectedUID)
            customPresets = settings.presets.keys.sorted()
            favoritePresets = settings.favoritePresets ?? []
        } catch { pendingStartup = nil; startupNotice = nil; self.error = error.localizedDescription }
        committedProfile = ProfileSnapshot(profile: profile, selectedPresetName: selectedPresetName)
        levelMatch = levelMatch(for: profile, in: workspace)
        refreshLoudness()
        refreshLoginStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pauseForSleep() }
        })
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.resumeAfterWake() }
        })
    }
    var launchAtLoginRequested: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }
    func refreshLoginStatus() {
        loginStatusRefresh?.cancel()
        let readStatus = readLoginStatus
        loginStatusRefresh = Task { [weak self] in
            // ServiceManagement performs synchronous XPC. Never block layout or input.
            let status = await Task.detached(priority: .utility) { readStatus() }.value
            guard !Task.isCancelled, let self else { return }
            if self.loginStatus != status { self.loginStatus = status }
        }
    }
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
    func setInterfaceMode(_ mode: InterfaceMode) {
        guard interfaceMode != mode else { return }
        var next = settings
        next.interfaceMode = mode
        do {
            try writeSettings(next)
            settings = next
            endProfileGesture()
            interfaceMode = mode
            error = nil
        } catch { self.error = "Could not save interface mode: " + error.localizedDescription }
    }
    func setTheme(_ theme: AuralTheme) {
        guard self.theme != theme else { return }
        var next = settings
        next.theme = theme
        do {
            try writeSettings(next)
            settings = next
            self.theme = theme
            error = nil
        } catch { self.error = "Could not save theme: " + error.localizedDescription }
    }
    func setInterfaceZoom(_ zoom: AuralInterfaceZoom) {
        guard interfaceZoom != zoom else { return }
        var next = settings
        next.interfaceZoom = zoom
        do {
            try writeSettings(next)
            settings = next
            interfaceZoom = zoom
        } catch { self.error = "Could not save interface zoom: " + error.localizedDescription }
    }
    func zoomIn() { setInterfaceZoom(interfaceZoom.increased) }
    func zoomOut() { setInterfaceZoom(interfaceZoom.decreased) }
    func resetZoom() { setInterfaceZoom(.actualSize) }

    func setFilterPanelPosition(_ position: FilterPanelPosition) {
        guard filterPanelPosition != position else { return }
        var next = settings
        next.filterPanelPosition = position
        do {
            try writeSettings(next)
            settings = next
            filterPanelPosition = position
        } catch { self.error = "Could not save filter panel position: " + error.localizedDescription }
    }

    func setPeakProtection(_ enabled: Bool) {
        guard peakProtectionEnabled != enabled else { return }
        var next = settings
        next.peakProtectionEnabled = enabled
        do {
            try writeSettings(next)
            settings = next
            route.setPeakProtection(enabled)
            if !enabled { meter.update(meter.peak) }
            peakProtectionEnabled = enabled
        } catch { self.error = "Could not save peak protection: " + error.localizedDescription }
    }

    func setMatchLevels(_ enabled: Bool) {
        guard matchLevels != enabled else { return }
        var next = settings
        next.matchLevels = enabled
        do {
            try writeSettings(next)
            settings = next
            matchLevels = enabled
            refreshLevelMatch()
        } catch { self.error = "Could not save level matching: " + error.localizedDescription }
    }

    /// The listening level for loudness compensation in phon, or nil while it is off or
    /// the output has no volume control.
    var loudnessLevel: Double? {
        guard loudness.enabled, let outputVolume, let reference = loudness.referenceVolumes[selectedUID] else { return nil }
        return Loudness.listeningLevel(volume: outputVolume, referenceVolume: reference, referenceLevel: loudness.referenceLevel)
    }
    func setLoudnessEnabled(_ enabled: Bool) {
        guard loudness.enabled != enabled else { return }
        var next = loudness
        next.enabled = enabled
        saveLoudness(next)
    }
    func setLoudnessReferenceLevel(_ level: Double) {
        guard loudness.referenceLevel != level, Loudness.referenceLevels.contains(level) else { return }
        var next = loudness
        next.referenceLevel = level
        saveLoudness(next)
    }
    /// The selected output's current volume becomes its reference: EQ plays as set there,
    /// and quieter volumes are compensated.
    func setLoudnessReference() {
        guard let selected, let volume = AudioRoute.volume(of: selected.id) else {
            error = "\(selected?.name ?? "This output") has no volume control in macOS, so loudness compensation has no volume to follow."
            return
        }
        var next = loudness
        next.referenceVolumes[selected.uid] = volume
        saveLoudness(next)
    }
    private func saveLoudness(_ next: LoudnessSettings) {
        var candidate = settings
        candidate.loudness = next
        do {
            try writeSettings(candidate)
            settings = candidate
            loudness = next
            refreshLoudness()
        } catch { self.error = "Could not save loudness compensation: " + error.localizedDescription }
    }
    /// Follows the selected output's volume. The first reading on an output without a
    /// reference becomes its reference, so turning compensation on never changes the sound at once.
    private func refreshLoudness() {
        let volume = loudness.enabled ? selected.flatMap { AudioRoute.volume(of: $0.id) } : nil
        if volume != outputVolume { outputVolume = volume }
        if let volume, !selectedUID.isEmpty, loudness.referenceVolumes[selectedUID] == nil {
            // Kept even if saving fails, so a failed write is reported once.
            settings.loudness.referenceVolumes[selectedUID] = volume
            loudness = settings.loudness
            do { try writeSettings(settings) }
            catch { self.error = "Could not save the loudness reference: " + error.localizedDescription }
        }
        let level = loudnessLevel
        guard running, level != appliedLoudnessLevel else { return }
        appliedLoudnessLevel = level
        route.loudness = loudnessFilters(level)
        do { try route.update(committedProfile.profile, bypass: bypass, levelMatch: levelMatch) }
        catch { self.error = error.localizedDescription }
    }
    private func loudnessFilters(_ level: Double?) -> [EQFilter] {
        level.map { Loudness.filters(level: $0, reference: loudness.referenceLevel) } ?? []
    }

    func setFollowSystemOutput(_ enabled: Bool) {
        guard followSystemOutput != enabled else { return }
        var next = settings
        next.followSystemOutput = enabled
        do {
            try writeSettings(next)
            settings = next
            followSystemOutput = enabled
            // Turning following on moves to the current macOS output right away.
            systemOutputFollower = SystemOutputFollower()
            if enabled, let output = try? AudioRoute.systemOutput(), systemOutputFollower.change(to: output.uid) != nil {
                follow(output)
            }
        } catch { self.error = "Could not save output following: " + error.localizedDescription }
    }

    func setStartAutomatically(_ enabled: Bool) {
        if enabled, selected == nil { error = "Select a connected output before enabling automatic EQ."; return }
        let previous = startEQAutomatically
        settings.startEQAutomatically = enabled
        if persist() { startEQAutomatically = enabled }
        else { settings.startEQAutomatically = previous }
        // Only the launch wait belongs to this setting; resuming after sleep or a disconnect continues.
        if !startEQAutomatically, let plan = pendingStartup, !plan.resumes { startGeneration += 1; pendingStartup = nil; startupNotice = nil }
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
        levelMatch = levelMatch(for: profile, in: workspace)
        persist()
        refreshLoudness()
    }
    func change() {
        // Legacy SwiftUI bindings may already have changed the visible value. The
        // last accepted snapshot remains the source of truth for undo and rollback.
        _ = commitProfile(ProfileSnapshot(profile: profile, selectedPresetName: selectedPresetName), label: "Adjust EQ")
    }
    func setBypass(_ value: Bool) {
        do {
            let match = levelMatch(for: profile, in: workspace)
            try route.update(profile, bypass: value, levelMatch: match)
            bypass = value
            levelMatch = match
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    /// Level matching depends on the playing version and, while comparing, the
    /// other A/B version. Off returns the original, unmatched playback.
    private func levelMatch(for profile: Profile, in workspace: ProfileWorkspace) -> LevelMatch {
        guard matchLevels else { return .none }
        let other = workspace.comparisonAvailable ? workspace.otherComparison?.profile : nil
        return LevelMatch(current: profile, comparedWith: other)
    }
    private func refreshLevelMatch() {
        let match = levelMatch(for: committedProfile.profile, in: workspace)
        guard match != levelMatch else { return }
        do {
            try route.update(committedProfile.profile, bypass: bypass, levelMatch: match)
            levelMatch = match
        } catch { self.error = error.localizedDescription }
    }
    func apply(_ name: String) {
        guard let p = factory[name] ?? settings.presets[name] else { error = "The preset no longer exists."; return }
        if commitProfile(ProfileSnapshot(profile: p, selectedPresetName: name), label: "Apply \(name)", nextBypass: false), !running { start() }
    }
    func importAutoEQ() {
        let panel = NSOpenPanel()
        panel.title = "Import AutoEQ profile"
        panel.message = "Choose an AutoEQ ParametricEQ.txt or FixedBandEQ.txt file, an Equalizer APO configuration, or a Room EQ Wizard filter file. Import stops processing; click Start EQ when ready."
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size <= 65536 else { throw AudioFailure(message: "The profile exceeds the 64 KB limit.") }
            let data = try Data(contentsOf: url)
            // Like Equalizer APO, fall back to the Windows code page for files that are not UTF-8.
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
                throw AudioFailure(message: "Use a UTF-8 text file.")
            }
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
        try importProfile(imported, name: base)
    }
    func importOnlineAutoEQ(_ preview: AutoEQPreview) {
        do { try importProfile(preview.profile, name: preview.entry.presetName) }
        catch { self.error = error.localizedDescription }
    }
    private func importProfile(_ proposed: Profile, name base: String) throws {
        let imported = try proposed.validated()
        // Validate everything before changing the profile or stopping audio.
        startGeneration += 1
        pendingStartup = nil; startupNotice = nil
        try route.stop(); running = false; meter.update(0)
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
        levelMatch = levelMatch(for: imported, in: workspace)
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
                                                 nextWorkspace: ProfileWorkspace? = nil,
                                                 coalescing: Bool = false) -> Bool {
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
            let match = levelMatch(for: snapshot.profile, in: nextWorkspace ?? workspace)
            try route.update(snapshot.profile, bypass: nextBypass ?? bypass, levelMatch: match)
            // Focus can submit an unchanged number after another editor opens.
            // Only a different document or comparison target invalidates its draft.
            let documentChanged = snapshot != committedProfile ||
                (nextWorkspace?.comparisonSlot ?? workspace.comparisonSlot) != workspace.comparisonSlot
            if let nextWorkspace { workspace = nextWorkspace }
            else { workspace.record(before: committedProfile, after: snapshot, label: label, coalescing: coalescing) }
            profile = snapshot.profile
            selectedPresetName = snapshot.selectedPresetName
            committedProfile = snapshot
            if documentChanged { editRevision += 1 }
            workspace.updateComparison(snapshot)
            if let nextBypass { bypass = nextBypass }
            levelMatch = match
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
    func endProfileGesture() {
        guard workspace.hasActiveGesture else { return }
        workspace.endGesture()
    }
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
        refreshLevelMatch()
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
            refreshLevelMatch()
            importNotice = "Copied \(comparisonSlot.rawValue) to \(comparisonSlot.other.rawValue)."
        } catch { self.error = error.localizedDescription }
    }
    private func editProfile(_ label: String, coalescing: Bool = false, _ edit: (Profile) throws -> Profile) {
        do {
            let next = try edit(profile)
            _ = commitProfile(ProfileSnapshot(profile: next, selectedPresetName: selectedPresetName), label: label, coalescing: coalescing)
        } catch { self.error = error.localizedDescription }
    }
    func setPreamp(_ value: Double) {
        editProfile("Adjust preamp", coalescing: true) { var next = $0; next.preamp = value; return next }
    }
    func setGraphicGain(at index: Int, to value: Double) {
        editProfile("Adjust graphic band", coalescing: true) {
            guard $0.filters == nil, $0.gains.indices.contains(index) else {
                throw AudioFailure(message: "This graphic band no longer exists.")
            }
            var next = $0; next.gains[index] = value; return next
        }
    }
    func setBandGain(at index: Int, to value: Double) {
        guard let filters = profile.filters else { setGraphicGain(at: index, to: value); return }
        guard filters.indices.contains(index), filters[index].kind.usesGain else {
            error = "This band does not have an adjustable gain."
            return
        }
        var filter = filters[index]
        filter.gain = value
        updateFilter(at: index, with: filter)
    }
    func setStereoSettings(_ value: StereoSettings) {
        editProfile("Adjust stereo", coalescing: true) { var next = $0; next.stereo = value.isNeutral ? nil : value; return next }
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
    func resetEQ() {
        editProfile("Reset EQ") {
            var next = try ProfileTools.transformGains($0, scale: 0, offset: 0)
            next.preamp = 0
            next.tilt = 0
            return next
        }
    }
    func setTilt(_ value: Double) {
        editProfile("Adjust tilt", coalescing: true) { var next = $0; next.tilt = value; return next }
    }
    func adjustTilt(_ delta: Double) {
        guard delta.isFinite else { error = "Tilt adjustment must be a finite number."; return }
        workspace.endGesture()
        setTilt(min(Profile.tiltRange.upperBound, max(Profile.tiltRange.lowerBound, ((profile.tilt + delta) * 10).rounded() / 10)))
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
        editProfile("Edit filter", coalescing: true) { try ProfileTools.updateFilter($0, at: index, with: filter) }
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
        if updateLibrary(selecting: name, {
            _ = try saved.validated()
            $0.presets[name] = saved
            if !selectedUID.isEmpty { try $0.setSelectedPreset(name, forOutput: selectedUID) }
        }) {
            presetName = ""
        }
    }
    @discardableResult private func updateLibrary(selecting requestedSelection: String? = nil,
                                                 _ edit: (inout Settings) throws -> Void) -> Bool {
        var next = settings
        do {
            try edit(&next)
            let selection = requestedSelection ?? next.selectedPresetName(forOutput: selectedUID, fallback: selectedPresetName)
            if let selection, next.preset(named: selection) == nil {
                throw AudioFailure(message: "The selected preset no longer exists.")
            }
            // Persist the candidate before publishing the library mutation.
            try writeSettings(next)
            settings = next
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
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = selectedPresetName == name ? trimmedName : nil
        let changed = updateLibrary(selecting: selection) { try $0.renamePreset(name, to: newName) }
        if changed { workspace.renamePreset(name, to: trimmedName) }
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
        workspace.endGesture()
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
        headroomTask?.cancel()
        let snapshot = profile, rate = responseRate, revision = editRevision, output = selectedUID
        calculatingHeadroom = true
        headroomTask = Task { [weak self] in
            let preamp = await EQAnalysisWorker.shared.calculate { Headroom.preamp(for: snapshot, rate: rate) }
            guard !Task.isCancelled, let preamp, let self else { return }
            self.calculatingHeadroom = false
            guard self.editRevision == revision, self.selectedUID == output, self.responseRate == rate,
                  self.profile.hasSameEQ(as: snapshot) else {
                self.error = "The EQ changed while calculating headroom. Click Auto preamp again."
                return
            }
            self.editProfile("Calculate headroom") { var next = $0; next.preamp = preamp; return next }
        }
    }
    /// EQ is waiting for an output at launch, after sleep, or after a disconnect.
    /// Every wait shows a notice, which also covers a resumed start in progress.
    var waitingForOutput: Bool { startupNotice != nil }
    func toggleProcessing(submitPendingInput: () -> Bool = { true }) {
        // Stopping releases the connection even when a numeric draft is invalid.
        // Only starting needs to accept pending edits before changing the sound.
        // Stop also ends a wait, so EQ never resumes after the person turned it off.
        if running || waitingForOutput { stop() }
        else if submitPendingInput() { start() }
    }
    /// A resumed start keeps Bypass and its waiting notice until audio is back.
    func start(resuming plan: StartupPlan? = nil) {
        pendingStartup = nil
        if plan == nil { startupNotice = nil }
        guard let selected else { startupNotice = nil; error = "Connect and select a stereo audio output."; return }
        startGeneration += 1
        let generation = startGeneration
        let match = levelMatch(for: profile, in: workspace)
        // Leave SwiftUI's synchronous accessibility action before entering HAL.
        // Core Audio may synchronously consult the app while registering its IO callback.
        DispatchQueue.main.async { [self] in
            guard generation == startGeneration else { return }
            refreshLoudness()
            appliedLoudnessLevel = loudnessLevel
            route.loudness = loudnessFilters(appliedLoudnessLevel)
            do {
                try route.start(selected, profile: profile, bypass: bypass, peakProtectionEnabled: peakProtectionEnabled, levelMatch: match)
                running = true; levelMatch = match; error = nil; importNotice = nil; startupNotice = nil
            } catch {
                running = false
                if let retry = plan?.retry() { pendingStartup = retry }
                else { startupNotice = nil; self.error = error.localizedDescription }
            }
        }
    }
    func stop() {
        startGeneration += 1
        pendingStartup = nil; startupNotice = nil
        do { try route.stop(); running = false; meter.update(0) }
        catch { self.error = error.localizedDescription }
    }
    func refresh() {
        do { devices = try AudioRoute.devices() } catch { fail(error) }
    }
    private func fail(_ failure: Error) {
        pendingStartup = nil; startupNotice = nil
        let reason = failure.localizedDescription
        do { try route.stop(); running = false; meter.update(0); error = reason }
        catch { self.error = reason + " Cleanup: " + error.localizedDescription + " Quit Aural to release its route." }
    }
    private func poll() {
        meter.update(route.readMeter())
        ticks += 1
        // Follow volume changes quickly while EQ plays, and keep the controls current otherwise.
        if loudness.enabled, running || ticks % 10 == 0 { refreshLoudness() }
        guard ticks % 10 == 0 else { return }
        do {
            let current = try AudioRoute.devices()
            if current != devices { devices = current }
            // A failed read keeps the current output; it must never stop EQ.
            if followSystemOutput, let output = try? AudioRoute.systemOutput(),
               systemOutputFollower.change(to: output.uid) != nil {
                follow(output)
            }
            if running, selected == nil { try waitForOutput() }
            else if running {
                do { try route.verify() }
                catch {
                    guard routeRecovery.allowRestart() else { throw error }
                    try waitForOutput(restarting: true)
                }
            }
            if let plan = pendingStartup {
                switch plan.decision(availableUIDs: current.map(\.uid), now: Date()) {
                case .wait: break
                case .start:
                    if plan.resumes { start(resuming: plan) }
                    else {
                        pendingStartup = nil
                        bypass = false
                        start()
                    }
                case .unavailable, .missingOutput:
                    pendingStartup = nil; startupNotice = nil
                    error = "Automatic EQ could not find the saved output within 60 seconds. Connect it, select it, and click Start EQ."
                }
            }
        } catch { fail(error) }
    }
    /// Release the route and resume on this exact output when it is available.
    /// A disconnect waits for the device to return; a format change or reconnection
    /// restarts on the same device. Cancel or Stop ends the wait.
    private func waitForOutput(restarting: Bool = false) throws {
        let name = route.device?.name ?? selected?.name ?? "The output"
        let plan = StartupPlan.resume(outputUID: selectedUID, outputName: name, after: 1)
        startGeneration += 1
        try route.stop(); running = false; meter.update(0)
        pendingStartup = plan
        startupNotice = restarting ? "The audio route to \(name) changed. Restarting EQ…"
                                   : "\(name) disconnected. EQ resumes when it reconnects."
    }
    /// Sleep releases the route. EQ that was running, or waiting for its output,
    /// resumes on the same output after wake.
    private func pauseForSleep() {
        let target = running ? selectedUID : pendingStartup?.outputUID
        let name = selected?.name ?? pendingStartup?.outputName
        stop()
        guard let target, !target.isEmpty, !route.hasResources else { return }
        // Wake sets the real resume time. The fallback covers a wake notice that never arrives.
        pendingStartup = .resume(outputUID: target, outputName: name, after: 30)
        startupNotice = "EQ paused for sleep. It resumes on \(name ?? "the saved output") after wake."
    }
    private func resumeAfterWake() {
        guard var plan = pendingStartup, plan.resumes else { return }
        plan.notBefore = Date().addingTimeInterval(2)
        pendingStartup = plan
        startupNotice = "Resuming EQ on \(plan.outputName ?? "the saved output")…"
    }
    /// macOS switched its output. Move there with that output's saved EQ, and keep
    /// EQ on if it was running or waiting to resume. Aural never changes the default.
    private func follow(_ output: OutputDevice) {
        guard output.uid != selectedUID else { return }
        guard devices.contains(where: { $0.uid == output.uid }) else {
            importNotice = "macOS switched to \(output.name), which Aural cannot equalize. Aural supports outputs with one stereo stream, so it stays on \(selected?.name ?? "the selected output")."
            return
        }
        let resume = running || waitingForOutput
        select(output.uid)
        guard selectedUID == output.uid else { return }
        if resume { start() }
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
