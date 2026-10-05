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
                Button(model.undoLabel) { if submitPendingInput() { model.undoProfile() } }.disabled(!model.canUndo)
                    .keyboardShortcut("z", modifiers: [.command])
                Button(model.redoLabel) { if submitPendingInput() { model.redoProfile() } }.disabled(!model.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Divider()
                Button("Compare A") { if submitPendingInput() { model.selectComparison(.a) } }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Compare B") { if submitPendingInput() { model.selectComparison(.b) } }.keyboardShortcut("2", modifiers: [.command, .option])
                Divider()
            }
            Button("Bypass EQ") { model.setBypass(!model.bypass) }.keyboardShortcut("b", modifiers: [.command, .option])
            Divider()
            Group {
                Button("Copy EQ") { if submitPendingInput() { model.copyEQ() } }.keyboardShortcut("c", modifiers: [.command, .shift])
            }
            Button("Paste EQ") { if submitPendingInput() { model.pasteEQ() } }.keyboardShortcut("v", modifiers: [.command, .shift])
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
            InterfaceStylePicker(model: model)
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
        Button(model.running ? "Stop equalization" : "Start equalization") { model.toggleProcessing() }
        Toggle("Bypass EQ", isOn: Binding(get: { model.bypass }, set: model.setBypass))
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
                Button("A") { model.selectComparison(.a) }
                Button("B") { model.selectComparison(.b) }
                Button("Copy current to other slot") { model.copyComparisonToOther() }
            }
        }
        Divider()
        ThemePicker(model: model)
        InterfaceStylePicker(model: model)
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

struct StartupSettings: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Appearance").font(.headline)
            ThemePicker(model: model).pickerStyle(.segmented)
            Text("System follows your Mac's appearance.").font(.caption).foregroundStyle(.secondary)
            InterfaceStylePicker(model: model).pickerStyle(.segmented)
            Text(AuralInterfaceStyle.liquidGlassSupported
                 ? "Liquid Glass adds depth to controls. Reduce Transparency or Increase Contrast uses solid surfaces."
                 : "Liquid Glass requires macOS 26 or later. Saved choices use solid surfaces on this Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Startup").font(.headline)
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLoginRequested }, set: model.setLaunchAtLogin))
                .disabled(model.loginStatus == nil)
            if model.loginStatus == nil { Text("Checking launch-at-login status…").font(.caption).foregroundStyle(.secondary) }
            Toggle("Start EQ automatically", isOn: Binding(get: { model.startEQAutomatically }, set: model.setStartAutomatically))
            Text("Use the saved output and preset on launch. Wait up to 60 seconds if the device is disconnected. Stop pauses EQ for this session.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.loginStatus == .requiresApproval {
                Text("macOS approval is needed to launch at login.").font(.caption).foregroundStyle(AuralStyle.warning)
                Button("Open Login Items settings") { model.openLoginSettings() }
            }
            Divider()
            if let error = model.error { AuralNotice(message: error, isError: true) }
            Button("About Aural") { openWindow.showAuralWindow("about") }
            Button("Check for Updates…") { openWindow.showAuralWindow("updates") }
        }.padding(18).frame(width: 300).auralAppearance(model.theme, style: model.interfaceStyle).onAppear { model.refreshLoginStatus() }
    }
}

struct InterfaceStylePicker: View {
    @ObservedObject var model: Model
    var body: some View {
        Picker("Style", selection: Binding(get: { model.interfaceStyle }, set: model.setInterfaceStyle)) {
            ForEach(AuralInterfaceStyle.allCases, id: \.self) { style in
                Text(style.label).tag(style)
                    .disabled(style == .liquidGlass && !AuralInterfaceStyle.liquidGlassSupported)
            }
        }.help("Liquid Glass uses Apple's native material on macOS 26 or later. Theme controls light and dark appearance separately.")
    }
}
