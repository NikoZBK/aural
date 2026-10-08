import SwiftUI
import Combine

private struct PrecisionSubmissionsKey: FocusedValueKey {
    typealias Value = PrecisionSubmissionCoordinator
}

extension FocusedValues {
    var precisionSubmissions: PrecisionSubmissionCoordinator? {
        get { self[PrecisionSubmissionsKey.self] }
        set { self[PrecisionSubmissionsKey.self] = newValue }
    }
}

#if !AURAL_TESTING
@main
#endif
struct AuralApp: App {
    @NSApplicationDelegateAdaptor(AuralAppDelegate.self) private var delegate
    private var model: Model { delegate.model }
    var body: some Scene {
        Window("Aural", id: "main") { MainView(model: model, icon: delegate.icon).background(WindowRegistration()) }
            .defaultSize(width: 1040, height: 690)
            .windowResizability(.contentMinSize)
            .commands { AuralCommands(model: model) }
        Window("Preset library", id: "presets") { PresetLibraryView(model: model).auralZoom(model).background(WindowRegistration()) }
            .defaultSize(width: 800, height: 580)
            .windowResizability(.contentMinSize)
        Window("AutoEQ profiles", id: "autoeq") { AutoEQBrowserView(model: model).auralZoom(model).background(WindowRegistration()) }
            .defaultSize(width: 880, height: 700)
            .windowResizability(.contentMinSize)
        Window("About Aural", id: "about") { AboutView(model: model, icon: delegate.icon).auralZoom(model).background(WindowRegistration()) }
            .windowResizability(.contentSize)
        Window("Software updates", id: "updates") { UpdatesView(model: model).auralZoom(model).background(WindowRegistration()) }
            .windowResizability(.contentSize)
        Window("Keyboard shortcuts", id: "shortcuts") {
            KeyboardShortcutsView(model: model).auralZoom(model)
                .background(WindowRegistration())
        }.defaultSize(width: 540, height: 600).windowResizability(.contentMinSize)
        MenuBarExtra("Aural", systemImage: "headphones") { MenuBarControls(model: model) }
    }
}

@MainActor final class AuralAppDelegate: NSObject, NSApplicationDelegate {
    let model: Model
    let icon: AppIconController
    private var themeSubscription: AnyCancellable?

    override init() {
        let model = Model()
        self.model = model
        icon = AppIconController(running: model.$running.eraseToAnyPublisher(), bypass: model.$bypass.eraseToAnyPublisher()) { [weak model] message in
            model?.error = message
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep native menus, alerts, and file panels consistent with the SwiftUI windows.
        themeSubscription = model.$theme.sink { NSApp.appearance = $0.appearance }
        icon.startUpdatingApplicationIcon()
        #if !AURAL_TESTING
        UpdateChecker.shared.start()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) { model.refreshLoginStatus() }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}

struct AuralCommands: Commands {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.precisionSubmissions) private var submissions
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Equalizer") {
            Group {
                Button(model.undoLabel) { if submitPendingInput() { withAuralAnimation { model.undoProfile() } } }.disabled(!model.canUndo)
                    .keyboardShortcut("z", modifiers: [.command])
                Button(model.redoLabel) { if submitPendingInput() { withAuralAnimation { model.redoProfile() } } }.disabled(!model.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Divider()
                Button("Compare A") { if submitPendingInput() { withAuralAnimation { model.selectComparison(.a) } } }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Compare B") { if submitPendingInput() { withAuralAnimation { model.selectComparison(.b) } } }.keyboardShortcut("2", modifiers: [.command, .option])
                Divider()
            }
            Button("Bypass EQ") { withAuralAnimation { model.setBypass(!model.bypass) } }.keyboardShortcut("b", modifiers: [.command, .option])
            Toggle("Match levels", isOn: Binding(get: { model.matchLevels }, set: model.setMatchLevels))
            Toggle("Peak protection", isOn: Binding(get: { model.peakProtectionEnabled }, set: model.setPeakProtection))
            Toggle("Loudness compensation", isOn: Binding(get: { model.loudness.enabled }, set: model.setLoudnessEnabled))
            Toggle("Follow macOS output", isOn: Binding(get: { model.followSystemOutput }, set: model.setFollowSystemOutput))
            Divider()
            Group {
                Button("Copy EQ") { if submitPendingInput() { model.copyEQ() } }.keyboardShortcut("c", modifiers: [.command, .shift])
            }
            Button("Paste EQ") { if submitPendingInput() { withAuralAnimation { model.pasteEQ() } } }.keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Search AutoEQ profiles…") { if submitPendingInput() { openWindow.showAuralWindow("autoeq") } }
            Button("Import AutoEQ…") { if submitPendingInput() { model.importAutoEQ() } }
            Group { Button("Export EQ…") { if submitPendingInput() { model.exportEQ() } } }
            Divider()
            Button("Preset library…") { openWindow.showAuralWindow("presets") }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appInfo) {
            Button("About Aural") { openWindow.showAuralWindow("about") }
            Button("Check for Updates…") { openWindow.showAuralWindow("updates") }
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard shortcuts…") { openWindow.showAuralWindow("shortcuts") }
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { model.zoomIn() }.keyboardShortcut("+", modifiers: .command)
                .disabled(model.interfaceZoom == .largest)
            Button("Zoom Out") { model.zoomOut() }.keyboardShortcut("-", modifiers: .command)
                .disabled(model.interfaceZoom == .smallest)
            Button("Actual Size") { model.resetZoom() }.keyboardShortcut("0", modifiers: .command)
                .disabled(model.interfaceZoom == .actualSize)
            Divider()
            ThemePicker(model: model)
            FilterPanelPositionPicker(model: model)
        }
    }
    private func submitPendingInput() -> Bool {
        switch submissions?.submitActive() ?? .unchanged {
        case .rejected: return false
        case .submitted: return model.error == nil
        case .unchanged: return true
        }
    }
}

struct MenuBarControls: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(model.running || model.waitingForOutput ? "Stop equalization" : "Start equalization") { model.toggleProcessing() }
        Toggle("Follow macOS output", isOn: Binding(get: { model.followSystemOutput }, set: model.setFollowSystemOutput))
        Toggle("Bypass EQ", isOn: Binding(get: { model.bypass }, set: model.setBypass))
        Toggle("Match levels", isOn: Binding(get: { model.matchLevels }, set: model.setMatchLevels))
        Toggle("Peak protection", isOn: Binding(get: { model.peakProtectionEnabled }, set: model.setPeakProtection))
        Toggle("Loudness compensation", isOn: Binding(get: { model.loudness.enabled }, set: model.setLoudnessEnabled))
        Menu("Preset: \(model.currentPresetTitle)") { PresetMenuItems(model: model) }
        Button("Preset library…") { openWindow.showAuralWindow("presets") }
        Button("Search AutoEQ profiles…") { openWindow.showAuralWindow("autoeq") }
        Group {
            Menu("Preamp: \(model.profile.preamp, specifier: "%.2f") dB") {
                Button("Increase 1 dB") { model.adjustPreamp(1) }
                    .disabled(model.profile.preamp >= model.profile.preampRange.upperBound)
                Button("Decrease 1 dB") { model.adjustPreamp(-1) }
                    .disabled(model.profile.preamp <= model.profile.preampRange.lowerBound)
            }
            Menu("Compare: \(model.comparisonSlot.rawValue.uppercased())") {
                Button("A") { withAuralAnimation { model.selectComparison(.a) } }
                Button("B") { withAuralAnimation { model.selectComparison(.b) } }
                Button("Copy current to other slot") { withAuralAnimation { model.copyComparisonToOther() } }
            }
        }
        Divider()
        ThemePicker(model: model)
        Button("Show Aural") { openWindow.showAuralWindow("main") }
        Button("Keyboard shortcuts…") { openWindow.showAuralWindow("shortcuts") }
        Button("About Aural") { openWindow.showAuralWindow("about") }
        Button("Check for Updates…") { openWindow.showAuralWindow("updates") }
        Button("Quit Aural") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct ThemePicker: View {
    @ObservedObject var model: Model
    var body: some View {
        Picker("Theme", selection: Binding(get: { model.theme }, set: model.setTheme)) {
            ForEach(AuralTheme.allCases, id: \.self) { theme in Text(theme.label).tag(theme) }
        }.help("System follows your Mac's appearance. Light or Dark keeps Aural in that theme.")
    }
}

struct FilterPanelPositionPicker: View {
    @ObservedObject var model: Model
    var body: some View {
        Picker("Filter panel position", selection: Binding(get: { model.filterPanelPosition }, set: model.setFilterPanelPosition)) {
            ForEach(FilterPanelPosition.allCases, id: \.self) { position in
                Label(position.label, systemImage: position.symbol).tag(position)
            }
        }
    }
}

struct StartupSettings: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14 * interfaceScale) {
            Text("Appearance").font(.headline)
            ThemePicker(model: model).pickerStyle(.segmented)
            Text("System follows your Mac's appearance.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Output").font(.headline)
            Toggle("Follow macOS output", isOn: Binding(get: { model.followSystemOutput }, set: model.setFollowSystemOutput))
            Text("When macOS switches its sound output, Aural switches too and loads that output's saved EQ. EQ stays on if it was running.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Listening").font(.headline)
            Toggle("Match levels for Bypass and A/B", isOn: Binding(get: { model.matchLevels }, set: model.setMatchLevels))
            Text("Plays Bypass and the louder A/B version at the same estimated loudness, so louder doesn't sound better. Saved presets don't change.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Loudness compensation", isOn: Binding(get: { model.loudness.enabled }, set: model.setLoudnessEnabled))
            Text("Restores bass and treble as you turn the volume down, following the ISO 226 equal-loudness contours. At the reference volume, EQ plays as set.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.loudness.enabled { LoudnessReference(model: model).transition(.opacity) }
            Divider()
            Text("Startup").font(.headline)
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLoginRequested }, set: model.setLaunchAtLogin))
                .disabled(model.loginStatus == nil)
            if model.loginStatus == nil {
                Text("Checking launch-at-login status…").font(.caption).foregroundStyle(.secondary).transition(.opacity)
            }
            Toggle("Start EQ automatically", isOn: Binding(get: { model.startEQAutomatically }, set: model.setStartAutomatically))
            Text("Use the saved output and preset on launch. Wait up to 60 seconds if the device is disconnected. Stop pauses EQ for this session.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.loginStatus == .requiresApproval {
                Group {
                    Text("macOS approval is needed to launch at login.").font(.caption).foregroundStyle(AuralStyle.warning)
                    Button("Open Login Items settings") { model.openLoginSettings() }
                }.transition(.opacity)
            }
            Divider()
            if let error = model.error { AuralNotice(message: error, isError: true).transition(.opacity) }
            Button("About Aural") { openWindow.showAuralWindow("about") }
            Button("Check for Updates…") { openWindow.showAuralWindow("updates") }
        }
        .auralAnimation(AuralMotion.quick, value: StartupMotion(status: model.loginStatus?.rawValue, error: model.error))
        .auralPadding(18).auralFrame(width: 300).auralAppearance(model.theme).onAppear { model.refreshLoginStatus() }
    }
}

private struct StartupMotion: Equatable { let status: Int?; let error: String? }

struct LoudnessReference: View {
    @ObservedObject var model: Model
    var body: some View {
        Picker("Reference level", selection: Binding(get: { model.loudness.referenceLevel }, set: model.setLoudnessReferenceLevel)) {
            ForEach(Loudness.referenceLevels, id: \.self) { level in Text("\(Int(level)) phon").tag(level) }
        }.help("How loud music is at the reference volume. 80 phon suits a comfortable, full listening level.")
        Button("Use current volume as reference") { model.setLoudnessReference() }
            .disabled(model.outputVolume == nil)
            .help("Set the reference where the EQ sounds right at your usual listening level. Lower volumes are compensated.")
        Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private var status: String {
        let name = model.selected?.name ?? "The selected output"
        guard let volume = model.outputVolume else { return "\(name) has no volume control in macOS, so there is nothing to compensate." }
        guard let level = model.loudnessLevel, let reference = model.loudness.referenceVolumes[model.selectedUID] else { return "Reading the volume of \(name)…" }
        guard level < model.loudness.referenceLevel else { return "\(name) is at or above its reference volume, so EQ plays as set." }
        let curve = Loudness.curve(level: level, reference: model.loudness.referenceLevel)
        return String(format: "%.1f dB below the reference: listening at %.0f phon, so bass rises %.1f dB at 50 Hz and treble %.1f dB at 12.5 kHz.",
                      reference - volume, level, Loudness.compensation(at: 50, curve: curve), Loudness.compensation(at: 12500, curve: curve))
    }
}
