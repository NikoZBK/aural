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
    @Published var importNotice: String?
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
    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aural/settings.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
                for p in Array(settings.devices.values) + Array(settings.presets.values) { _ = try p.validated() }
            }
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
            customPresets = settings.presets.keys.sorted()
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
        bypass = false
        persist()
    }
    func change() {
        do { _ = try profile.validated(); try route.update(profile, bypass: bypass); persist() }
        catch { fail(error) }
    }
    func apply(_ name: String) {
        guard let p = factory[name] ?? settings.presets[name] else { error = "The preset no longer exists."; return }
        replaceProfile(p)
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
            let imported = try AutoEQ.parse(text, name: base)
            // No state changes occur until the entire file has passed validation.
            startGeneration += 1
            pendingStartup = nil; startupNotice = nil
            try route.stop(); running = false; peak = 0
            var name = base, suffix = 2
            while settings.presets[name] != nil || factory[name] != nil {
                name = "\(base) (\(suffix))"; suffix += 1
            }
            profile = imported
            bypass = false
            settings.presets[name] = imported
            customPresets = settings.presets.keys.sorted()
            error = nil
            if persist() {
                importNotice = "Imported \(name). Saved in Presets. Click Start EQ to apply."
            } else { importNotice = nil }
        } catch { self.error = error.localizedDescription }
    }
    private func replaceProfile(_ next: Profile) {
        do {
            // The audio callback resets changed filter state and smooths gains in place.
            // Validate and enqueue before replacing the visible or saved profile.
            try route.update(next, bypass: false)
            profile = next
            bypass = false
            importNotice = nil
            error = nil
            persist()
            if !running { start() }
        } catch { self.error = error.localizedDescription }
    }

    func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, factory[name] == nil else { error = "Choose a preset name other than a built-in preset."; return }
        settings.presets[name] = profile
        customPresets = settings.presets.keys.sorted(); presetName = ""; persist()
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
        if !selectedUID.isEmpty { settings.devices[selectedUID] = profile }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: file, options: .atomic)
            return true
        } catch { self.error = "Could not save settings: " + error.localizedDescription; return false }
    }
}
