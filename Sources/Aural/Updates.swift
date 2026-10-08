import SwiftUI
import Sparkle

/// One updater for the entire app, including its menu-bar-only lifetime.
@MainActor final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let releasesURL = URL(string: "https://github.com/NikoZBK/aural/releases")!
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var error: String?
    private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    private var started = false
    let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"

    private init() {
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
    }

    func start() {
        guard !started else { return }
        do {
            try controller.updater.start()
            started = true
            error = nil
        } catch {
            self.error = "Could not start software updates: \(error.localizedDescription)"
        }
    }

    func check() {
        start()
        guard started else { return } // start() surfaces the configuration error.
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloads(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
    }
}

struct UpdatesView: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    @ObservedObject private var checker = UpdateChecker.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14 * interfaceScale) {
            Text("Software updates").font(.title2.weight(.semibold))
            Text("Installed: Aural \(checker.installed)").foregroundStyle(.secondary)
            Text("Aural downloads and verifies updates, then installs them and relaunches. Your saved settings and presets are preserved.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Automatically check for updates", isOn: Binding(get: { checker.automaticallyChecks }, set: checker.setAutomaticallyChecks))
            Toggle("Automatically download updates", isOn: Binding(get: { checker.automaticallyDownloads }, set: checker.setAutomaticallyDownloads))
                .disabled(!checker.automaticallyChecks)
            Text("Installing an update briefly stops EQ while Aural restarts. Start EQ automatically follows your startup setting.")
                .auralFont(size: 11).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = checker.error {
                Text(error).foregroundStyle(AuralStyle.warning).fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            HStack {
                Link("Releases page", destination: UpdateChecker.releasesURL)
                Spacer()
                Button("Check for Updates…") { checker.check() }
                    .disabled(!checker.canCheckForUpdates && checker.error == nil)
                    .buttonStyle(.borderedProminent)
            }
        }.auralAnimation(AuralMotion.quick, value: checker.error)
            .auralFont(size: 12).auralPadding(22).auralFrame(width: 530)
            .auralAppearance(model.theme)
            .auralAnnouncement(checker.error ?? "")
            .task { checker.check() }
    }
}
