import SwiftUI

struct MainView: View {
    @ObservedObject var model: Model
    @ObservedObject var icon: AppIconController
    @State private var showStartup = false
    @State private var showFilterEditor = false
    @State private var page = StudioPage.equalizer
    @State private var selectionRevision = 0
    @StateObject private var submissions = PrecisionSubmissionCoordinator()

    private var status: String { model.running ? (model.bypass ? "Bypassed" : "Processing") : "Stopped" }
    private var statusColor: Color { model.running ? (model.bypass ? AuralStyle.warning : AuralStyle.accent) : AuralStyle.secondary }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AuralStyle.border)
            // The window's minimum size is explicit below. Keep its size negotiation
            // from repeatedly measuring every editor and scroll view during a mode swap.
            GeometryReader { viewport in
                InterfacePanelHost(mode: model.interfaceMode, simple: EasyModeView(model: model, submissions: submissions), professional: professionalPanel)
                    .frame(width: viewport.size.width, height: viewport.size.height)
            }
            Divider().overlay(AuralStyle.border)
            footer
        }
        .frame(minWidth: model.interfaceMode == .easy ? 900 : 1060, minHeight: model.interfaceMode == .easy ? 640 : 700)
        .auralAppearance(model.theme)
        .focusedSceneValue(\.precisionSubmissions, submissions)
        .sheet(isPresented: $showFilterEditor) { FilterEditor(model: model) }
    }

    private var professionalPanel: some View {
        HSplitView {
            StudioSidebar(model: model, submissions: submissions)
                .frame(minWidth: 184, idealWidth: 184, maxWidth: .infinity, maxHeight: .infinity)
            GeometryReader { geometry in
                workspace(graphHeight: min(246, max(160, geometry.size.height * 0.30)))
            }.frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
            MonitorPanel(model: model, submissions: submissions)
                .frame(minWidth: 218, idealWidth: 218, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let image = icon.image { Image(nsImage: image).resizable() }
                else { Image(systemName: "headphones").resizable().scaledToFit().padding(5) }
            }.frame(width: 35, height: 35).accessibilityHidden(true)
            Text("AURAL").font(.system(size: 18, weight: .bold)).tracking(2)
            Text("EQUALIZER").font(.system(size: 9, weight: .medium)).tracking(1.2)
                .foregroundStyle(AuralStyle.secondary).fixedSize()
            Picker("Interface mode", selection: Binding(get: { model.interfaceMode }, set: changeInterfaceMode)) {
                ForEach(InterfaceMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                .id(selectionRevision)
                .accessibilityLabel("Interface mode")
                .help("Simple shows everyday listening controls. Professional shows every control. Your current sound stays active in either mode.")
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(status).font(.system(size: 11, weight: .medium))
            }.foregroundStyle(statusColor).accessibilityElement(children: .ignore)
                .accessibilityLabel("Equalizer status: \(status)")
            Divider().frame(height: 22).padding(.horizontal, 4)
            Toggle("Bypass", isOn: Binding(get: { model.bypass }, set: model.setBypass)).toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 11))
                .help("Bypass EQ, preamp, and stereo effects. Routing and peak protection stay active.")
            Button { model.running ? model.stop() : model.start() } label: {
                Label(model.running ? "Stop EQ" : "Start EQ", systemImage: model.running ? "stop.fill" : "play.fill")
                    .frame(width: 80)
            }.buttonStyle(AuralButtonStyle(prominent: true)).disabled(model.selected == nil && !model.running)
            Button { showStartup.toggle() } label: { Image(systemName: "gearshape").frame(width: 15) }
                .buttonStyle(AuralButtonStyle()).accessibilityLabel("Settings").help("Appearance, startup, About, and updates")
                .popover(isPresented: $showStartup) { StartupSettings(model: model) }
        }.padding(.horizontal, 18).frame(height: 62)
    }

    private func workspace(graphHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    AuralSectionLabel(title: "Current preset")
                    HStack(spacing: 8) {
                        Text(model.selectedPresetName ?? "Custom EQ").font(.system(size: 20, weight: .semibold))
                            .lineLimit(1).help(model.currentPresetTitle)
                        if model.isPresetModified {
                            Text("EDITED").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                                .foregroundStyle(AuralStyle.warning).padding(.horizontal, 6).padding(.vertical, 3)
                                .background(AuralStyle.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }.accessibilityElement(children: .ignore).accessibilityLabel("Current preset: \(model.currentPresetTitle)")
                }
                Spacer(minLength: 4)
                Button { model.undoProfile() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(AuralButtonStyle()).disabled(!model.canUndo).help(model.undoLabel).accessibilityLabel(model.undoLabel)
                Button { model.redoProfile() } label: { Image(systemName: "arrow.uturn.forward") }
                    .buttonStyle(AuralButtonStyle()).disabled(!model.canRedo).help(model.redoLabel).accessibilityLabel(model.redoLabel)
                Menu {
                    Button("Edit as a draft…") { if submitPendingInput() { showFilterEditor = true } }
                    Divider()
                    Button("Copy EQ") { if submitPendingInput() { model.copyEQ() } }
                    Button("Export EQ…") { if submitPendingInput() { model.exportEQ() } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                    .accessibilityLabel("EQ options")
            }
            notices
            ResponseCurve(profile: model.profile, rate: model.responseRate, bypass: model.bypass, running: model.running,
                          comparisonProfile: model.otherComparisonProfile)
                .equatable().frame(height: graphHeight).auralPanel(padding: 14)
            comparison
            HStack {
                Picker("Controls", selection: Binding(get: { page }, set: changePage)) {
                    Text("Equalizer").tag(StudioPage.equalizer)
                    Text("Stereo & delay").tag(StudioPage.stereo)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 242).id(selectionRevision)
                Spacer()
                if page == .equalizer {
                    Menu("New EQ") {
                        Button("New flat 10-band EQ") { if submitPendingInput() { model.useGraphicTemplate(bands: 10) } }
                        Button("New flat 31-band EQ") { if submitPendingInput() { model.useGraphicTemplate(bands: 31) } }
                    }.fixedSize().help("Replace the current bands with a new flat EQ. Undo restores your previous EQ.")
                }
            }
            if page == .equalizer {
                FilterRack(model: model, submissions: submissions).frame(maxHeight: .infinity)
            } else {
                StereoPanel(model: model, submissions: submissions).frame(maxHeight: .infinity)
            }
        }.padding(18)
    }

    private var comparison: some View {
        HStack(spacing: 8) {
            AuralSectionLabel(title: "Compare")
            Button("A") { model.selectComparison(.a) }
                .buttonStyle(AuralButtonStyle(prominent: model.comparisonSlot == .a)).help("Listen to comparison A")
            Button("B") { model.selectComparison(.b) }
                .buttonStyle(AuralButtonStyle(prominent: model.comparisonSlot == .b)).help("Listen to comparison B")
            Menu {
                Button("Copy \(model.comparisonSlot.rawValue.uppercased()) to other slot") { if submitPendingInput() { model.copyComparisonToOther() } }
                Button("Reset both to current EQ") { if submitPendingInput() { model.captureComparison() } }
            } label: { Image(systemName: "doc.on.doc") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                .accessibilityLabel("Comparison actions")
            Spacer()
            Text(model.comparisonAvailable ? "Changes stay in A or B" : "Select B to start a comparison")
                .font(.system(size: 10)).foregroundStyle(AuralStyle.secondary)
        }.accessibilityElement(children: .contain).accessibilityLabel("A/B comparison")
    }

    private var notices: some View { SessionNotices(model: model) }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(statusColor).frame(width: 5, height: 5).accessibilityHidden(true)
            if model.interfaceMode == .professional {
                Text(model.running ? "STEREO OUTPUT" : "PREVIEW")
                Text("·").foregroundStyle(AuralStyle.border)
                Text(String(format: "%g kHz", model.responseRate / 1000)).monospacedDigit()
            } else {
                Text(status)
            }
            Spacer()
            Text("Close window to keep EQ in the menu bar").foregroundStyle(AuralStyle.secondary)
            Image(systemName: "lock.shield").accessibilityHidden(true)
        }.font(.system(size: 9, weight: .medium)).tracking(0.3).foregroundStyle(AuralStyle.secondary)
            .padding(.horizontal, 18).frame(height: 27)
    }

    private func submitPendingInput() -> Bool {
        switch submissions.submitActive() {
        case .rejected: return false
        case .submitted: return model.error == nil
        case .unchanged: return true
        }
    }

    private func changeInterfaceMode(_ mode: InterfaceMode) {
        guard mode != model.interfaceMode else { return }
        guard submitPendingInput() else { selectionRevision += 1; return }
        model.setInterfaceMode(mode)
        if model.interfaceMode != mode { selectionRevision += 1 }
    }

    private func changePage(_ next: StudioPage) {
        guard next != page else { return }
        guard submitPendingInput() else { selectionRevision += 1; return }
        page = next
    }
}

private enum StudioPage { case equalizer, stereo }
