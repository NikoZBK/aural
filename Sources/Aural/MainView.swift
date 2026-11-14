import SwiftUI

struct MainView: View {
    @ObservedObject var model: Model
    @ObservedObject var icon: AppIconController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showStartup = false
    @State private var showFilterEditor = false
    @State private var page = StudioPage.equalizer
    @State private var selectedBand = 0
    @State private var filterDisplay = FilterDisplay.faders
    @State private var dragRevision: Int?
    @State private var dragOutput: String?
    @State private var selectionRevision = 0
    // The placement on screen trails the model by one short fade; see movePlacement.
    @State private var shownPlacement: InspectorPlacement?
    @State private var inspectorFaded = false
    @State private var controlsFaded = false
    @State private var placementTask: Task<Void, Never>?
    // Beside the rail, a side inspector needs room for itself and a readable curve.
    @State private var sideFits = true
    @StateObject private var submissions = PrecisionSubmissionCoordinator()

    // Keep the existing persisted preference: it now controls the inspector,
    // rather than selecting two independent copies of the listening workspace.
    private var detailsVisible: Bool { model.interfaceMode == .professional }
    private var status: String {
        if let band = model.soloBand { return "Solo · band \(band + 1)" }
        return model.running ? (model.bypass ? "Bypassed" : "EQ active") : (model.starting ? "Starting" : (model.waitingForOutput ? "Waiting" : "EQ stopped"))
    }
    private var statusSymbol: String {
        if model.soloBand != nil { return "headphones" }
        return model.running ? (model.bypass ? "arrow.turn.up.right" : "checkmark.circle.fill") : (model.starting ? "ellipsis.circle" : (model.waitingForOutput ? "hourglass" : "stop.circle"))
    }
    /// A wait keeps EQ on: Stop cancels it, as it would stop running audio.
    private var processingOn: Bool { model.running || model.waitingForOutput || model.starting }
    /// Layout changes that move whole surfaces share one animation at the workspace
    /// level, so the curve, controls, and inspector stay in step with each other.
    private var workspaceMotion: WorkspaceMotion {
        WorkspaceMotion(placement: placement, page: page, display: filterDisplay,
                        notices: [model.startupNotice, model.error, model.importNotice])
    }
    private var targetPlacement: InspectorPlacement {
        InspectorPlacement(visible: detailsVisible, side: detailsVisible && sideFits && model.filterPanelPosition == .right)
    }
    private var placement: InspectorPlacement { shownPlacement ?? targetPlacement }
    // This view applies zoom to its own body, so the environment above it still reads 1.
    private var interfaceScale: CGFloat { model.interfaceZoom.scale }
    private var filterInspectorHeight: CGFloat {
        switch filterDisplay {
        case .selected: return 146
        case .rows: return 206
        case .faders: return 352
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let logicalWidth = geometry.size.width / model.interfaceZoom.scale
            HStack(spacing: 0) {
                rail
                    .auralFrame(width: logicalWidth < 780 ? 232 : 248)
                    .background { AuralChromeBackground() }
                    .auralPadding([.leading, .vertical], 12)
                workspace.auralFrame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .auralZoom(model)
        .frame(minWidth: 900, minHeight: 620)
        .auralAppearance(model.theme)
        .background(HistoryKeyboardShortcuts(canUndo: model.canUndo, canRedo: model.canRedo,
                                            undo: { if submitPendingInput() { withAuralAnimation { model.undoProfile() } } },
                                            redo: { if submitPendingInput() { withAuralAnimation { model.redoProfile() } } }))
        .auralAnnouncement(model.error ?? model.importNotice ?? model.startupNotice)
        .focusedSceneValue(\.precisionSubmissions, submissions)
        .sheet(isPresented: $showFilterEditor) { FilterEditor(model: model) }
        .onChange(of: model.profile.filters?.count ?? model.profile.gains.count) { _, count in
            selectedBand = min(selectedBand, max(0, count - 1))
        }
    }

    /// Everything about listening lives in one rail, top to bottom in signal order:
    /// power, where the audio goes, the sound that shapes it, how to audition it, and
    /// the level leaving Aural. Each group keeps its own actions, so nothing has to be
    /// looked for in a different bar. The rail scrolls when zoom leaves it short.
    private var rail: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8 * interfaceScale) {
                HStack(spacing: 8 * interfaceScale) {
                    if let image = icon.image { Image(nsImage: image).resizable().auralFrame(width: 24, height: 24).accessibilityHidden(true) }
                    statusLabel
                    Spacer(minLength: 0)
                    Button { showStartup.toggle() } label: { Image(systemName: "gearshape") }
                        .buttonStyle(AuralButtonStyle()).accessibilityLabel("Settings").help("Appearance, output, startup, About, and updates")
                        .popover(isPresented: $showStartup) { StartupSettings(model: model).auralZoom(model) }
                }
                transport
                Divider()
                VStack(alignment: .leading, spacing: 8 * interfaceScale) {
                    OutputSelection(model: model, submissions: submissions, captioned: false)
                    // App levels belong to the output they play on.
                    Button { if submitPendingInput() { openWindow.showAuralWindow("apps") } } label: {
                        Label("App volumes", systemImage: "slider.horizontal.3").auralFrame(maxWidth: .infinity)
                    }.buttonStyle(AuralButtonStyle()).accessibilityLabel("Open app mixer")
                        .help("Open per-app volume and mute for this output (⇧⌘M)")
                }
                Divider()
                soundSection
                Divider()
                compareSection
                Divider()
                VStack(alignment: .leading, spacing: 7 * interfaceScale) {
                    AuralSectionLabel(title: "Tone & level", systemImage: "dial.medium")
                    PreampControls(model: model, submissions: submissions, compact: true)
                    TiltControls(model: model, submissions: submissions)
                    LoudnessControls(model: model)
                    StudioMeter(meter: model.meter, running: model.running,
                                protectionEnabled: Binding(get: { model.peakProtectionEnabled }, set: model.setPeakProtection),
                                compact: true)
                }
            }.auralPadding(.horizontal, 14).auralPadding(.vertical, 10)
        }
    }

    private var transportKey: TransportKey {
        TransportKey(status: status, symbol: statusSymbol, warning: model.running && (model.bypass || model.soloBand != nil),
                     processing: processingOn, selected: model.selected != nil, solo: model.soloBand != nil, scale: interfaceScale)
    }

    private var statusLabel: some View {
        AuralEquatableContent(key: transportKey) {
            Label {
                Text(status).contentTransition(.interpolate)
            } icon: {
                Image(systemName: statusSymbol).auralSymbolTransition()
            }
                .auralFont(size: 12, weight: .semibold)
                .foregroundStyle(model.running && (model.bypass || model.soloBand != nil) ? AuralStyle.warning : Color.primary)
                .lineLimit(1)
                .accessibilityIdentifier("processing-status")
                .help(AuralHelp.signalPath + " Waiting means audio resumes on the saved output. Solo plays only one band's part of the spectrum.")
                .auralAnimation(AuralMotion.quick, value: [model.running, model.bypass, model.waitingForOutput, model.soloBand != nil])
        }.equatable()
    }

    private var transport: some View {
        AuralEquatableContent(key: transportKey) {
        VStack(alignment: .leading, spacing: 8 * interfaceScale) {
            Button {
                model.toggleProcessing(submitPendingInput: submitPendingInput)
            } label: {
                Label {
                    Text(processingOn ? "Stop EQ" : "Start EQ").contentTransition(.interpolate)
                } icon: {
                    Image(systemName: processingOn ? "stop.fill" : "play.fill").auralSymbolTransition()
                }
                    .auralFrame(maxWidth: .infinity)
            }.buttonStyle(AuralButtonStyle(prominent: !processingOn)).disabled(model.selected == nil && !processingOn)
                .help(AuralHelp.processing(processingOn))
            if model.soloBand != nil {
                Button { if submitPendingInput() { withAuralAnimation { model.setSolo(nil) } } } label: {
                    Text("End solo").auralFrame(maxWidth: .infinity)
                }.buttonStyle(AuralButtonStyle()).help("Play the whole EQ again")
            }
        }.auralAnimation(AuralMotion.quick, value: [model.running, model.soloBand != nil])
        }.equatable()
    }

    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 7 * interfaceScale) {
            HStack(spacing: 8 * interfaceScale) {
                AuralSectionLabel(title: "Sound", systemImage: "waveform")
                Spacer(minLength: 0)
                if model.isPresetModified {
                    Label("Edited", systemImage: "pencil").auralFont(size: 10)
                        .foregroundStyle(AuralStyle.secondary)
                        .help("The current EQ differs from the saved preset. Save to keep a named copy.")
                        .transition(.auralPop(reduceMotion: reduceMotion))
                }
            }
            PresetSelection(model: model, submissions: submissions)
            AuralEquatableContent(key: interfaceScale) {
                VStack(alignment: .leading, spacing: 8 * interfaceScale) {
                    HStack(spacing: 8 * interfaceScale) {
                        SavePresetButton(model: model, submissions: submissions)
                        Button { if submitPendingInput() { openWindow.showAuralWindow("presets") } } label: {
                            Label("Presets", systemImage: "square.stack").auralFrame(maxWidth: .infinity)
                        }.buttonStyle(AuralButtonStyle())
                            .accessibilityLabel("Open preset library")
                            .help("Search, organize, and back up presets (⇧⌘P)")
                    }
                    HStack(spacing: 12 * interfaceScale) {
                        Button { if submitPendingInput() { openWindow.showAuralWindow("autoeq") } } label: {
                            Label("AutoEQ", systemImage: "headphones").foregroundStyle(AuralStyle.violet)
                        }.buttonStyle(AuralButtonStyle())
                            .help("Search online headphone correction profiles")
                        EQFileMenu(model: model, submissions: submissions)
                        Spacer(minLength: 0)
                    }
                }
            }.equatable()
        }.auralAnimation(AuralMotion.quick, value: model.isPresetModified)
    }

    /// Auditioning: the two EQ versions, the unprocessed sound, and the loudness
    /// matching that keeps the comparison fair.
    private var compareSection: some View {
        AuralEquatableContent(key: CompareKey(comparison: model.comparisonSlot, matching: model.matchLevels, bypass: model.bypass,
                                              scale: interfaceScale, revision: selectionRevision)) {
        VStack(alignment: .leading, spacing: 7 * interfaceScale) {
            HStack(spacing: 8 * interfaceScale) {
                AuralSectionLabel(title: "Compare", systemImage: "arrow.left.arrow.right")
                Spacer(minLength: 0)
                Toggle("Match levels", isOn: Binding(get: { model.matchLevels }, set: model.setMatchLevels))
                    .toggleStyle(AuralCheckboxStyle()).auralControlSize(.small).auralFont(size: 11).fixedSize()
                    .help("Plays Bypass and the louder A/B version at the same estimated loudness, so louder doesn't sound better. Saved presets don't change.")
            }
            HStack(spacing: 8 * interfaceScale) {
                AuralSegmented(title: "A/B comparison", selection: Binding(get: { model.comparisonSlot }, set: { slot in
                    if submitPendingInput() { withAuralAnimation { model.selectComparison(slot) } }
                    selectionRevision += 1
                }), options: [(ComparisonSlot.a, "A"), (ComparisonSlot.b, "B")]).auralFrame(width: 76).transition(.identity).id(selectionRevision)
                    .help(model.matchLevels
                          ? "Compare two versions of your EQ. Each slot keeps its edits; switching preserves playback. The louder version plays lower so both match."
                          : "Compare two versions of your EQ. Each slot keeps its edits; switching preserves playback.")
                Toggle("Bypass", isOn: Binding(get: { model.bypass }, set: { value in if submitPendingInput() { withAuralAnimation { model.setBypass(value) } } }))
                    .toggleStyle(AuralGelToggleStyle()).auralControlSize(.small)
                    .help(model.matchLevels
                          ? "Bypass EQ, preamp, and stereo effects at the EQ's estimated loudness. Routing stays active; peak protection follows its On/Off switch."
                          : "Bypass EQ, preamp, and stereo effects. Routing stays active; peak protection follows its On/Off switch.")
                Spacer(minLength: 0)
                Menu {
                    Button("Copy current to other comparison slot") { if submitPendingInput() { withAuralAnimation { model.copyComparisonToOther() } } }.help("Replace the other A/B slot with the current EQ.")
                    Button("Reset both comparisons to current EQ") { if submitPendingInput() { withAuralAnimation { model.captureComparison() } } }.help("Replace both A/B comparison slots with the current EQ.")
                } label: { Image(systemName: "ellipsis") }
                    .auralMenuButton().fixedSize()
                    .accessibilityLabel("Comparison options").help("Copy or reset the A/B comparison slots")
            }
        }
        }.equatable()
    }

    private var workspace: some View {
        GeometryReader { geometry in
            let logicalWidth = geometry.size.width / interfaceScale - 24
            let fits = logicalWidth >= 620
            let sidePanel = placement.side
            let detailsShown = placement.visible
            let panelWidth = AuralWorkspaceLayout.sidePanelWidth(in: geometry.size.width - 24 * interfaceScale, scale: interfaceScale)
            let inspectorContentHeight: CGFloat = sidePanel
                ? (page == .equalizer && filterDisplay == .faders ? 400 : 230)
                : (page == .stereo ? 230 : filterInspectorHeight)
            let minimumInspectorHeight: CGFloat = detailsShown ? (inspectorContentHeight + 22) * interfaceScale : 0
            ScrollView {
                AuralWorkspaceLayout(availableHeight: max(0, geometry.size.height - 24 * interfaceScale),
                                     minimumInspectorHeight: minimumInspectorHeight,
                                     sidePanelWidth: sidePanel ? panelWidth : nil, scale: interfaceScale) {
                    editBar(compact: logicalWidth < 430)
                    VStack { SessionNotices(model: model) }
                    ResponseCurve(profile: model.profile, rate: model.responseRate, bypass: model.bypass, running: model.running,
                                  levelMatch: model.levelMatch, comparisonProfile: model.otherComparisonProfile, selectedBand: detailsVisible ? selectedBand : nil,
                                  selectBand: selectBand, beginDrag: beginCurveDrag, changeDrag: changeCurveDrag, endDrag: endCurveDrag,
                                  minimumPlotHeight: 132)
                        .equatable().frame(maxHeight: .infinity)
                        .auralWorkspaceSurface(emphasized: true)
                        // Above the controls, so an inspector arriving before the curve
                        // settles is uncovered by it rather than drawn across it.
                        .zIndex(1)
                    // One card holds the inspector and the tabs that switch it. The layout
                    // sizes it to both, so hidden details leave the tabs as a slim card.
                    // It fades and jumps with the tabs; resizing only redraws a shape.
                    Color.clear.auralWorkspaceSurface(padding: 0)
                        .allowsHitTesting(false).accessibilityHidden(true)
                        .auralRelocation(sidePanel, hidden: controlsFaded)
                    let inspectorToolbar = (sidePanel ? panelWidth / interfaceScale : logicalWidth) < 480
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10 * interfaceScale))
                        : AnyLayout(HStackLayout(spacing: 12 * interfaceScale))
                    inspectorToolbar {
                        // Sized to its segments, which macOS may draw equal and wider than a fixed frame.
                        AuralSegmented(title: "Controls", selection: Binding(get: { page }, set: changePage),
                                       options: [(StudioPage.equalizer, "Filters"), (StudioPage.stereo, "Stereo & delay")]).fixedSize().transition(.identity).id(selectionRevision)
                            .help("Switch between filter editing and stereo balance, width, crossfeed, channel trims, and delay.")
                        HStack(spacing: 8 * interfaceScale) {
                            Spacer(minLength: 0)
                            Menu {
                                FilterPanelPositionPicker(model: model).pickerStyle(.inline)
                            } label: {
                                Label("Panel", systemImage: model.filterPanelPosition.symbol)
                            }.auralMenuButton().fixedSize()
                                .accessibilityLabel("Filter panel position")
                                .accessibilityValue(model.filterPanelPosition.label)
                                .help("Place editing controls below or to the right of the graph. Your choice is remembered.")
                            Button { setDetailsVisible(!detailsVisible) } label: {
                                // Keep one rotating chevron through disclosure changes.
                                Label {
                                    Text(detailsVisible ? "Hide details" : "Show details")
                                } icon: {
                                    Image(systemName: "chevron.right").rotationEffect(.degrees(detailsVisible ? 90 : 0))
                                        .auralAnimation(AuralMotion.quick, value: detailsVisible)
                                }
                            }.buttonStyle(AuralButtonStyle()).fixedSize()
                                .accessibilityLabel(detailsVisible ? "Hide details" : "Show details")
                                .help("Show or hide editing controls. Your current sound stays active.")
                        }
                    }
                    .auralPadding(.horizontal, 14).auralPadding(.vertical, 10)
                    .auralRelocation(sidePanel, hidden: controlsFaded)
                    let inspectorHeight: CGFloat = detailsShown ? (page == .stereo ? 230 : filterInspectorHeight) : 0
                    let editorsActive = detailsShown && detailsVisible && page == .equalizer
                    GeometryReader { inspector in
                        let height = sidePanel ? max(inspectorContentHeight, inspector.size.height / interfaceScale) : inspectorHeight
                        // The workspace owns overflow; the table and faders own their
                        // own scroll axes. A second vertical viewport here produces
                        // competing scrollbars as the retained editors change height.
                        ZStack(alignment: .topLeading) {
                                FilterRack(model: model, submissions: submissions, selectedBand: $selectedBand, display: $filterDisplay,
                                           expanded: sidePanel, compactRows: inspector.size.width / model.interfaceZoom.scale < 520,
                                           active: editorsActive)
                                    .auralFrame(height: sidePanel ? height : filterInspectorHeight)
                                    .opacity(detailsShown && page == .equalizer ? 1 : 0)
                                    .allowsHitTesting(editorsActive)
                                    .accessibilityElement(children: editorsActive ? .contain : .ignore)
                                    .accessibilityHidden(!editorsActive)
                                    .disabled(!editorsActive)
                                if detailsShown && page == .stereo {
                                    StereoPanel(model: model, submissions: submissions, stacked: sidePanel).auralFrame(height: height)
                                        .transition(.opacity)
                                }
                        }
                        .auralFrame(height: height, alignment: .top).clipped()
                    }
                    .frame(minHeight: detailsShown ? 40 : 0, idealHeight: inspectorHeight * model.interfaceZoom.scale,
                           maxHeight: sidePanel ? .infinity : inspectorHeight * model.interfaceZoom.scale, alignment: .top)
                    .auralPadding([.horizontal, .bottom], detailsShown ? 12 : 0).auralPadding(.top, detailsShown ? 10 : 0)
                    // Separates the tabs from what they show, and leaves with the details.
                    .overlay(alignment: .top) { if detailsShown { Divider() } }
                    .auralRelocation(placement, hidden: inspectorFaded)
                }.auralPadding(12)
            }.clipped()
                .auralAnimation(value: workspaceMotion)
                .onAppear {
                    sideFits = fits
                    let target = InspectorPlacement(visible: detailsVisible, side: detailsVisible && fits && model.filterPanelPosition == .right)
                    shownPlacement = target
                    inspectorFaded = !target.visible
                }
                .onChange(of: fits) { _, value in sideFits = value }
                .onChange(of: targetPlacement) { _, target in movePlacement(to: target) }
        }
    }

    /// Editing history and whole-EQ editing actions sit on the curve they change.
    private func editBar(compact: Bool) -> some View {
        let summary = "\(model.profile.filters?.count ?? model.profile.gains.count) filters · \(model.profile.stereoSettings == StereoSettings() ? "Stereo neutral" : "Stereo adjusted")"
        return AuralEquatableContent(key: EditBarKey(compact: compact, summary: summary, undo: model.undoLabel, redo: model.redoLabel,
                                                     canUndo: model.canUndo, canRedo: model.canRedo, scale: interfaceScale)) {
            HStack(spacing: 10 * interfaceScale) {
                AuralSectionLabel(title: "Equalizer", systemImage: "slider.vertical.3")
                if !compact {
                    Text(summary).auralFont(size: 11).foregroundStyle(AuralStyle.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 4 * interfaceScale) {
                    Button { if submitPendingInput() { withAuralAnimation { model.undoProfile() } } } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(AuralButtonStyle()).disabled(!model.canUndo)
                        .accessibilityLabel(model.undoLabel).help("\(model.undoLabel) (⌘Z)")
                    Button { if submitPendingInput() { withAuralAnimation { model.redoProfile() } } } label: { Image(systemName: "arrow.uturn.forward") }
                        .buttonStyle(AuralButtonStyle()).disabled(!model.canRedo)
                        .accessibilityLabel(model.redoLabel).help("\(model.redoLabel) (⇧⌘Z)")
                }
                Menu {
                    Button("Edit as a draft…") { if submitPendingInput() { showFilterEditor = true } }.help("Open a draft of the current EQ. Review changes before applying them.")
                    Divider()
                    Button("Copy EQ") { if submitPendingInput() { model.copyEQ() } }.help(AuralHelp.copyEQ)
                    Button("Paste EQ") { if submitPendingInput() { withAuralAnimation { model.pasteEQ() } } }.help(AuralHelp.pasteEQ)
                    Button("Export EQ…") { if submitPendingInput() { model.exportEQ() } }.help(AuralHelp.exportEQ)
                } label: { Label("Edit", systemImage: "ellipsis") }
                    .auralMenuButton().fixedSize()
                    .accessibilityLabel("EQ options").help("Draft editing and clipboard")
            }.auralPadding(.horizontal, 4)
        }.equatable()
    }

    private func submitPendingInput() -> Bool {
        switch submissions.submitActive() {
        case .rejected: return false
        case .submitted: return model.error == nil
        case .unchanged: return true
        }
    }

    /// Moves the inspector in three beats. What is about to move fades out in place,
    /// the curve reflows while the inspector jumps to its new frame unseen, and the
    /// inspector fades in as the curve settles. Its retained editors never slide or
    /// squeeze across the curve, and they are laid out once instead of every frame.
    private func movePlacement(to target: InspectorPlacement) {
        placementTask?.cancel()
        placementTask = nil
        let shown = placement
        guard shown != target else {
            // Reversed before the layout moved: bring back what was fading out.
            withAnimation(AuralMotion.quick) {
                inspectorFaded = !target.visible
                controlsFaded = false
            }
            return
        }
        let relocating = shown.side != target.side
        let vacating = (shown.visible && !inspectorFaded) || (relocating && !controlsFaded)
        withAnimation(AuralMotion.vacate) {
            inspectorFaded = true
            if relocating { controlsFaded = true }
        }
        let settle = {
            shownPlacement = target
            withAnimation(AuralMotion.arrive) {
                inspectorFaded = !target.visible
                controlsFaded = false
            }
        }
        guard vacating else { return settle() }
        placementTask = Task { @MainActor in
            do { try await Task.sleep(for: AuralMotion.vacateDuration) } catch { return }
            settle()
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

private struct TransportKey: Equatable {
    let status: String
    let symbol: String
    let warning: Bool
    let processing: Bool
    let selected: Bool
    let solo: Bool
    let scale: CGFloat
}

private struct CompareKey: Equatable {
    let comparison: ComparisonSlot
    let matching: Bool
    let bypass: Bool
    let scale: CGFloat
    let revision: Int
}

private struct EditBarKey: Equatable {
    let compact: Bool
    let summary: String
    let undo: String
    let redo: String
    let canUndo: Bool
    let canRedo: Bool
    let scale: CGFloat
}

/// Where the inspector sits. Hidden details have no side placement, so moving the
/// panel while they are hidden doesn't move anything.
private struct InspectorPlacement: Equatable {
    let visible: Bool
    let side: Bool
}

private struct WorkspaceMotion: Equatable {
    let placement: InspectorPlacement
    let page: StudioPage
    let display: FilterDisplay
    let notices: [String?]
}

/// Preserve each control row's measured height, then give the curve the space
/// left over. The inspector can scroll before the outer workspace needs to.
/// Keeping one layout and one scroll view also retains focused native editors.
/// The card spans the inspector's tabs and the inspector, below or beside the curve.
struct AuralWorkspaceLayout: AuralContainerLayout {
    let availableHeight: CGFloat
    let minimumInspectorHeight: CGFloat
    var sidePanelWidth: CGFloat? = nil
    var scale: CGFloat = 1
    private var spacing: CGFloat { 12 * scale }
    /// Between the curve and the inspector card, in either placement.
    private var surfaceGap: CGFloat { 12 * scale }

    struct MeasurementKey: Equatable {
        let width: CGFloat
        let height: CGFloat
        let inspector: CGFloat
        let side: CGFloat?
        let scale: CGFloat
    }
    struct Cache {
        var key: MeasurementKey?
        var frames: [CGRect] = []
    }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.key = nil }

    private func frames(width: CGFloat, subviews: Subviews, cache: inout Cache) -> [CGRect] {
        let key = MeasurementKey(width: width, height: availableHeight, inspector: minimumInspectorHeight, side: sidePanelWidth, scale: scale)
        if cache.key != key {
            cache.frames = measureFrames(width: width, subviews: subviews)
            cache.key = key
        }
        return cache.frames
    }

    static func sidePanelWidth(in width: CGFloat, scale: CGFloat) -> CGFloat {
        min(max(544 * scale, width * 0.43), width - 260 * scale - 12 * scale)
    }

    private func measureFrames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        precondition(subviews.count == 6, "Workspace layout requires toolbar, notices, curve, card, tabs, and inspector")
        func height(_ index: Int, width: CGFloat) -> CGFloat {
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        let toolbar = height(0, width: width)
        let notices = height(1, width: width)
        let top = toolbar + spacing + (notices > 0 ? notices + spacing : 0)
        let curve, tabs, inspector: CGRect
        if let sidePanelWidth {
            let curveWidth = max(0, width - sidePanelWidth - surfaceGap)
            let tabsHeight = height(4, width: sidePanelWidth)
            let bodyHeight = max(availableHeight - top, height(2, width: curveWidth), tabsHeight + minimumInspectorHeight)
            curve = CGRect(x: 0, y: top, width: curveWidth, height: bodyHeight)
            tabs = CGRect(x: curveWidth + surfaceGap, y: top, width: sidePanelWidth, height: tabsHeight)
            inspector = CGRect(x: tabs.minX, y: tabs.maxY, width: sidePanelWidth, height: bodyHeight - tabsHeight)
        } else {
            let tabsHeight = height(4, width: width)
            let minimumCurveHeight = height(2, width: width)
            let idealInspectorHeight = height(5, width: width)
            let room = availableHeight - top - surfaceGap - tabsHeight
            let inspectorHeight = max(min(minimumInspectorHeight, idealInspectorHeight),
                                      min(idealInspectorHeight, room - minimumCurveHeight))
            curve = CGRect(x: 0, y: top, width: width, height: max(minimumCurveHeight, room - inspectorHeight))
            tabs = CGRect(x: 0, y: curve.maxY + surfaceGap, width: width, height: tabsHeight)
            inspector = CGRect(x: 0, y: tabs.maxY, width: width, height: inspectorHeight)
        }
        return [
            CGRect(x: 0, y: 0, width: width, height: toolbar),
            CGRect(x: 0, y: toolbar + spacing, width: width, height: notices),
            curve, tabs.union(inspector), tabs, inspector
        ]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 900
        return CGSize(width: width, height: frames(width: width, subviews: subviews, cache: &cache).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews, cache: &cache)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(frame.size))
        }
    }
}
