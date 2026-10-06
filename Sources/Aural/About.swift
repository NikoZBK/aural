import SwiftUI

struct AboutView: View {
    @ObservedObject var model: Model
    @ObservedObject var icon: AppIconController
    @Environment(\.openWindow) private var openWindow
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let image = icon.image { Image(nsImage: image).resizable() }
                else { Image(systemName: "headphones").resizable().scaledToFit().padding(14) }
            }.auralFrame(width: 88, height: 88).accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Aural").auralFont(size: 27, weight: .semibold)
                Text("Version \(version) (\(build))").auralFont(size: 11).foregroundStyle(.secondary)
            }
            Text("Good company. Better sound.").auralFont(size: 13, weight: .medium).foregroundStyle(Color.primary)
            Text("A native equalizer for macOS, with device profiles, AutoEQ import, and audio processing that stays on your Mac.")
                .auralFont(size: 12).multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(spacing: 5) {
                Text("Created by Nikolay Ostroukhov").auralFont(size: 12, weight: .medium)
                Text("© 2026 Nikolay Ostroukhov · MIT License").auralFont(size: 10).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                Link("GitHub", destination: URL(string: "https://github.com/NikoZBK/aural")!)
                Link("Report an issue", destination: URL(string: "https://github.com/NikoZBK/aural/issues")!)
                Link("License", destination: URL(string: "https://github.com/NikoZBK/aural/blob/main/LICENSE")!)
            }.auralFont(size: 11)
            Text("macOS 14.2+ · Apple silicon & Intel\nBuilt with SwiftUI and Core Audio. Independent of Apple and AutoEQ.")
                .auralFont(size: 10).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("Check for Updates…") { openWindow.showAuralWindow("updates") }
            Text("Updates are verified before installation.").auralFont(size: 10).foregroundStyle(.secondary)
        }.padding(26).auralFrame(width: 380).auralAppearance(model.theme, style: model.interfaceStyle)
    }
}
