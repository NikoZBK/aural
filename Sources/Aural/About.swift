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
            }.frame(width: 88, height: 88).accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Aural").font(.system(size: 27, weight: .semibold))
                Text("Version \(version) (\(build))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Good company. Better sound.").font(.system(size: 13, weight: .medium)).foregroundStyle(AuralStyle.accent)
            Text("A native equalizer for macOS, with device profiles, AutoEQ import, and audio processing that stays on your Mac.")
                .font(.system(size: 12)).multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(spacing: 5) {
                Text("Created by Nikolay Ostroukhov").font(.system(size: 12, weight: .medium))
                Text("© 2026 Nikolay Ostroukhov · MIT License").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                Link("GitHub", destination: URL(string: "https://github.com/NikoZBK/aural")!)
                Link("Report an issue", destination: URL(string: "https://github.com/NikoZBK/aural/issues")!)
                Link("License", destination: URL(string: "https://github.com/NikoZBK/aural/blob/main/LICENSE")!)
            }.font(.system(size: 11))
            Text("macOS 14.2+ · Apple silicon & Intel\nBuilt with SwiftUI and Core Audio. Independent of Apple and AutoEQ.")
                .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("Check for Updates…") { openWindow.showAuralWindow("updates") }
            Text("This build is not notarized by Apple.").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(26).frame(width: 380).auralAppearance(model.theme)
    }
}
