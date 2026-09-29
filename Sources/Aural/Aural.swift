import SwiftUI

@main struct AuralApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        Window("Aural", id: "main") { MainView(model: model) }
            .defaultSize(width: 1040, height: 920)
            .windowResizability(.contentMinSize)
            .commands { AuralCommands(model: model) }
        Window("Preset library", id: "presets") { PresetLibraryView(model: model) }
            .defaultSize(width: 800, height: 580)
            .windowResizability(.contentMinSize)
        Window("About Aural", id: "about") { AboutView() }
            .windowResizability(.contentSize)
        Window("Software updates", id: "updates") { UpdatesView() }
            .windowResizability(.contentSize)
        MenuBarExtra("Aural", systemImage: "headphones") { MenuBarControls(model: model) }
    }
}

struct AuralCommands: Commands {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Equalizer") {
            Button("Copy EQ") { model.copyEQ() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Paste EQ") { model.pasteEQ() }.keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Import AutoEQ…") { model.importAutoEQ() }
            Button("Export EQ…") { model.exportEQ() }
            Divider()
            Button("Preset library…") { openWindow(id: "presets") }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appInfo) {
            Button("About Aural") { openWindow(id: "about"); NSApp.activate(ignoringOtherApps: true) }
            Button("Check for Updates…") { openWindow(id: "updates"); NSApp.activate(ignoringOtherApps: true) }
        }
    }
}

struct MenuBarControls: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(model.running ? "Stop equalization" : "Start equalization") { model.running ? model.stop() : model.start() }
        Toggle("Bypass EQ", isOn: $model.bypass).onChange(of: model.bypass) { model.change() }
        Menu("Preset: \(model.currentPresetTitle)") { PresetMenuItems(model: model) }
        Button("Preset library…") { openWindow(id: "presets"); NSApp.activate(ignoringOtherApps: true) }
        Menu("Preamp: \(model.profile.preamp, specifier: "%.2f") dB") {
            Button("Increase 1 dB") { model.adjustPreamp(1) }
                .disabled(model.profile.preamp >= model.profile.preampRange.upperBound)
            Button("Decrease 1 dB") { model.adjustPreamp(-1) }
                .disabled(model.profile.preamp <= model.profile.preampRange.lowerBound)
        }
        Divider()
        Button("Show Aural") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("About Aural") { openWindow(id: "about"); NSApp.activate(ignoringOtherApps: true) }
        Button("Check for Updates…") { openWindow(id: "updates"); NSApp.activate(ignoringOtherApps: true) }
        Button("Quit Aural") { model.stop(); NSApp.terminate(nil) }.keyboardShortcut("q")
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
            Button("About Aural") { openWindow(id: "about") }
            Button("Check for Updates…") { openWindow(id: "updates") }
        }.padding(18).frame(width: 300).onAppear { model.refreshLoginStatus() }
    }
}
