import SwiftUI
import Combine

// This fixture uses disposable settings and never starts audio automatically.
// Only the separately signed preview bundle selects this entry point.
struct PerformancePreview: App {
    @NSApplicationDelegateAdaptor(PreviewDelegate.self) private var delegate
    private var minimumFixture: Bool { Bundle.main.bundleIdentifier == "local.aural.performance-preview.zoom-minimum" }
    var body: some Scene {
        Window("Aural performance preview", id: "main") {
            if Bundle.main.bundleIdentifier == "local.aural.performance-preview.accent" {
                NativeAccentPreview()
            } else {
                MainView(model: delegate.model, icon: delegate.icon)
                    .frame(width: minimumFixture ? 900 : nil, height: minimumFixture ? 620 : nil)
            }
        }.defaultSize(width: minimumFixture ? 900 : 1040, height: minimumFixture ? 620 : 690).windowResizability(.contentMinSize)
            .commands { AuralCommands(model: delegate.model) }
        Window("Preset library", id: "presets") { PresetLibraryView(model: delegate.model).auralZoom(delegate.model) }
        Window("AutoEQ profiles", id: "autoeq") { AutoEQBrowserView(model: delegate.model).auralZoom(delegate.model) }
            .defaultSize(width: 780, height: 620).windowResizability(.contentMinSize)
        Window("About Aural", id: "about") { AboutView(model: delegate.model, icon: delegate.icon).auralZoom(delegate.model) }
        Window("Software updates", id: "updates") { UpdatesView(model: delegate.model).auralZoom(delegate.model) }
        Window("Keyboard shortcuts", id: "shortcuts") {
            KeyboardShortcutsView(model: delegate.model).auralZoom(delegate.model)
        }.defaultSize(width: 540, height: 600).windowResizability(.contentMinSize)
    }
}
@MainActor final class PreviewDelegate: NSObject, NSApplicationDelegate {
    let model: Model
    let icon: AppIconController
    private var theme: AnyCancellable?
    override init() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-performance-preview-data", isDirectory: true)
        let model = Model(settingsFile: directory.appendingPathComponent("settings.json"), readLoginStatus: { .notRegistered })
        model.setInterfaceMode(.easy)
        self.model = model
        icon = AppIconController(running: model.$running.eraseToAnyPublisher(), bypass: model.$bypass.eraseToAnyPublisher(), reportError: { [weak model] in model?.error = $0 })
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        theme = model.$theme.sink { NSApp.appearance = $0.appearance }
    }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}
