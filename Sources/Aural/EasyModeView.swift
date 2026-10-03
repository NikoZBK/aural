import SwiftUI

struct EasyModeView: View {
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                currentPreset
                Spacer(minLength: 12)
                Button { if submitPendingInput() { model.undoProfile() } } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(AuralButtonStyle()).disabled(!model.canUndo).help(model.undoLabel)
                Button { if submitPendingInput() { model.redoProfile() } } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .buttonStyle(AuralButtonStyle()).disabled(!model.canRedo).help(model.redoLabel)
            }
            SessionNotices(model: model)
            GeometryReader { geometry in
                HSplitView {
                    PresetBrowser(model: model, comfortable: true)
                        .auralPanel(padding: 20)
                        .frame(minWidth: 260, idealWidth: min(360, max(260, geometry.size.width * 0.26)), maxWidth: .infinity, maxHeight: .infinity)
                    GeometryReader { controls in
                        let columns = Array(repeating: GridItem(.flexible(), alignment: .top), count: controls.size.width >= 700 ? 2 : 1)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                equalizer
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                                    OutputSelection(model: model, submissions: submissions, comfortable: true)
                                        .frame(maxWidth: .infinity, alignment: .leading).auralPanel(padding: 20)
                                    PreampControls(model: model, submissions: submissions)
                                        .frame(maxWidth: .infinity, alignment: .leading).auralPanel(padding: 20)
                                    SimpleListeningControls(model: model, submissions: submissions)
                                        .frame(maxWidth: .infinity, alignment: .leading).auralPanel(padding: 20)
                                    VStack(alignment: .leading, spacing: 18) {
                                        StudioMeter(meter: model.meter, running: model.running)
                                        Divider().overlay(AuralStyle.border)
                                        Text(model.running ? "Listening on \(model.selected?.name ?? "the selected output")." : "Start EQ to hear your adjustments and see the output level.")
                                            .font(.system(size: 13)).foregroundStyle(AuralStyle.secondary).fixedSize(horizontal: false, vertical: true)
                                        HStack(alignment: .top, spacing: 10) {
                                            Image(systemName: "gearshape").accessibilityHidden(true)
                                            Text("Use Settings above to start EQ automatically or open Aural when you log in.")
                                                .fixedSize(horizontal: false, vertical: true)
                                        }.font(.system(size: 12)).foregroundStyle(AuralStyle.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).auralPanel(padding: 20)
                                }
                            }.padding(.bottom, 4)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).scrollIndicators(.visible)
                    }.padding(.leading, 12)
                        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDisappear { model.endProfileGesture() }
    }

    private var equalizer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AuralSectionLabel(title: "Equalizer · \(model.profile.filters?.count ?? model.profile.gains.count) bands", systemImage: "slider.vertical.3")
                Spacer()
                Button("Reset EQ") { if submitPendingInput() { model.resetEQ() } }
                    .buttonStyle(AuralButtonStyle()).help("Set band gains and preamp to 0 dB. Keep frequencies, Q, filter types, channels, and stereo settings.")
            }
            EQBars(model: model, submissions: submissions).frame(height: model.profile.filters == nil ? 184 : 210)
        }.auralPanel(padding: 20)
    }

    private var currentPreset: some View {
        VStack(alignment: .leading, spacing: 8) {
            AuralSectionLabel(title: "Current preset")
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.selectedPresetName ?? "Custom EQ")
                    .font(.system(size: 28, weight: .semibold)).lineLimit(2)
                if model.isPresetModified {
                    Text("Customized").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AuralStyle.warning)
                }
            }.accessibilityElement(children: .ignore)
                .accessibilityLabel("Current preset: \(model.currentPresetTitle)")
            Text("Choose a preset, start EQ, and enjoy your music.")
                .font(.system(size: 14)).foregroundStyle(AuralStyle.secondary)
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
