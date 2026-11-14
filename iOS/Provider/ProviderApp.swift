import SwiftUI

@main
struct AuralRouteApp: App {
    @Environment(\.openURL) private var openURL
    @State private var openFailed = false
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 52, weight: .light)).foregroundStyle(.cyan)
                    Text("Aural’s connection\nis ready.").font(.largeTitle.bold())
                    Text("Keep this companion installed to make Aural available in Control Center’s audio-output picker. Your EQ, presets, and listening controls live in the main Aural app.").foregroundStyle(.secondary)
                    Button("Open Aural", systemImage: "arrow.up.right") {
                        openURL(URL(string: "aural://equalizer")!) { accepted in openFailed = !accepted }
                    }.buttonStyle(.glassProminent).controlSize(.large)
                    Spacer()
                    Text("Start EQ in Aural, play music, then select Aural in Control Center. You can switch back and reconnect without pausing your music.").font(.footnote).foregroundStyle(.secondary)
                }.padding(28).frame(maxWidth: 560).frame(maxWidth: .infinity)
                    .background { LinearGradient(colors: [.cyan.opacity(0.10), .clear, .indigo.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea() }
                    .navigationTitle("Aural Route").navigationBarTitleDisplayMode(.inline)
                    .alert("Aural could not be opened", isPresented: $openFailed) { Button("OK", role: .cancel) {} } message: { Text("Install the main Aural app alongside this companion, then open it from your Home Screen.") }
            }
        }
    }
}
