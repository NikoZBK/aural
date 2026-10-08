import SwiftUI

// Run in the separately signed accent preview bundle. Native popup indicators
// must be checked in a live window using the production SDK compatibility mode;
// offscreen SwiftUI snapshots omit their AppKit drawing.
struct NativeAccentPreview: View {
    @State private var theme: AuralTheme = .dark
    @State private var output = "headphones"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Native dropdown accent check").font(.title2)
            VStack(alignment: .leading, spacing: 10) {
                Text("System reference").font(.headline)
                controls
            }.preferredColorScheme(theme.colorScheme)
            VStack(alignment: .leading, spacing: 10) {
                Text("Aural appearance").font(.headline)
                controls
            }.padding(12).auralAppearance(theme)
            Button("Switch light / dark") { theme = theme == .dark ? .light : .dark }
            Text("The Aural row uses its fixed cyan instrument color; the system row keeps the macOS accent. Popup arrows must never turn red, before or after switching appearance. This fixture never starts audio.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(width: 580, height: 340)
            .preferredColorScheme(theme.colorScheme)
    }

    private var controls: some View {
        HStack(spacing: 20) {
            Picker("Output", selection: $output) {
                Text("Headphones").tag("headphones")
                Text("Speakers").tag("speakers")
            }.labelsHidden().frame(width: 260)
            Menu("Peak") {
                Button("Peak") { }
                Button("Low shelf") { }
            }.frame(width: 180)
        }
    }
}
