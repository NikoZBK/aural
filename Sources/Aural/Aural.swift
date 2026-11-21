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
        Window("App mixer", id: "apps") {
            AppMixerWindow(model: model).background(WindowRegistration())
        }.defaultSize(width: 720, height: 560).windowResizability(.contentMinSize)
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
        #if DEBUG
        let previewSettings = Bundle.main.bundleIdentifier == "local.aural.integration-preview"
            ? (Bundle.main.object(forInfoDictionaryKey: "AuralPreviewSettings") as? String).map { URL(fileURLWithPath: $0) } : nil
        let model = Model(settingsFile: previewSettings)
        #else
        let model = Model()
        #endif
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
        if Bundle.main.bundleIdentifier == "local.aural.equalizer" { UpdateChecker.shared.start() }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) { model.refreshLoginStatus() }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor [model] in
            // Quit, logout and update relaunch must never be refused: an edit that
            // could not be saved was already reported when it was made.
            do { try await model.appMixer.flush() }
            catch { AuralLog.lifecycle.error("App levels were not saved before quitting: \(AuralLog.describe(error), privacy: .public)") }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct AuralCommands: Commands {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.precisionSubmissions) private var submissions
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Equalizer") {
            Group {
                Button(model.undoLabel) { if submitPendingInput() { withAuralAnimation { model.undoProfile() } } }.disabled(!model.canUndo).help("\(model.undoLabel) (⌘Z)")
                    .keyboardShortcut("z", modifiers: [.command])
                Button(model.redoLabel) { if submitPendingInput() { withAuralAnimation { model.redoProfile() } } }.disabled(!model.canRedo).help("\(model.redoLabel) (⇧⌘Z)")
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Divider()
                Button("Compare A") { if submitPendingInput() { withAuralAnimation { model.selectComparison(.a) } } }.keyboardShortcut("1", modifiers: [.command, .option]).help("Switch to comparison A and keep the edits in both slots (⌥⌘1).")
                Button("Compare B") { if submitPendingInput() { withAuralAnimation { model.selectComparison(.b) } } }.keyboardShortcut("2", modifiers: [.command, .option]).help("Switch to comparison B and keep the edits in both slots (⌥⌘2).")
                Divider()
            }
            Button("Bypass EQ") { withAuralAnimation { model.setBypass(!model.bypass) } }.keyboardShortcut("b", modifiers: [.command, .option]).help(AuralHelp.bypass)
            Button("End solo") { withAuralAnimation { model.setSolo(nil) } }.disabled(model.soloBand == nil).help("Play the whole EQ again.")
            Toggle("Match levels", isOn: Binding(get: { model.matchLevels }, set: model.setMatchLevels)).help(AuralHelp.matchLevels)
            Toggle("Peak protection", isOn: Binding(get: { model.peakProtectionEnabled }, set: model.setPeakProtection)).help(AuralHelp.peakProtection)
            Toggle("Loudness compensation", isOn: Binding(get: { model.loudness.enabled }, set: model.setLoudnessEnabled)).help(AuralHelp.loudness)
            Toggle("Follow macOS output", isOn: Binding(get: { model.followSystemOutput }, set: model.setFollowSystemOutput)).help(AuralHelp.followOutput)
            Divider()
            Group {
                Button("Copy EQ") { if submitPendingInput() { model.copyEQ() } }.keyboardShortcut("c", modifiers: [.command, .shift]).help(AuralHelp.copyEQ)
            }
            Button("Paste EQ") { if submitPendingInput() { withAuralAnimation { model.pasteEQ() } } }.keyboardShortcut("v", modifiers: [.command, .shift]).help(AuralHelp.pasteEQ)
            Button("Search AutoEQ profiles…") { if submitPendingInput() { openWindow.showAuralWindow("autoeq") } }.help(AuralHelp.autoEQ)
            Button("Import AutoEQ…") { if submitPendingInput() { model.importAutoEQ() } }.help("Choose an Equalizer APO text file or paste AutoEQ text to import.")
            Group { Button("Export EQ…") { if submitPendingInput() { model.exportEQ() } }.help(AuralHelp.exportEQ) }
            Divider()
            Button("Preset library…") { openWindow.showAuralWindow("presets") }.help(AuralHelp.presetLibrary)
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("App mixer…") { if submitPendingInput() { openWindow.showAuralWindow("apps") } }.help(AuralHelp.appMixer)
                .keyboardShortcut("m", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appInfo) {
            Button("About Aural") { openWindow.showAuralWindow("about") }.help(AuralHelp.about)
            Button("Check for Updates…") { openWindow.showAuralWindow("updates") }.help(AuralHelp.updates)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard shortcuts…") { openWindow.showAuralWindow("shortcuts") }.help(AuralHelp.shortcuts)
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { model.zoomIn() }.keyboardShortcut("+", modifiers: .command).help("Increase interface text and control sizes (⌘+).")
                .disabled(model.interfaceZoom == .largest)
            Button("Zoom Out") { model.zoomOut() }.keyboardShortcut("-", modifiers: .command).help("Decrease interface text and control sizes (⌘−).")
                .disabled(model.interfaceZoom == .smallest)
            Button("Actual Size") { model.resetZoom() }.keyboardShortcut("0", modifiers: .command).help("Restore the interface to 100 percent (⌘0).")
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
        Button(model.running || model.waitingForOutput || model.starting ? "Stop EQ" : "Start EQ") { model.toggleProcessing() }.help(AuralHelp.processing(model.running || model.waitingForOutput || model.starting))
        Button("App mixer…") { openWindow.showAuralWindow("apps") }.help(AuralHelp.appMixer)
        Toggle("Follow macOS output", isOn: Binding(get: { model.followSystemOutput }, set: model.setFollowSystemOutput)).help(AuralHelp.followOutput)
        Toggle("Bypass EQ", isOn: Binding(get: { model.bypass }, set: model.setBypass)).help(AuralHelp.bypass)
        if let band = model.soloBand { Button("End solo of band \(band + 1)") { model.setSolo(nil) }.help("Play the whole EQ again.") }
        Toggle("Match levels", isOn: Binding(get: { model.matchLevels }, set: model.setMatchLevels)).help(AuralHelp.matchLevels)
        Toggle("Peak protection", isOn: Binding(get: { model.peakProtectionEnabled }, set: model.setPeakProtection)).help(AuralHelp.peakProtection)
        Toggle("Loudness compensation", isOn: Binding(get: { model.loudness.enabled }, set: model.setLoudnessEnabled)).help(AuralHelp.loudness)
        Menu("Preset: \(model.currentPresetTitle)") { PresetMenuItems(model: model) }.help("Choose a preset to apply, or delete a saved custom preset.")
        Button("Preset library…") { openWindow.showAuralWindow("presets") }.help(AuralHelp.presetLibrary)
        Button("Search AutoEQ profiles…") { openWindow.showAuralWindow("autoeq") }.help(AuralHelp.autoEQ)
        Group {
            Menu("Preamp: \(model.profile.preamp, specifier: "%.2f") dB") {
                Button("Increase 1 dB") { model.adjustPreamp(1) }.help("Raise preamp by 1 dB.")
                    .disabled(model.profile.preamp >= model.profile.preampRange.upperBound)
                Button("Decrease 1 dB") { model.adjustPreamp(-1) }.help("Lower preamp by 1 dB.")
                    .disabled(model.profile.preamp <= model.profile.preampRange.lowerBound)
            }.help(AuralHelp.preamp)
            Menu("Tilt: \(model.profile.tilt, specifier: "%+.1f") dB") {
                Button("Brighter 0.5 dB") { model.adjustTilt(0.5) }.help("Raise tilt by 0.5 dB to brighten the sound.")
                    .disabled(model.profile.tilt >= Profile.tiltRange.upperBound)
                Button("Darker 0.5 dB") { model.adjustTilt(-0.5) }.help("Lower tilt by 0.5 dB to darken the sound.")
                    .disabled(model.profile.tilt <= Profile.tiltRange.lowerBound)
                Button("No tilt") { model.setTilt(0) }.disabled(model.profile.tilt == 0).help("Reset tilt to 0 dB.")
            }.help(AuralHelp.tilt)
            Menu("Compare: \(model.comparisonSlot.rawValue.uppercased())") {
                Button("A") { withAuralAnimation { model.selectComparison(.a) } }.help("Switch to comparison A and keep the edits in both slots.")
                Button("B") { withAuralAnimation { model.selectComparison(.b) } }.help("Switch to comparison B and keep the edits in both slots.")
                Button("Copy current to other slot") { withAuralAnimation { model.copyComparisonToOther() } }.help("Replace the other A/B slot with the current EQ.")
            }.help("Switch between two versions of your EQ or copy the current EQ to the other comparison slot.")
        }
        Divider()
        ThemePicker(model: model)
        Button("Show Aural") { openWindow.showAuralWindow("main") }.help("Open the main Aural window.")
        Button("Keyboard shortcuts…") { openWindow.showAuralWindow("shortcuts") }.help(AuralHelp.shortcuts)
        Button("About Aural") { openWindow.showAuralWindow("about") }.help(AuralHelp.about)
        Button("Check for Updates…") { openWindow.showAuralWindow("updates") }.help(AuralHelp.updates)
        Button("Quit Aural") { NSApp.terminate(nil) }.keyboardShortcut("q").help("Stop audio processing and quit Aural (⌘Q).")
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
        }.help(AuralHelp.panelPosition)
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
            Toggle("Follow macOS output", isOn: Binding(get: { model.followSystemOutput }, set: model.setFollowSystemOutput)).help(AuralHelp.followOutput)
            Text("When macOS switches its sound output, Aural switches too and loads that output's saved EQ. EQ stays on if it was running.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Startup").font(.headline)
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLoginRequested }, set: model.setLaunchAtLogin))
                .disabled(model.loginStatus == nil)
                .help("Open Aural when you log in to your Mac. macOS may ask you to approve it in Login Items.")
            if model.loginStatus == nil {
                Text("Checking launch-at-login status…").font(.caption).foregroundStyle(.secondary).transition(.opacity)
            }
            Toggle("Start EQ automatically", isOn: Binding(get: { model.startEQAutomatically }, set: model.setStartAutomatically))
                .help("Start EQ with the saved output and preset when Aural launches. Wait up to 60 seconds for a disconnected output.")
            Text("Use the saved output and preset on launch. Wait up to 60 seconds if the device is disconnected. Stop pauses EQ for this session.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.loginStatus == .requiresApproval {
                Group {
                    Text("macOS approval is needed to launch at login.").font(.caption).foregroundStyle(AuralStyle.warning)
                    Button("Open Login Items settings") { model.openLoginSettings() }.help("Open macOS Login Items settings to approve launching Aural at login.")
                }.transition(.opacity)
            }
            Divider()
            if let error = model.error { AuralNotice(message: error, isError: true).transition(.opacity) }
            Button { openWindow.showAuralWindow("about") } label: {
                Text("About Aural").auralFrame(maxWidth: .infinity)
            }.buttonStyle(AuralButtonStyle()).help(AuralHelp.about)
            Button { openWindow.showAuralWindow("updates") } label: {
                Text("Check for Updates…").auralFrame(maxWidth: .infinity)
            }.buttonStyle(AuralButtonStyle()).help(AuralHelp.updates)
        }
        .auralAnimation(AuralMotion.quick, value: StartupMotion(status: model.loginStatus?.rawValue, error: model.error))
        .auralPadding(18).auralFrame(width: 300).auralAppearance(model.theme).onAppear { model.refreshLoginStatus() }
    }
}

private struct StartupMotion: Equatable { let status: Int?; let error: String? }

struct LoudnessReference: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    var body: some View {
        HStack(spacing: 8 * interfaceScale) {
            Text("Reference level").fixedSize().accessibilityHidden(true)
                .help("How loud music is at the reference volume. 80 phon suits a comfortable, full listening level.")
            AuralPicker(title: "Reference level", value: "\(Int(model.loudness.referenceLevel)) phon",
                        selection: Binding(get: { model.loudness.referenceLevel }, set: model.setLoudnessReferenceLevel)) {
                ForEach(Loudness.referenceLevels, id: \.self) { level in Text("\(Int(level)) phon").tag(level) }
            }.help("Choose how loud music is at the reference volume. 80 phon suits a comfortable, full listening level.")
        }
        Button { model.setLoudnessReference() } label: {
            Text("Use current volume as reference").auralFrame(maxWidth: .infinity)
        }.buttonStyle(AuralButtonStyle())
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
