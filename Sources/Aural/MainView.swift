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
    @State private var filterDisplay = FilterDisplay.selected
    @State private var dragRevision: Int?
    @State private var dragOutput: String?
    @State private var selectionRevision = 0
    // The placement on screen trails the model by one short fade; see movePlacement.
    @State private var shownPlacement: InspectorPlacement?
    @State private var inspectorFaded = false
    @State private var controlsFaded = false
    @State private var placementTask: Task<Void, Never>?
    @StateObject private var submissions = PrecisionSubmissionCoordinator()

    // Keep the existing persisted preference: it now controls the inspector,
    // rather than selecting two independent copies of the listening workspace.
    private var detailsVisible: Bool { model.interfaceMode == .professional }
    private var status: String {
        if let band = model.soloBand { return "Solo · band \(band + 1)" }
        return model.running ? (model.bypass ? "Bypassed" : "EQ active") : (model.waitingForOutput ? "Waiting" : "EQ stopped")
    }
    private var statusSymbol: String {
        if model.soloBand != nil { return "headphones" }
        return model.running ? (model.bypass ? "arrow.turn.up.right" : "checkmark.circle.fill") : (model.waitingForOutput ? "hourglass" : "stop.circle")
    }
    /// A wait keeps EQ on: Stop cancels it, as it would stop running audio.
    private var processingOn: Bool { model.running || model.waitingForOutput }
    /// Layout changes that move whole surfaces share one animation at the workspace
    /// level, so the curve, controls, and inspector stay in step with each other.
    private var workspaceMotion: WorkspaceMotion {
        WorkspaceMotion(placement: placement, page: page, display: filterDisplay,
                        notices: [model.startupNotice, model.error, model.importNotice])
    }
    private var targetPlacement: InspectorPlacement {
        InspectorPlacement(visible: detailsVisible, side: detailsVisible && model.filterPanelPosition == .right)
    }
    private var placement: InspectorPlacement { shownPlacement ?? targetPlacement }
    // This view applies zoom to its own body, so the environment above it still reads 1.
    private var interfaceScale: CGFloat { model.interfaceZoom.scale }

    var body: some View {
        GeometryReader { geometry in
            let logicalWidth = geometry.size.width / model.interfaceZoom.scale
            VStack(spacing: 0) {
                // Docked bars frame the workspace, like a mixing console's header and transport.
                header(compact: logicalWidth < 820).background(AuralStyle.surface)
                Divider()
                workspace(compact: logicalWidth < 720).auralFrame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                // A wide bar holds preamp, tilt, loudness, level, and protection on one row.
                footer(compact: logicalWidth < 960).background(AuralStyle.surface)
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

    private func header(compact: Bool) -> some View {
        let layout = compact ? AnyLayout(VStackLayout(spacing: 10 * interfaceScale)) : AnyLayout(HStackLayout(spacing: 24 * interfaceScale))
        return layout {
            HStack(spacing: 18 * interfaceScale) {
                HStack(spacing: 8 * interfaceScale) {
                    if let image = icon.image { Image(nsImage: image).resizable().auralFrame(width: 28, height: 28).accessibilityHidden(true) }
                    Text("Aural").auralFont(size: 15, weight: .semibold)
                }.fixedSize()
                Divider().auralFrame(height: 28)
                OutputSelection(model: model, submissions: submissions, compact: true)
                    .auralFrame(minWidth: 190, maxWidth: 310)
                Spacer(minLength: 0)
            }
            // A hairline marks the transport section, as on a console's channel strip.
            if !compact { Divider().auralFrame(height: 28) }
            listeningControls
                .fixedSize(horizontal: !compact, vertical: true)
        }.auralPadding(.horizontal, 20).auralPadding(.vertical, 12)
    }

    private var listeningControls: some View {
        HStack(spacing: 12 * interfaceScale) {
            Label {
                Text(status).contentTransition(.interpolate)
            } icon: {
                Image(systemName: statusSymbol).auralSymbolTransition()
            }
                .auralFont(size: 11, weight: .medium)
                .foregroundStyle(model.running && (model.bypass || model.soloBand != nil) ? AuralStyle.warning : Color.primary)
                .fixedSize()
                .accessibilityIdentifier("processing-status")
                .help("Bypass skips EQ, preamp, and stereo effects while routing stays active. Stop releases the audio connection. Waiting means EQ resumes when its output is ready. Solo plays only one band's part of the spectrum.")
            Spacer(minLength: 12 * interfaceScale)
            if model.soloBand != nil {
                Button("End solo") { if submitPendingInput() { withAuralAnimation { model.setSolo(nil) } } }
                    .buttonStyle(AuralButtonStyle()).help("Play the whole EQ again")
            }
            // Beside Bypass, which it affects with A/B.
            Toggle("Match levels", isOn: Binding(get: { model.matchLevels }, set: model.setMatchLevels))
                .toggleStyle(.checkbox).auralControlSize(.small).auralFont(size: 11).fixedSize()
                .help("Plays Bypass and the louder A/B version at the same estimated loudness, so louder doesn't sound better. Saved presets don't change.")
            Toggle("Bypass", isOn: Binding(get: { model.bypass }, set: { value in if submitPendingInput() { withAuralAnimation { model.setBypass(value) } } }))
                .toggleStyle(.button).auralControlSize(.small)
                .help(model.matchLevels
                      ? "Bypass EQ, preamp, and stereo effects at the EQ's estimated loudness. Routing stays active; peak protection follows its On/Off switch."
                      : "Bypass EQ, preamp, and stereo effects. Routing stays active; peak protection follows its On/Off switch.")
            Button {
                model.toggleProcessing(submitPendingInput: submitPendingInput)
            } label: {
                Label {
                    Text(processingOn ? "Stop EQ" : "Start EQ").contentTransition(.interpolate)
                } icon: {
                    Image(systemName: processingOn ? "stop.fill" : "play.fill").auralSymbolTransition()
                }
                    .auralFrame(minWidth: 78)
            }.buttonStyle(AuralButtonStyle(prominent: !processingOn)).disabled(model.selected == nil && !processingOn)
            Button { showStartup.toggle() } label: { Image(systemName: "gearshape") }
                .buttonStyle(AuralButtonStyle()).accessibilityLabel("Settings").help("Appearance, output, startup, About, and updates")
                .popover(isPresented: $showStartup) { StartupSettings(model: model).auralZoom(model) }
        }.fixedSize(horizontal: false, vertical: true)
            .auralAnimation(AuralMotion.quick, value: [model.running, model.bypass, model.waitingForOutput, model.soloBand != nil])
    }

    private func workspace(compact: Bool) -> some View {
        GeometryReader { geometry in
            let sidePanel = placement.side
            let detailsShown = placement.visible
            let panelWidth = AuralWorkspaceLayout.sidePanelWidth(in: geometry.size.width - 40 * interfaceScale, scale: interfaceScale)
            ScrollView {
                AuralWorkspaceLayout(availableHeight: max(0, geometry.size.height - 40 * interfaceScale),
                                     minimumInspectorHeight: detailsShown ? 80 * interfaceScale : 0,
                                     sidePanelWidth: sidePanel ? panelWidth : nil, scale: interfaceScale) {
                    let toolbarLayout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12 * interfaceScale)) : AnyLayout(HStackLayout(alignment: .top, spacing: 20 * interfaceScale))
                    toolbarLayout {
                        let presetLayout = compact ? AnyLayout(HStackLayout(spacing: 12 * interfaceScale)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 8 * interfaceScale))
                        presetLayout {
                            HStack(spacing: 8 * interfaceScale) {
                                AuralSectionLabel(title: "Preset")
                                if !compact {
                                    Text("· \(model.profile.filters?.count ?? model.profile.gains.count) filters · \(model.profile.stereoSettings == StereoSettings() ? "Stereo neutral" : "Stereo adjusted")")
                                        .auralFont(size: 11).foregroundStyle(AuralStyle.secondary).lineLimit(1)
                                }
                                if model.isPresetModified {
                                    Label("Edited", systemImage: "pencil").auralFont(size: 10)
                                        .foregroundStyle(AuralStyle.secondary)
                                        .help("The current EQ differs from the saved preset. Save to keep a named copy.")
                                        .transition(.auralPop(reduceMotion: reduceMotion))
                                }
                            }
                            HStack(spacing: 8 * interfaceScale) {
                                PresetSelection(model: model, submissions: submissions)
                                SavePresetButton(model: model, submissions: submissions)
                            }
                        }
                        workspaceActions(compact: compact)
                            .auralFrame(maxWidth: .infinity, alignment: .trailing)
                    }.auralAnimation(AuralMotion.quick, value: model.isPresetModified)
                    VStack { SessionNotices(model: model) }
                    ResponseCurve(profile: model.profile, rate: model.responseRate, bypass: model.bypass, running: model.running,
                                  levelMatch: model.levelMatch, comparisonProfile: model.otherComparisonProfile, selectedBand: detailsVisible ? selectedBand : nil,
                                  selectBand: selectBand, beginDrag: beginCurveDrag, changeDrag: changeCurveDrag, endDrag: endCurveDrag,
                                  minimumPlotHeight: 132)
                        .equatable().frame(maxHeight: .infinity)
                        .auralWorkspaceSurface()
                        // Above the controls, so an inspector arriving before the curve
                        // settles is uncovered by it rather than drawn across it.
                        .zIndex(1)
                    // One card holds the inspector and the tabs that switch it. The layout
                    // sizes it to both, so hidden details leave the tabs as a slim card.
                    // It fades and jumps with the tabs; resizing only redraws a shape.
                    Color.clear.auralWorkspaceSurface(padding: 0)
                        .allowsHitTesting(false).accessibilityHidden(true)
                        .auralRelocation(sidePanel, hidden: controlsFaded)
                    HStack(spacing: 8 * interfaceScale) {
                        // Sized to its segments, which macOS may draw equal and wider than a fixed frame.
                        Picker("Controls", selection: Binding(get: { page }, set: changePage)) {
                            Text("Filters").tag(StudioPage.equalizer)
                            Text("Stereo & delay").tag(StudioPage.stereo)
                        }.pickerStyle(.segmented).labelsHidden().fixedSize().transition(.identity).id(selectionRevision)
                        Spacer(minLength: 0)
                        Menu {
                            FilterPanelPositionPicker(model: model).pickerStyle(.inline)
                        } label: {
                            Image(systemName: model.filterPanelPosition.symbol)
                                .auralFrame(width: 28, height: 24)
                        }.menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.primary).fixedSize()
                            .accessibilityLabel("Filter panel position")
                            .accessibilityValue(model.filterPanelPosition.label)
                            .help("Place editing controls below or to the right of the graph. Your choice is remembered.")
                        Button { setDetailsVisible(!detailsVisible) } label: {
                            // One chevron turns, like a Finder disclosure triangle. The title
                            // swaps at once, like a menu item; morphing it would redraw text
                            // on the CPU during every frame of the reflow.
                            Label {
                                Text(detailsVisible ? "Hide details" : "Show details")
                            } icon: {
                                Image(systemName: "chevron.right").rotationEffect(.degrees(detailsVisible ? 90 : 0))
                                    .auralAnimation(AuralMotion.quick, value: detailsVisible)
                            }.labelStyle(PanelDisclosureLabelStyle(iconOnly: sidePanel))
                        }.buttonStyle(AuralButtonStyle())
                            .accessibilityLabel(detailsVisible ? "Hide details" : "Show details")
                            .help("Show or hide editing controls. Your current sound stays active.")
                    }
                    .auralPadding(.horizontal, 12).auralPadding(.vertical, 8)
                    .auralRelocation(sidePanel, hidden: controlsFaded)
                    let inspectorHeight: CGFloat = detailsShown ? (page == .stereo ? 230 : (filterDisplay == .selected ? 146 : 206)) : 0
                    let editorsActive = detailsShown && detailsVisible && page == .equalizer
                    GeometryReader { inspector in
                        let height = sidePanel ? max(230, inspector.size.height / model.interfaceZoom.scale) : inspectorHeight
                        ScrollView {
                            ZStack(alignment: .topLeading) {
                                FilterRack(model: model, submissions: submissions, selectedBand: Binding(get: { selectedBand }, set: selectBand), display: $filterDisplay,
                                           expanded: sidePanel, compactRows: inspector.size.width / model.interfaceZoom.scale < 520)
                                    .auralFrame(height: sidePanel ? height : (filterDisplay == .selected ? 146 : 206))
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
                            .auralFrame(height: height, alignment: .top)
                        }.scrollIndicators(.visible).clipped()
                    }
                    .frame(minHeight: detailsShown ? 40 : 0, idealHeight: inspectorHeight * model.interfaceZoom.scale,
                           maxHeight: sidePanel ? .infinity : inspectorHeight * model.interfaceZoom.scale, alignment: .top)
                    .auralPadding([.horizontal, .bottom], detailsShown ? 12 : 0).auralPadding(.top, detailsShown ? 10 : 0)
                    // Separates the tabs from what they show, and leaves with the details.
                    .overlay(alignment: .top) { if detailsShown { Divider() } }
                    .auralRelocation(placement, hidden: inspectorFaded)
                }.auralPadding(20)
            }.clipped()
                .auralAnimation(value: workspaceMotion)
                .onAppear {
                    shownPlacement = targetPlacement
                    inspectorFaded = !targetPlacement.visible
                }
                .onChange(of: targetPlacement) { _, target in movePlacement(to: target) }
        }.background(AuralStyle.background)
    }

    private func workspaceActions(compact: Bool) -> some View {
        let layout = compact ? AnyLayout(HStackLayout(spacing: 16 * interfaceScale)) : AnyLayout(VStackLayout(alignment: .trailing, spacing: 8 * interfaceScale))
        return layout {
            HStack(spacing: 12 * interfaceScale) {
                Button { if submitPendingInput() { openWindow.showAuralWindow("autoeq") } } label: {
                    Label("AutoEQ", systemImage: "headphones")
                }.buttonStyle(.plain).auralFont(size: 12)
                    .help("Search online headphone correction profiles")
                EQFileMenu(model: model, submissions: submissions)
                eqOptions
            }
            if compact { Divider().auralFrame(height: 20) }
            HStack(spacing: 12 * interfaceScale) {
                HStack(spacing: 4 * interfaceScale) {
                    Button { if submitPendingInput() { withAuralAnimation { model.undoProfile() } } } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(AuralButtonStyle()).disabled(!model.canUndo)
                        .accessibilityLabel(model.undoLabel).help("\(model.undoLabel) (⌘Z)")
                    Button { if submitPendingInput() { withAuralAnimation { model.redoProfile() } } } label: { Image(systemName: "arrow.uturn.forward") }
                        .buttonStyle(AuralButtonStyle()).disabled(!model.canRedo)
                        .accessibilityLabel(model.redoLabel).help("\(model.redoLabel) (⇧⌘Z)")
                }
                Divider().auralFrame(height: 20)
                comparisonControls
            }.fixedSize()
        }
    }

    private var comparisonControls: some View {
        HStack(spacing: 7 * interfaceScale) {
            Text("Compare").auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
            Picker("A/B comparison", selection: Binding(get: { model.comparisonSlot }, set: { slot in
                if submitPendingInput() { withAuralAnimation { model.selectComparison(slot) } }
                selectionRevision += 1
            })) {
                Text("A").tag(ComparisonSlot.a)
                Text("B").tag(ComparisonSlot.b)
            }.pickerStyle(.segmented).labelsHidden().auralFrame(width: 76).transition(.identity).id(selectionRevision)
                .help(model.matchLevels
                      ? "Compare two versions of your EQ. Each slot keeps its edits; switching preserves playback. The louder version plays lower so both match."
                      : "Compare two versions of your EQ. Each slot keeps its edits; switching preserves playback.")
        }
    }

    private var eqOptions: some View {
        Menu {
            Button(model.undoLabel) { if submitPendingInput() { withAuralAnimation { model.undoProfile() } } }.disabled(!model.canUndo)
            Button(model.redoLabel) { if submitPendingInput() { withAuralAnimation { model.redoProfile() } } }.disabled(!model.canRedo)
            Divider()
            Button("Copy current to other comparison slot") { if submitPendingInput() { withAuralAnimation { model.copyComparisonToOther() } } }
            Button("Reset both comparisons to current EQ") { if submitPendingInput() { withAuralAnimation { model.captureComparison() } } }
            Divider()
            Button("Edit as a draft…") { if submitPendingInput() { showFilterEditor = true } }
            Button("Copy EQ") { if submitPendingInput() { model.copyEQ() } }
            Button("Paste EQ") { if submitPendingInput() { withAuralAnimation { model.pasteEQ() } } }
            Button("Export EQ…") { if submitPendingInput() { model.exportEQ() } }
        } label: { Image(systemName: "ellipsis").auralFrame(width: 28, height: 24).contentShape(Rectangle()) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.primary).auralFrame(width: 28)
            .accessibilityLabel("EQ options").help("Comparison actions, draft editing, and clipboard")
    }

    /// One bar for the end of the signal path, in processing order: the preamp that
    /// sets headroom, the tilt after the filters, loudness compensation, then the level
    /// leaving the EQ and the protection limiting it. The sample rate already shows under the graph.
    /// When one row doesn't fit, loudness goes under tilt and protection under the level.
    private func footer(compact: Bool) -> some View {
        let tone = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5 * interfaceScale))
                           : AnyLayout(HStackLayout(spacing: 14 * interfaceScale))
        return HStack(spacing: 14 * interfaceScale) {
            PreampControls(model: model, submissions: submissions, compact: true)
            Divider().auralFrame(height: compact ? 36 : 18)
            tone {
                TiltControls(model: model, submissions: submissions)
                if !compact { Divider().auralFrame(height: 18) }
                LoudnessControls(model: model)
            }
            Divider().auralFrame(height: compact ? 36 : 18)
            StudioMeter(meter: model.meter, running: model.running,
                        protectionEnabled: Binding(get: { model.peakProtectionEnabled }, set: model.setPeakProtection),
                        compact: true, inline: !compact)
        }
        .auralFrame(maxWidth: .infinity, alignment: .leading)
        .help("Audio passes through preamp, filters and tilt, loudness compensation, stereo and delay, then optional peak protection. Bypass skips EQ and stereo effects; peak protection follows its On/Off switch. Stop releases the audio connection. Closing the window keeps EQ in the menu bar.")
        .auralPadding(.horizontal, 20).auralPadding(.vertical, 8)
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

private struct PanelDisclosureLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.icon
            if !iconOnly { configuration.title }
        }
    }
}

private enum StudioPage { case equalizer, stereo }

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
struct AuralWorkspaceLayout: Layout {
    let availableHeight: CGFloat
    let minimumInspectorHeight: CGFloat
    var sidePanelWidth: CGFloat? = nil
    var scale: CGFloat = 1
    private var spacing: CGFloat { 10 * scale }
    /// Between the curve and the inspector card, in either placement.
    private var surfaceGap: CGFloat { 20 * scale }

    static func sidePanelWidth(in width: CGFloat, scale: CGFloat) -> CGFloat {
        min(max(544 * scale, width * 0.43), width - 260 * scale - 20 * scale)
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        precondition(subviews.count == 6, "Workspace layout requires toolbar, notices, curve, card, tabs, and inspector")
        func height(_ index: Int, width: CGFloat) -> CGFloat {
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        let toolbar = height(0, width: width)
        let notices = height(1, width: width)
        let top = toolbar + notices + spacing * 2
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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(frame.size))
        }
    }
}
