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
        bypass = false
        persist()
    }
    func change() {
        do { _ = try profile.validated(); try route.update(profile, bypass: bypass); persist() }
        catch { fail(error) }
    }
    func apply(_ name: String) {
        guard let p = factory[name] ?? settings.presets[name] else { error = "The preset no longer exists."; return }
        replaceProfile(p, selectingPreset: name)
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
        profile = imported
        bypass = false
        settings.presets[name] = imported
        selectedPresetName = name
        customPresets = settings.presets.keys.sorted()
        error = nil
        if persist() {
            importNotice = "Imported \(name). Saved in Presets. Click Start EQ to apply."
        } else { importNotice = nil }
    }
    @discardableResult func replaceProfile(_ next: Profile, selectingPreset name: String? = nil) -> Bool {
        do {
            // The control path prepares coefficients; the callback crossfades complete chains.
            // Validate and enqueue before replacing the visible or saved profile.
            var candidate = settings
            if let name, !selectedUID.isEmpty {
                try candidate.setSelectedPreset(name, forOutput: selectedUID)
            }
            try route.update(next, bypass: false)
            settings = candidate
            profile = next
            if let name { selectedPresetName = name }
            bypass = false
            importNotice = nil
            error = nil
            guard persist() else { return false }
            if !running { start() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, factory[name] == nil else { error = "Choose a preset name other than a built-in preset."; return }
        let saved = profile
        if updateLibrary({
            _ = try saved.validated()
            $0.presets[name] = saved
            if !selectedUID.isEmpty { try $0.setSelectedPreset(name, forOutput: selectedUID) }
        }) { selectedPresetName = name; presetName = "" }
    }
    @discardableResult private func updateLibrary(_ edit: (inout Settings) throws -> Void) -> Bool {
        var next = settings
        do {
            try edit(&next)
            // Persist the candidate before publishing the library mutation.
            try writeSettings(next)
            settings = next
            selectedPresetName = next.selectedPresetName(forOutput: selectedUID)
            customPresets = next.presets.keys.sorted()
            favoritePresets = next.favoritePresets ?? []
            error = nil
            return true
        } catch { self.error = "Could not update presets: " + error.localizedDescription; return false }
    }
    @discardableResult func renamePreset(_ name: String, to newName: String) -> Bool {
        updateLibrary { try $0.renamePreset(name, to: newName) }
    }
    func duplicatePreset(_ name: String) {
        _ = updateLibrary { try $0.duplicatePreset(name) }
    }
    func deletePreset(_ name: String) {
        guard let saved = settings.presets[name] else { error = "The preset no longer exists."; return }
        let favorite = favoritePresets.contains(name)
        if updateLibrary({
            try $0.deletePreset(name)
        }) { deletedPreset = (name, saved, favorite) }
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
        var next = profile
        next.preamp = min(next.preampRange.upperBound, max(next.preampRange.lowerBound, next.preamp + delta))
        do {
            try route.update(next, bypass: bypass)
            profile = next
            if persist() { error = nil }
        } catch { self.error = error.localizedDescription }
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
        profile.preamp = max(profile.preampRange.lowerBound, -ceil(maximum * 10)/10)
        change()
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
