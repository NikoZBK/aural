import SwiftUI

struct MainView: View {
    @ObservedObject var model: Model
    @ObservedObject var icon: AppIconController
    @Environment(\.openWindow) private var openWindow
    @State private var showStartup = false
    @State private var showFilterEditor = false
    @State private var page = StudioPage.equalizer
    @State private var selectedBand = 0
    @State private var filterDisplay = FilterDisplay.selected
    @State private var dragRevision: Int?
    @State private var dragOutput: String?
    @State private var selectionRevision = 0
    @StateObject private var submissions = PrecisionSubmissionCoordinator()

    // Keep the existing persisted preference: it now controls the inspector,
    // rather than selecting two independent copies of the listening workspace.
    private var detailsVisible: Bool { model.interfaceMode == .professional }
    private var status: String { model.running ? (model.bypass ? "Bypassed" : "EQ active") : "EQ stopped" }

    var body: some View {
        VStack(spacing: 0) {
            header.auralChrome()
            Divider()
            workspace.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer.auralChrome()
        }
        .frame(minWidth: 900, minHeight: 620)
        .auralAppearance(model.theme, style: model.interfaceStyle)
        .auralAnnouncement(model.error ?? model.importNotice ?? model.startupNotice)
        .focusedSceneValue(\.precisionSubmissions, submissions)
        .sheet(isPresented: $showFilterEditor) { FilterEditor(model: model) }
        .onChange(of: model.profile.filters?.count ?? model.profile.gains.count) { _, count in
            selectedBand = min(selectedBand, max(0, count - 1))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let image = icon.image { Image(nsImage: image).resizable().frame(width: 24, height: 24).accessibilityHidden(true) }
            Text("Aural").font(.system(size: 13, weight: .semibold))
            EQFileMenu(model: model, submissions: submissions)
            Button { if submitPendingInput() { openWindow.showAuralWindow("autoeq") } } label: {
                Label("AutoEQ", systemImage: "headphones")
            }.buttonStyle(AuralButtonStyle()).help("Search online headphone correction profiles")
            Spacer()
            OutputSelection(model: model, submissions: submissions, compact: true).frame(width: 280)
            Button { showStartup.toggle() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).accessibilityLabel("Settings").help("Appearance, startup, About, and updates")
                .popover(isPresented: $showStartup) { StartupSettings(model: model) }
        }.padding(.horizontal, 18).frame(height: 46)
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Preset").font(.system(size: 12, weight: .medium)).foregroundStyle(AuralStyle.secondary)
                        PresetSelection(model: model, submissions: submissions)
                        if model.isPresetModified { Text("Edited").font(.system(size: 11)).foregroundStyle(AuralStyle.secondary) }
                    }
                    Text("\(model.profile.filters?.count ?? model.profile.gains.count) filters · \(model.profile.stereoSettings == StereoSettings() ? "Stereo neutral" : "Stereo adjusted")")
                        .font(.system(size: 11)).foregroundStyle(AuralStyle.secondary)
                }
                Spacer(minLength: 0)
                SavePresetButton(model: model, submissions: submissions)
                Picker("A/B comparison", selection: Binding(get: { model.comparisonSlot }, set: { slot in
                    if submitPendingInput() { model.selectComparison(slot) }
                    selectionRevision += 1
                })) {
                    Text("A").tag(ComparisonSlot.a)
                    Text("B").tag(ComparisonSlot.b)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 70).id(selectionRevision)
                Toggle("Bypass", isOn: Binding(get: { model.bypass }, set: { value in if submitPendingInput() { model.setBypass(value) } }))
                    .toggleStyle(.button).controlSize(.small)
                    .help("Bypass EQ, preamp, and stereo effects. Routing and peak protection stay active.")
                Button(model.running ? "Stop EQ" : "Start EQ") {
                    if submitPendingInput() { model.running ? model.stop() : model.start() }
                }.buttonStyle(AuralButtonStyle(prominent: !model.running)).disabled(model.selected == nil && !model.running)
                Menu {
                    Button(model.undoLabel) { if submitPendingInput() { model.undoProfile() } }.disabled(!model.canUndo)
                    Button(model.redoLabel) { if submitPendingInput() { model.redoProfile() } }.disabled(!model.canRedo)
                    Divider()
                    Button("Copy current to other comparison slot") { if submitPendingInput() { model.copyComparisonToOther() } }
                    Button("Reset both comparisons to current EQ") { if submitPendingInput() { model.captureComparison() } }
                    Divider()
                    Button("Edit as a draft…") { if submitPendingInput() { showFilterEditor = true } }
                    Button("Copy EQ") { if submitPendingInput() { model.copyEQ() } }
                    Button("Paste EQ") { if submitPendingInput() { model.pasteEQ() } }
                    Button("Export EQ…") { if submitPendingInput() { model.exportEQ() } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
                    .accessibilityLabel("EQ options")
            }
            SessionNotices(model: model)
            ResponseCurve(profile: model.profile, rate: model.responseRate, bypass: model.bypass, running: model.running,
                          comparisonProfile: model.otherComparisonProfile, selectedBand: detailsVisible ? selectedBand : nil,
                          selectBand: selectBand, beginDrag: beginCurveDrag, changeDrag: changeCurveDrag, endDrag: endCurveDrag)
                .equatable().frame(minHeight: 120, idealHeight: 280, maxHeight: .infinity)
            Divider()
            HStack {
                Picker("Controls", selection: Binding(get: { page }, set: changePage)) {
                    Text("Filters").tag(StudioPage.equalizer)
                    Text("Stereo & delay").tag(StudioPage.stereo)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 210).id(selectionRevision)
                Spacer()
                Button(detailsVisible ? "Hide details" : "Show details") { setDetailsVisible(!detailsVisible) }
                    .buttonStyle(.plain).foregroundStyle(AuralStyle.secondary)
                    .help("Show or hide editing controls. Your current sound stays active.")
            }
            ZStack(alignment: .topLeading) {
                FilterRack(model: model, submissions: submissions, selectedBand: Binding(get: { selectedBand }, set: selectBand), display: $filterDisplay)
                    .frame(height: filterDisplay == .selected ? 146 : 206)
                    .auralGlassVisibility(detailsVisible && page == .equalizer)
                    .opacity(detailsVisible && page == .equalizer ? 1 : 0)
                    .allowsHitTesting(detailsVisible && page == .equalizer)
                    .accessibilityElement(children: detailsVisible && page == .equalizer ? .contain : .ignore)
                    .accessibilityHidden(!detailsVisible || page != .equalizer)
                    .disabled(!detailsVisible || page != .equalizer)
                if detailsVisible && page == .stereo {
                    StereoPanel(model: model, submissions: submissions).frame(height: 230)
                }
            }
            .frame(height: detailsVisible ? (page == .stereo ? 230 : (filterDisplay == .selected ? 146 : 206)) : 0, alignment: .top)
            .clipped()

        }.padding(20).background(AuralStyle.surface)
    }

    private var footer: some View {
        HStack(spacing: 20) {
            PreampControls(model: model, submissions: submissions, compact: true)
            Divider().frame(height: 24)
            StudioMeter(meter: model.meter, running: model.running, compact: true).frame(width: 260)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Circle().fill(model.running && !model.bypass ? AuralStyle.accent : AuralStyle.secondary).frame(width: 5, height: 5)
                Text(status)
                Text(String(format: "· %g kHz", model.responseRate / 1000)).foregroundStyle(AuralStyle.secondary)
            }.font(.system(size: 11)).accessibilityElement(children: .combine)
                .help("Audio passes through preamp and filters, stereo and delay, then sample-peak protection. Bypass skips EQ and stereo effects while routing and protection stay active. Stop releases the audio connection. Closing the window keeps EQ in the menu bar.")
        }.padding(.horizontal, 18).frame(height: 52)
    }

    private func submitPendingInput() -> Bool {
        switch submissions.submitActive() {
        case .rejected: return false
        case .submitted: return model.error == nil
        case .unchanged: return true
        }
    }

    private func setDetailsVisible(_ visible: Bool) {
        guard submitPendingInput() else { return }
        model.endProfileGesture()
        model.setInterfaceMode(visible ? .professional : .easy)
    }

    private func selectBand(_ index: Int) {
        guard submitPendingInput() else { return }
        model.endProfileGesture()
        model.setInterfaceMode(.professional)
        guard detailsVisible else { return }
        selectedBand = index
        filterDisplay = .selected
        page = .equalizer
    }

    private func beginCurveDrag(_ index: Int) -> EQBarBand? {
        guard submitPendingInput() else { return nil }
        guard let band = EQBarBand.bands(in: model.profile).first(where: { $0.index == index }) else {
            model.error = "The filter layout changed. Try the edit again."
            return nil
        }
        model.endProfileGesture()
        selectedBand = index
        dragRevision = model.editRevision
        dragOutput = model.selectedUID
        model.beginProfileGesture(label: "Curve adjustment")
        return band
    }

    private func changeCurveDrag(_ index: Int, frequency: Double, gain: Double) -> Bool {
        guard dragRevision == model.editRevision, dragOutput == model.selectedUID else {
            model.endProfileGesture()
            model.error = "The EQ changed during the drag. Release the pointer and try again."
            return false
        }
        if let filters = model.profile.filters {
            guard filters.indices.contains(index) else {
                model.error = "The filter layout changed. Try the edit again."
                return false
            }
            var filter = filters[index]
            filter.frequency = frequency
            if filter.kind.usesGain { filter.gain = gain }
            model.updateFilter(at: index, with: filter)
        } else {
            model.setBandGain(at: index, to: gain)
        }
        dragRevision = model.editRevision
        return model.error == nil
    }

    private func endCurveDrag(_ index: Int) {
        model.endProfileGesture()
        let unchanged = dragRevision == model.editRevision && dragOutput == model.selectedUID
        dragRevision = nil
        dragOutput = nil
        guard unchanged else {
            model.error = "The EQ changed during the drag. Release the pointer and try again."
            return
        }
        if model.error == nil { selectBand(index) }
    }

    private func changePage(_ next: StudioPage) {
        guard submitPendingInput() else { selectionRevision += 1; return }
        model.endProfileGesture()
        model.setInterfaceMode(.professional)
        guard detailsVisible else { selectionRevision += 1; return }
        page = next
    }
}

private enum StudioPage { case equalizer, stereo }
