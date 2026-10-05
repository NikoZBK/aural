import SwiftUI

struct StereoPanel: View {
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    private var settings: StereoSettings { model.profile.stereoSettings }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    AuralSectionLabel(title: "Stereo controls", systemImage: "arrow.left.and.right")
                    Spacer()
                    Button("Reset stereo") { if submitPendingInput() { model.resetStereoSettings() } }.buttonStyle(AuralButtonStyle())
                        .help("Restore neutral stereo settings, leaving EQ unchanged")
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 14) {
                        AuralSectionLabel(title: "Stereo balance")
                        control("Balance", value: settings.balance, range: -1...1, suffix: "", keyPath: \.balance, spokenValue: AuralAccessibility.balance(settings.balance), decimals: 2)
                        HStack { Text("Left"); Spacer(); Text("Center"); Spacer(); Text("Right") }
                            .auralFont(size: 9).foregroundStyle(AuralStyle.secondary)
                        control("Width", value: settings.width, range: 0...2, suffix: "×", keyPath: \.width, spokenValue: AuralAccessibility.percentage(settings.width), decimals: 2)
                            .disabled(settings.mono)
                        Toggle("Mono", isOn: flag(\.mono)).toggleStyle(.checkbox).auralFont(size: 12)
                            .help("Sum left and right to mono before channel trims, polarity, and delay.")
                        control("Crossfeed", value: settings.crossfeed, range: 0...1, suffix: "", keyPath: \.crossfeed, spokenValue: AuralAccessibility.percentage(settings.crossfeed), decimals: 2)
                        Text("Crossfeed blends low frequencies from the opposite channel for headphone listening.")
                            .auralFont(size: 10).foregroundStyle(AuralStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    }.auralFrame(maxWidth: .infinity).auralPanel(padding: 14)
                        .accessibilityElement(children: .contain).accessibilityLabel("Stereo balance, width, and crossfeed")
                    VStack(alignment: .leading, spacing: 14) {
                        AuralSectionLabel(title: "Left & right")
                        control("Left trim", value: settings.leftTrimDB, range: -24...12, suffix: "dB", keyPath: \.leftTrimDB, spokenValue: AuralAccessibility.decibels(settings.leftTrimDB))
                        control("Right trim", value: settings.rightTrimDB, range: -24...12, suffix: "dB", keyPath: \.rightTrimDB, spokenValue: AuralAccessibility.decibels(settings.rightTrimDB))
                        Divider().overlay(AuralStyle.border)
                        delay("Left delay", value: settings.leftDelayMS, keyPath: \.leftDelayMS)
                        delay("Right delay", value: settings.rightDelayMS, keyPath: \.rightDelayMS)
                        Toggle("Invert left polarity", isOn: flag(\.invertLeft)).toggleStyle(.checkbox)
                        Toggle("Invert right polarity", isOn: flag(\.invertRight)).toggleStyle(.checkbox)
                        Text("Delay adds 0–30 ms to the selected channel. The curve shows EQ and preamp only.")
                            .auralFont(size: 10).foregroundStyle(AuralStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    }.auralFont(size: 12).auralFrame(maxWidth: .infinity).auralPanel(padding: 14)
                        .accessibilityElement(children: .contain).accessibilityLabel("Channel trim, delay, and polarity")
                }
            }.padding(.bottom, 8)
        }.scrollIndicators(.visible).onDisappear { model.endProfileGesture() }
    }
    private func flag(_ keyPath: WritableKeyPath<StereoSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in
            guard submitPendingInput() else { return }
            model.endProfileGesture()
            var next = settings; next[keyPath: keyPath] = value; model.setStereoSettings(next)
        })
    }
    private func numeric(_ keyPath: WritableKeyPath<StereoSettings, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in
            guard submitPendingInput() else { return }
            var next = settings; next[keyPath: keyPath] = value; model.setStereoSettings(next)
        })
    }
    private func control(_ title: String, value: Double, range: ClosedRange<Double>, suffix: String,
                         keyPath: WritableKeyPath<StereoSettings, Double>, spokenValue: String, decimals: Int = 1) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(title).auralFont(size: 11, weight: .medium).auralFrame(maxWidth: .infinity, alignment: .leading)
                PrecisionField(value: value, range: range, label: suffix == "dB" ? "\(title) in decibels" : suffix == "×" ? "\(title) multiplier" : title, decimals: decimals, revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model, keyPath] number in
                    model.endProfileGesture()
                    var next = model.profile.stereoSettings; next[keyPath: keyPath] = number; model.setStereoSettings(next)
                }.auralFrame(width: 58)
                if !suffix.isEmpty { Text(suffix).auralFont(size: 9).foregroundStyle(AuralStyle.secondary) }
            }
            Slider(value: numeric(keyPath), in: range,
                   onEditingChanged: { active in active ? model.beginProfileGesture(label: title) : model.endProfileGesture() })
                .accessibilityLabel(title).accessibilityValue(spokenValue)
        }
    }
    private func delay(_ title: String, value: Double, keyPath: WritableKeyPath<StereoSettings, Double>) -> some View {
        HStack {
            Text(title).auralFont(size: 11).auralFrame(maxWidth: .infinity, alignment: .leading)
            PrecisionField(value: value, range: 0...30, label: "\(title) in milliseconds", revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model, keyPath] number in
                model.endProfileGesture()
                var next = model.profile.stereoSettings; next[keyPath: keyPath] = number; model.setStereoSettings(next)
            }.auralFrame(width: 68)
            Text("ms").auralFont(size: 10).foregroundStyle(AuralStyle.secondary)
        }
    }
    private func submitPendingInput() -> Bool {
        switch submissions.submitActive() {
        case .rejected: return false
        case .submitted: return model.error == nil
        case .unchanged: return true
        }
    }
}
