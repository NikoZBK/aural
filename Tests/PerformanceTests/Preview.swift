import SwiftUI
import Combine

// This fixture uses disposable settings and never starts audio automatically.
// Only the separately signed preview bundle selects this entry point.
struct PerformancePreview: App {
    @NSApplicationDelegateAdaptor(PreviewDelegate.self) private var delegate
    var body: some Scene {
        Window("Aural performance preview", id: "main") {
            MainView(model: delegate.model, icon: delegate.icon)
        }.defaultSize(width: 1040, height: 690).windowResizability(.contentMinSize)
            .commands { AuralCommands(model: delegate.model) }
        Window("Preset library", id: "presets") { PresetLibraryView(model: delegate.model) }
        Window("AutoEQ profiles", id: "autoeq") { AutoEQBrowserView(model: delegate.model) }
            .defaultSize(width: 780, height: 620).windowResizability(.contentMinSize)
        Window("About Aural", id: "about") { AboutView(model: delegate.model, icon: delegate.icon) }
        Window("Software updates", id: "updates") { UpdatesView(model: delegate.model) }
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
