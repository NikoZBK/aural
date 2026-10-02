import SwiftUI

@main struct AuralApp: App {
    @NSApplicationDelegateAdaptor(AuralAppDelegate.self) private var delegate
    private var model: Model { delegate.model }
    var body: some Scene {
        Window("Aural", id: "main") { MainView(model: model, icon: delegate.icon).background(WindowRegistration()) }
            .defaultSize(width: 1240, height: 820)
            .windowResizability(.contentMinSize)
            .commands { AuralCommands(model: model) }
        Window("Preset library", id: "presets") { PresetLibraryView(model: model).background(WindowRegistration()) }
            .defaultSize(width: 800, height: 580)
            .windowResizability(.contentMinSize)
        Window("About Aural", id: "about") { AboutView(icon: delegate.icon).background(WindowRegistration()) }
            .windowResizability(.contentSize)
        Window("Software updates", id: "updates") { UpdatesView().background(WindowRegistration()) }
            .windowResizability(.contentSize)
        MenuBarExtra("Aural", systemImage: "headphones") { MenuBarControls(model: model) }
    }
}

@MainActor final class AuralAppDelegate: NSObject, NSApplicationDelegate {
    let model: Model
    let icon: AppIconController

    override init() {
        let model = Model()
        self.model = model
        icon = AppIconController(running: model.$running.eraseToAnyPublisher(), bypass: model.$bypass.eraseToAnyPublisher()) { [weak model] message in
            model?.error = message
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) { icon.startUpdatingApplicationIcon() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}

struct AuralCommands: Commands {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Equalizer") {
            Button(model.undoLabel) { model.undoProfile() }.disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: [.command, .option])
            Button(model.redoLabel) { model.redoProfile() }.disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .option, .shift])
            Divider()
            Button("Compare A") { model.selectComparison(.a) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Compare B") { model.selectComparison(.b) }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Bypass EQ") { model.setBypass(!model.bypass) }.keyboardShortcut("b", modifiers: [.command, .option])
            Divider()
            Button("Copy EQ") { model.copyEQ() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Paste EQ") { model.pasteEQ() }.keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Import AutoEQ…") { model.importAutoEQ() }
            Button("Export EQ…") { model.exportEQ() }
            Divider()
            Button("Preset library…") { openWindow.showAuralWindow("presets") }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appInfo) {
            Button("About Aural") { openWindow.showAuralWindow("about") }
            Button("Check for Updates…") { openWindow.showAuralWindow("updates") }
        }
    }
}

struct MenuBarControls: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(model.running ? "Stop equalization" : "Start equalization") { model.running ? model.stop() : model.start() }
        Toggle("Bypass EQ", isOn: Binding(get: { model.bypass }, set: model.setBypass))
        Menu("Preset: \(model.currentPresetTitle)") { PresetMenuItems(model: model) }
        Button("Preset library…") { openWindow.showAuralWindow("presets") }
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
        Divider()
        Button("Show Aural") { openWindow.showAuralWindow("main") }
        Button("About Aural") { openWindow.showAuralWindow("about") }
        Button("Check for Updates…") { openWindow.showAuralWindow("updates") }
        Button("Quit Aural") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct StartupSettings: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Startup").font(.headline)
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLoginRequested }, set: model.setLaunchAtLogin))
            Toggle("Start EQ automatically", isOn: Binding(get: { model.startEQAutomatically }, set: model.setStartAutomatically))
            Text("Use the saved output and profile on launch. Wait up to 60 seconds if the device is disconnected. Stop pauses EQ for this session.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.loginStatus == .requiresApproval {
                Text("macOS approval is needed to launch at login.").font(.caption).foregroundStyle(.orange)
                Button("Open Login Items settings") { model.openLoginSettings() }
            }
            Divider()
            Button("About Aural") { openWindow.showAuralWindow("about") }
            Button("Check for Updates…") { openWindow.showAuralWindow("updates") }
        }.padding(18).frame(width: 300).onAppear { model.refreshLoginStatus() }
    }
}
