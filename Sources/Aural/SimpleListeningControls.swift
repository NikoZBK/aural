import SwiftUI

struct SimpleListeningControls: View {
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    private var settings: StereoSettings { model.profile.stereoSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                AuralSectionLabel(title: "Listening", systemImage: "headphones")
                Spacer()
                Button("Reset") {
                    if submitPendingInput() {
                        model.endProfileGesture()
                        model.setStereoSettings(model.profile.stereoSettings.resettingListeningControls())
                    }
                }.buttonStyle(AuralButtonStyle()).accessibilityLabel("Reset listening controls").help("Reset balance, mono, width, and headphone blend")
            }
            VStack(spacing: 6) {
                HStack { Text("Balance"); Spacer(); Text(balanceLabel).foregroundStyle(AuralStyle.secondary) }
                Slider(value: number(\.balance), in: -1...1,
                       onEditingChanged: gesture("Balance"))
                    .accessibilityLabel("Stereo balance").accessibilityValue(AuralAccessibility.balance(settings.balance))
                HStack { Text("Left"); Spacer(); Text("Center"); Spacer(); Text("Right") }
                    .font(.caption).foregroundStyle(AuralStyle.secondary)
            }
            Toggle("Mono listening", isOn: Binding(get: { settings.mono }, set: { value in
                guard submitPendingInput() else { return }
                model.endProfileGesture()
                var next = model.profile.stereoSettings; next.mono = value; model.setStereoSettings(next)
            })).toggleStyle(.switch)
                .help("Play the same mix through both channels")
            VStack(spacing: 6) {
                HStack { Text("Stereo width"); Spacer(); Text(String(format: "%.0f%%", settings.width * 100)).monospacedDigit().foregroundStyle(AuralStyle.secondary) }
                Slider(value: number(\.width), in: 0...2, onEditingChanged: gesture("Stereo width"))
                    .accessibilityLabel("Stereo width").accessibilityValue(AuralAccessibility.percentage(settings.width)).disabled(settings.mono)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("Headphone blend"); Spacer(); Text(String(format: "%.0f%%", settings.crossfeed * 100)).monospacedDigit().foregroundStyle(AuralStyle.secondary) }
                Slider(value: number(\.crossfeed), in: 0...1, onEditingChanged: gesture("Headphone blend"))
                    .accessibilityLabel("Headphone crossfeed").accessibilityValue(AuralAccessibility.percentage(settings.crossfeed))
                Text("Blend a little of the opposite channel for headphone listening.")
                    .font(.caption).foregroundStyle(AuralStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.system(size: 13)).onDisappear { model.endProfileGesture() }
    }

    private var balanceLabel: String {
        settings.balance == 0 ? "Centered" : String(format: "%.0f%% %@", abs(settings.balance) * 100,
                                                    settings.balance < 0 ? "left" : "right")
    }
    private func number(_ keyPath: WritableKeyPath<StereoSettings, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in
            guard submitPendingInput() else { return }
            var next = model.profile.stereoSettings; next[keyPath: keyPath] = value; model.setStereoSettings(next)
        })
    }
    private func gesture(_ label: String) -> (Bool) -> Void {
        { active in active ? model.beginProfileGesture(label: label) : model.endProfileGesture() }
    }
    private func submitPendingInput() -> Bool {
        switch submissions.submitActive() {
        case .rejected: return false
        case .submitted: return model.error == nil
        case .unchanged: return true
        }
    }
}
