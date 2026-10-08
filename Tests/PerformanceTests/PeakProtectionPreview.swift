import SwiftUI

// Deterministic native checks of the actual meter in all protection states.
// Readings are invented; this separately signed fixture never routes audio.
struct PeakProtectionPreview: View {
    @State private var theme: AuralTheme = .dark
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Peak protection").font(.title2)
            HStack(alignment: .top, spacing: 24) {
                sample("Stopped", running: false, peak: 0, reductionDB: 0)
                sample("Active", running: true, peak: 0.5, reductionDB: 0)
            }
            HStack(alignment: .top, spacing: 24) {
                sample("Reducing", running: true, peak: 0.98, reductionDB: 6.2)
                sample("Off", running: true, peak: 1.2, reductionDB: 6.2, enabled: false)
            }
            Button("Switch light / dark") { theme = theme == .dark ? .light : .dark }
        }.padding(24).auralAppearance(theme)
    }
    private func sample(_ title: String, running: Bool, peak: Float, reductionDB: Float, enabled: Bool = true) -> some View {
        PeakProtectionSample(title: title, running: running, peak: peak, reductionDB: reductionDB, protectionEnabled: enabled)
    }
}

private struct PeakProtectionSample: View {
    let title: String
    let running: Bool
    let peak: Float
    let reductionDB: Float
    @State var protectionEnabled: Bool
    @StateObject private var meter = AudioMeter()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.headline)
            StudioMeter(meter: meter, running: running, protectionEnabled: $protectionEnabled, compact: true)
            Divider()
            StudioMeter(meter: meter, running: running, protectionEnabled: $protectionEnabled)
        }.frame(width: 260).onAppear { meter.update(peak, reductionDB: reductionDB) }
    }
}
