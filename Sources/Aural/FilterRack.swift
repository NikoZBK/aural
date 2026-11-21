import SwiftUI

struct FilterRackLayout: Equatable {
    static let headerSpacing: CGFloat = 8
    static let editorSpacing: CGFloat = 10

    let compactRows: Bool
    let stackedHeader: Bool

    init(width: CGFloat = .infinity, graphic: Bool = false) {
        compactRows = width < 520
        stackedHeader = width < (graphic ? 650 : 550)
    }

    func editorHeight(for display: FilterDisplay) -> CGFloat {
        switch display {
        case .selected: return compactRows ? 124 : 108
        case .rows: return 168
        case .faders: return 300
        }
    }

    func inspectorHeight(for display: FilterDisplay) -> CGFloat {
        let controlsHeight = stackedHeader ? 2 * AuralStyle.controlHeight + Self.headerSpacing : AuralStyle.controlHeight
        return controlsHeight + Self.editorSpacing + editorHeight(for: display)
    }
}

struct FilterRack: View {
    @Environment(\.auralPalette) private var palette
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    @ObservedObject var submissions: PrecisionSubmissionCoordinator
    @Binding var selectedBand: Int
    @Binding var display: FilterDisplay
    var expanded = false
    var layout = FilterRackLayout()
    var active = true
    @State private var selectionRevision = 0
    private var count: Int { model.profile.filters?.count ?? 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: FilterRackLayout.editorSpacing * interfaceScale) {
            AuralEquatableContent(key: FilterHeaderKey(display: display, count: count, slots: model.profile.filters?.slots ?? count,
                                                       graphic: model.profile.filters == nil, stacked: layout.stackedHeader,
                                                       scale: interfaceScale, revision: selectionRevision)) {
                let headerLayout = layout.stackedHeader
                    ? AnyLayout(VStackLayout(alignment: .trailing, spacing: FilterRackLayout.headerSpacing * interfaceScale))
                    : AnyLayout(HStackLayout(spacing: 10 * interfaceScale))
                headerLayout {
                    HStack(spacing: 10 * interfaceScale) {
                        AuralSegmented(title: "Filter view", selection: Binding(get: { display }, set: { next in
                            guard finishNumericEdit() else { selectionRevision += 1; return }
                            if next == .rows && model.profile.filters == nil { model.editGraphicAsFilters() }
                            guard model.error == nil else { selectionRevision += 1; return }
                            display = next
                        }), options: [(FilterDisplay.selected, "Selected"), (FilterDisplay.rows, "All rows"), (FilterDisplay.faders, "Faders")])
                            .auralFrame(width: 218).transition(.identity).id(selectionRevision)
                            .help("Edit one selected filter, all filter rows, or gain faders. All rows makes graphic frequencies and Q editable.")
                        if layout.stackedHeader { Spacer(minLength: 0) }
                        bandCount.fixedSize()
                    }
                    HStack(spacing: (layout.stackedHeader ? 5 : 8) * interfaceScale) {
                        bandActions
                    }.frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                }
            }.equatable()
            // Retain the native editors across display changes. Hidden editors are
            // disabled and excluded from pointer and accessibility navigation.
            // Their value boundary also stops document edits from rebuilding an
            // invisible picker, row list, or bank of native fields.
            ZStack(alignment: .topLeading) {
                AuralEquatableContent(key: editorKey(.faders)) {
                    EQBarsContent(model: model, presentation: EQBarsPresentation(model: model), submissions: submissions, compact: true, showParameters: true,
                                  active: active && display == .faders,
                                  moveFilter: { moveFilter(at: $0, by: $1) })
                }.equatable()
                    .opacity(display == .faders ? 1 : 0)
                    .allowsHitTesting(display == .faders)
                    .accessibilityElement(children: display == .faders ? .contain : .ignore)
                    .accessibilityHidden(display != .faders)
                    .disabled(display != .faders)
                if let filters = model.profile.filters {
                    AuralEquatableContent(key: editorKey(.rows)) { rows(filters) }.equatable()
                        .opacity(display == .rows ? 1 : 0)
                        .allowsHitTesting(display == .rows)
                        .accessibilityElement(children: display == .rows ? .contain : .ignore)
                        .accessibilityHidden(display != .rows)
                        .disabled(display != .rows)
                }
                AuralEquatableContent(key: editorKey(.selected)) { selectedInspector }.equatable()
                    .opacity(display == .selected ? 1 : 0)
                    .allowsHitTesting(display == .selected)
                    .accessibilityElement(children: display == .selected ? .contain : .ignore)
                    .accessibilityHidden(display != .selected)
                    .disabled(display != .selected)
            }
            .auralFrame(height: expanded ? nil : layout.editorHeight(for: display), alignment: .top)
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: expanded ? .infinity : nil, alignment: .topLeading)
            .clipped()
            .onChange(of: display) { _, _ in model.endProfileGesture() }

        }.onDisappear { model.endProfileGesture() }
    }

    private func editorKey(_ editor: FilterDisplay) -> RetainedFilterEditorKey {
        let presentation = active && display == editor
            ? FilterEditorPresentation(profile: model.profile, revision: model.editRevision, selected: selectedBand,
                                       selectionRevision: selectionRevision, soloed: model.soloBand, canSolo: model.running && !model.bypass)
            : nil
        return RetainedFilterEditorKey(model: ObjectIdentifier(model), submissions: ObjectIdentifier(submissions),
                                       expanded: expanded, compactRows: layout.compactRows, scale: interfaceScale, presentation: presentation)
    }

    private var bandCount: some View {
        AuralSectionLabel(title: "\(count) bands", systemImage: "slider.horizontal.3")
    }

    @ViewBuilder private var bandActions: some View {
        if display == .faders && model.profile.filters == nil {
            Button("Edit parameters…") { if finishNumericEdit() { model.editGraphicAsFilters() } }
                .buttonStyle(AuralButtonStyle(compact: layout.stackedHeader)).fixedSize()
                .help("Make the graphic bands' frequencies and Q editable, preserving their response.")
        }
        Menu("EQ actions") {
            Menu("New EQ") {
                Button("New flat 10-band EQ") { if finishNumericEdit() { withAuralAnimation { model.useGraphicTemplate(bands: 10) } } }.help("Replace the current filters with a flat 10-band graphic EQ.")
                Button("New flat 31-band EQ") { if finishNumericEdit() { withAuralAnimation { model.useGraphicTemplate(bands: 31) } } }.help("Replace the current filters with a flat 31-band EQ.")
            }.help("Replace the current EQ with a flat 10-band or 31-band layout.")
            Divider()
            Button("Gains +1 dB") { if finishNumericEdit() { withAuralAnimation { model.transformGains(scale: 1, offset: 1) } } }.help("Raise every adjustable band gain by 1 dB.")
            Button("Gains −1 dB") { if finishNumericEdit() { withAuralAnimation { model.transformGains(scale: 1, offset: -1) } } }.help("Lower every adjustable band gain by 1 dB.")
            Button("Scale gains to 50%") { if finishNumericEdit() { withAuralAnimation { model.transformGains(scale: 0.5, offset: 0) } } }.help("Halve every adjustable band boost and cut.")
            Button("Invert gains") { if finishNumericEdit() { withAuralAnimation { model.transformGains(scale: -1, offset: 0) } } }.help("Turn every adjustable boost into a cut and every cut into a boost.")
            Divider()
            Button("Shift up ⅓ octave") { if finishNumericEdit() { withAuralAnimation { model.shiftFrequencies(octaves: 1.0 / 3) } } }.help("Raise all filter frequencies by one third of an octave.")
            Button("Shift down ⅓ octave") { if finishNumericEdit() { withAuralAnimation { model.shiftFrequencies(octaves: -1.0 / 3) } } }.help("Lower all filter frequencies by one third of an octave.")
        }.auralMenuButton().fixedSize().help("Adjust all bands together. Undo restores your previous EQ.")
        Button("Reset EQ") { if finishNumericEdit() { withAuralAnimation { model.resetEQ() } } }
            .buttonStyle(AuralButtonStyle(compact: layout.stackedHeader)).fixedSize()
            .help("Set band gains, tilt, and preamp to 0 dB. Keep frequencies, Q, filter types, channels, and stereo settings.")
        Button { if finishNumericEdit() { withAuralAnimation { model.addFilter() } } } label: { Image(systemName: "plus") }
            .buttonStyle(AuralButtonStyle(compact: layout.stackedHeader)).fixedSize()
            .disabled((model.profile.filters?.slots ?? count) >= Profile.maxFilters).help("Add a parametric filter").accessibilityLabel("Add filter")
    }

    private var selectedInspector: some View {
        VStack(alignment: .leading, spacing: 12 * interfaceScale) {
            let bands = EQBarBand.bands(in: model.profile)
            AuralEquatableContent(key: SelectedBandPickerKey(choices: bands.map { BandChoice(index: $0.index, frequency: $0.frequency, enabled: $0.filter?.enabled ?? true) },
                                                              selected: selectedBand, revision: selectionRevision,
                                                              soloed: model.soloBand == selectedBand, canSolo: model.running && !model.bypass,
                                                              scale: interfaceScale)) {
            HStack(spacing: 8 * interfaceScale) {
                Text("Selected filter").auralFont(size: 12).fixedSize().accessibilityHidden(true)
                AuralPicker(title: "Selected filter", value: bands.first { $0.index == selectedBand }.map(Self.bandTitle) ?? "",
                            selection: Binding(get: { selectedBand }, set: { index in
                    if finishNumericEdit() {
                        model.endProfileGesture()
                        selectedBand = index
                    }
                    selectionRevision += 1
                })) {
                    ForEach(bands, id: \.index) { band in Text(Self.bandTitle(band)).tag(band.index) }
                }.auralFrame(minWidth: 0, idealWidth: 170, maxWidth: 170)
                    .help("Choose the filter shown in the inspector. Its settings appear below.")
                Spacer(minLength: 0)
                soloToggle.fixedSize()
            }.transition(.identity).id(selectionRevision)
            }.equatable()
            if let filters = model.profile.filters, filters.indices.contains(selectedBand) {
                VStack(spacing: 0) {
                    columnHeader
                    // Switching filters is instant, like an inspector; a crossfade would
                    // briefly stack two rows.
                    FilterRow(model: model, submissions: submissions, filter: filters[selectedBand], index: selectedBand, compact: layout.compactRows,
                              move: { moveFilter(at: selectedBand, by: $0) })
                        .transition(.identity).id(selectedBand)
                }
            } else if model.profile.gains.indices.contains(selectedBand) {
                HStack(spacing: 12 * interfaceScale) {
                    Text("Gain").auralFont(size: 12)
                    PrecisionField(value: model.profile.gains[selectedBand], range: -12...12, label: "Band \(selectedBand + 1) gain in decibels", revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model, selectedBand] value in
                        model.endProfileGesture(); model.setBandGain(at: selectedBand, to: value)
                    }.auralFrame(width: 80).transition(.identity).id(selectedBand)
                    Text("dB").auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
                    Spacer()
                    Button("Edit filter parameters…") { if finishNumericEdit() { model.editGraphicAsFilters() } }
                        .buttonStyle(AuralButtonStyle()).help("Convert these graphic bands to editable filters, preserving their response.")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var soloToggle: some View {
        let available = model.running && !model.bypass
        return Toggle(isOn: Binding(get: { model.soloBand == selectedBand }, set: { on in
            if finishNumericEdit() { withAuralAnimation { model.setSolo(on ? selectedBand : nil) } }
        })) { Label("Solo", systemImage: "headphones") }
            .toggleStyle(AuralGelToggleStyle()).auralControlSize(.small).disabled(!available)
            .help(available ? "Play only the part of the spectrum this band acts on, to find it by ear. Edits apply while soloed."
                            : "Start EQ and turn off Bypass to solo a band.")
            .accessibilityLabel("Solo band \(selectedBand + 1)")
    }

    private static func bandTitle(_ band: EQBarBand) -> String {
        String(format: "%d · %.0f Hz", band.index + 1, band.frequency) + (band.filter?.enabled == false ? " · Off" : "")
    }

    private func finishNumericEdit() -> Bool {
        switch submissions.submitActive() {
        case .unchanged: return true
        case .submitted: return model.error == nil
        case .rejected: return false
        }
    }

    func moveFilter(at index: Int, by offset: Int) {
        guard finishNumericEdit() else { return }
        withAuralAnimation {
            guard model.moveFilter(at: index, by: offset) else { return }
            let destination = index + offset
            if selectedBand == index { selectedBand = destination }
            else if selectedBand == destination { selectedBand = index }
        }
    }

    private func rows(_ filters: [ImportedFilter]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(filters.indices, id: \.self) { index in
                        FilterRow(model: model, submissions: submissions, filter: filters[index], index: index, compact: layout.compactRows,
                                  move: { moveFilter(at: index, by: $0) })
                    }
                } header: {
                    columnHeader
                }
            }
        }.background(palette.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AuralStyle.border))
            .scrollDisabled(display != .rows)
            .scrollIndicators(display == .rows ? .visible : .hidden)
    }

    // Sharing the scroll viewport also shares its scrollbar inset. A separate
    // header above the scroll view would place the flexible column too far right.
    private var columnHeader: some View {
        VStack(spacing: 0) {
            FilterColumns(height: 26 * interfaceScale, scale: interfaceScale) {
                Text("On").auralFrame(width: 24)
                Text("Filter").auralPadding(.leading, 32).auralFrame(maxWidth: .infinity, alignment: .leading)
                Text("Channel").auralFrame(width: 60)
                Text("Hz").auralFrame(width: 79)
                Text("dB").auralFrame(width: 66)
                Text("Q").auralFrame(width: 58)
                Color.clear.auralFrame(width: 22, height: 1)
            }.auralFont(size: 10, weight: .medium).foregroundStyle(AuralStyle.secondary)
                .auralPadding(.horizontal, 10).auralFrame(height: 26).auralFrame(maxWidth: .infinity)
            Divider().overlay(AuralStyle.border)
        }.background(palette.surface).frame(height: layout.compactRows ? 0 : nil).clipped().accessibilityHidden(true)
    }
}

private struct FilterEditorPresentation: Equatable {
    let profile: Profile
    let revision: Int
    let selected: Int
    let selectionRevision: Int
    let soloed: Int?
    let canSolo: Bool
}

private struct RetainedFilterEditorKey: Equatable {
    let model: ObjectIdentifier
    let submissions: ObjectIdentifier
    let expanded: Bool
    let compactRows: Bool
    let scale: CGFloat
    let presentation: FilterEditorPresentation?
}

private struct FilterHeaderKey: Equatable {
    let display: FilterDisplay
    let count: Int
    let slots: Int
    let graphic: Bool
    let stacked: Bool
    let scale: CGFloat
    let revision: Int
}

private struct BandChoice: Equatable {
    let index: Int
    let frequency: Double
    let enabled: Bool
}

private struct SelectedBandPickerKey: Equatable {
    let choices: [BandChoice]
    let selected: Int
    let revision: Int
    let soloed: Bool
    let canSolo: Bool
    let scale: CGFloat
}

private struct FilterRow: View {
    let model: Model
    let submissions: PrecisionSubmissionCoordinator
    let filter: ImportedFilter
    let index: Int
    var compact = false
    let move: (Int) -> Void
    private let actions: FilterActionsState
    @MainActor init(model: Model, submissions: PrecisionSubmissionCoordinator, filter: ImportedFilter, index: Int,
                   compact: Bool = false, move: @escaping (Int) -> Void) {
        self.model = model; self.submissions = submissions; self.filter = filter; self.index = index
        self.compact = compact; self.move = move
        actions = FilterActionsState(model: model, index: index, filter: filter)
    }

    var body: some View {
        FilterRowContent(model: model, submissions: submissions, filter: filter, index: index, compact: compact,
                         actions: actions, move: move).equatable()
    }
}

private struct FilterRowContent: View, Equatable {
    @Environment(\.auralPalette) private var palette
    @Environment(\.auralInterfaceScale) private var interfaceScale
    let model: Model
    let submissions: PrecisionSubmissionCoordinator
    let filter: ImportedFilter
    let index: Int
    var compact = false
    let actions: FilterActionsState
    let move: (Int) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.submissions === rhs.submissions && lhs.filter == rhs.filter && lhs.index == rhs.index &&
            lhs.compact == rhs.compact && lhs.actions == rhs.actions
    }
    private var number: Int { index + 1 }
    private var currentFilter: ImportedFilter {
        guard let filters = model.profile.filters, filters.indices.contains(index) else { return filter }
        return filters[index]
    }
    private func finishNumericEdit() -> Bool {
        switch submissions.submitActive() {
        case .unchanged: return true
        case .submitted: return model.error == nil
        case .rejected: return false
        }
    }
    private func editFilter(_ edit: (inout ImportedFilter) -> Void) {
        guard finishNumericEdit() else { return }
        FilterParameterEditing.update(model: model, index: index, edit)
    }
    var body: some View {
        FilterColumns(height: (compact ? 78 : 39) * interfaceScale, scale: interfaceScale, compact: compact) {
            Toggle(isOn: Binding(get: { currentFilter.enabled }, set: { enabled in editFilter { $0.enabled = enabled } })) { EmptyView() }
                .toggleStyle(AuralCheckboxStyle()).auralFrame(width: 24)
                .accessibilityLabel("Filter \(number) enabled")
                .help("Enable or bypass filter \(number) without removing its settings.")
            HStack(spacing: 6 * interfaceScale) {
                Group {
                    if actions.soloed {
                        Image(systemName: "headphones").auralFont(size: 10, weight: .semibold).foregroundStyle(AuralStyle.warning)
                            .help("Filter \(number) is soloed")
                    } else {
                        Text(String(format: "%02d", number)).auralFont(size: 9, design: .monospaced).foregroundStyle(AuralStyle.secondary)
                    }
                }.auralFrame(width: 18).accessibilityHidden(true)
                FilterTypeMenu(title: "Filter \(number) type", shape: currentFilter.shape, buttonTitle: currentFilter.shape.name) { shape in
                    editFilter { $0.shape = shape; if !shape.kind.usesGain { $0.gain = 0 } }
                }.auralFrame(maxWidth: compact ? .infinity : 180)
                    .auralFrame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }.auralFrame(maxWidth: .infinity, alignment: .leading)
            Menu(currentFilter.effectiveChannel == .stereo ? "L+R" : currentFilter.effectiveChannel.rawValue) {
                ForEach(ImportedFilter.Channel.allCases, id: \.self) { channel in
                    Button {
                        editFilter { $0.channel = channel == .stereo ? nil : channel }
                    } label: {
                        if currentFilter.effectiveChannel == channel {
                            Label(channel == .stereo ? "L+R" : channel.rawValue, systemImage: "checkmark")
                        } else { Text(channel == .stereo ? "L+R" : channel.rawValue) }
                    }.help("Apply filter \(number) to \(channel.label).")
                }
            }.auralMenuButton(.small).auralFrame(width: 60).accessibilityLabel("Filter \(number) channel")
                .accessibilityValue(currentFilter.effectiveChannel.label)
                .help(AuralHelp.filterChannel(number))
            parameterCell("Hz") {
                PrecisionField(value: filter.frequency, range: 10...22000, label: "Filter \(number) frequency in hertz", decimals: 0, revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model, index] value in
                    FilterParameterEditing.update(model: model, index: index) { $0.frequency = value }
                }
            }
            parameterCell("dB") {
                if filter.kind.usesGain {
                    PrecisionField(value: filter.gain, range: -30...30, label: "Filter \(number) gain in decibels", revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model, index] value in
                        FilterParameterEditing.update(model: model, index: index) { $0.gain = value }
                    }
                } else {
                    Text("—").auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
                        .accessibilityLabel("Filter \(number) has no gain parameter")
                }
            }
            parameterCell("Q") {
                if filter.usesQ {
                    PrecisionField(value: filter.q, range: 0.05...50, label: "Filter \(number) Q", decimals: 3, revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model, index] value in
                        FilterParameterEditing.update(model: model, index: index) { $0.q = value }
                    }
                } else {
                    Text("—").auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
                        .accessibilityLabel("Filter \(number) has a fixed \(filter.slope?.label ?? "6 dB per octave") slope")
                        .help(filter.shape.fixedQHelp)
                }
            }
            FilterActionsMenu(model: model, submissions: submissions, index: index, filter: currentFilter, move: move)
                .auralFrame(width: 22)
        }.auralPadding(.horizontal, 10).auralFrame(height: compact ? 78 : 39)
            .background(index.isMultiple(of: 2) ? Color.clear : palette.elevated.opacity(0.32))
            .accessibilityElement(children: .contain).accessibilityLabel("Filter \(number)")
            .accessibilityValue(actions.soloed ? "Soloed" : "")
    }

    private func parameterCell<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        content().auralFrame(minWidth: 0, maxWidth: .infinity, minHeight: AuralStyle.controlHeight)
            .overlay(alignment: .topLeading) {
                if compact {
                    Text(title).auralFont(size: 9, weight: .medium).foregroundStyle(AuralStyle.secondary)
                        .offset(y: -12 * interfaceScale).accessibilityHidden(true).allowsHitTesting(false)
                }
            }
    }
}

/// All parameter presentations read the current filter after pending input commits.
@MainActor enum FilterParameterEditing {
    static func update(model: Model, index: Int, _ edit: (inout ImportedFilter) -> Void) {
        guard let filters = model.profile.filters, filters.indices.contains(index) else {
            model.error = "The filter layout changed. Try the edit again."
            return
        }
        model.endProfileGesture()
        var next = filters[index]
        edit(&next)
        model.updateFilter(at: index, with: next)
    }
}

/// Exactly the model state that changes a filter menu's labels or availability.
struct FilterActionsState: Equatable {
    let soloed: Bool
    let canSolo: Bool
    let canMoveBack: Bool
    let canMoveForward: Bool
    let canDuplicate: Bool
    let canDelete: Bool
    @MainActor init(model: Model, index: Int, filter: ImportedFilter) {
        soloed = model.soloBand == index
        canSolo = model.running && !model.bypass
        canMoveBack = index > 0
        canMoveForward = index < (model.profile.filters?.count ?? 0) - 1
        canDuplicate = (model.profile.filters?.slots ?? 0) + filter.slots <= Profile.maxFilters
        canDelete = model.profile.filters?.count != 1
    }
}

struct FilterActionsMenu: View {
    let model: Model
    let submissions: PrecisionSubmissionCoordinator
    let index: Int
    let filter: ImportedFilter
    var move: ((Int) -> Void)? = nil
    var horizontal = false
    var includeChannel = false
    private let state: FilterActionsState
    @MainActor init(model: Model, submissions: PrecisionSubmissionCoordinator, index: Int, filter: ImportedFilter,
                   move: ((Int) -> Void)? = nil, horizontal: Bool = false, includeChannel: Bool = false) {
        self.model = model; self.submissions = submissions; self.index = index; self.filter = filter
        self.move = move; self.horizontal = horizontal; self.includeChannel = includeChannel
        state = FilterActionsState(model: model, index: index, filter: filter)
    }
    private var currentFilter: ImportedFilter {
        guard let filters = model.profile.filters, filters.indices.contains(index) else { return filter }
        return filters[index]
    }
    var body: some View {
        Menu {
            if includeChannel {
                Menu("Channel") {
                    ForEach(ImportedFilter.Channel.allCases, id: \.self) { channel in
                        Button {
                            if finishNumericEdit() {
                                FilterParameterEditing.update(model: model, index: index) { $0.channel = channel == .stereo ? nil : channel }
                            }
                        } label: {
                            if currentFilter.effectiveChannel == channel { Label(channel.label, systemImage: "checkmark") }
                            else { Text(channel.label) }
                        }.help("Apply filter \(index + 1) to \(channel.label).")
                    }
                }.help(AuralHelp.filterChannel(index + 1))
                Divider()
            }
            if state.soloed {
                Button("End solo") { if finishNumericEdit() { withAuralAnimation { model.setSolo(nil) } } }.help("Play the whole EQ again.")
            } else {
                Button("Solo") { if finishNumericEdit() { withAuralAnimation { model.setSolo(index) } } }.help("Play only the part of the spectrum this filter acts on. Start EQ and turn off Bypass first.")
                    .disabled(!state.canSolo)
            }
            if let move {
                Divider()
                Button(horizontal ? "Move left" : "Move up") { move(-1) }.disabled(!state.canMoveBack).help("Move this filter one position earlier in the processing order.")
                Button(horizontal ? "Move right" : "Move down") { move(1) }.disabled(!state.canMoveForward).help("Move this filter one position later in the processing order.")
            }
            Divider()
            Button("Duplicate") { if finishNumericEdit() { withAuralAnimation { model.duplicateFilter(at: index) } } }.help("Create a copy of this filter in the EQ.")
                .disabled(!state.canDuplicate)
            Button("Delete filter", role: .destructive) { if finishNumericEdit() { withAuralAnimation { model.deleteFilter(at: index) } } }.help("Remove this filter from the EQ. Undo restores it.")
                .disabled(!state.canDelete)
        } label: { Image(systemName: "ellipsis").auralFrame(width: 22, height: 22) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.primary)
        .accessibilityLabel("Filter \(index + 1) actions")
        .help("Solo, reorder, duplicate, or delete this filter. Reordering ends Solo and can change mixed left/right and mid/side processing.")
    }
    private func finishNumericEdit() -> Bool {
        switch submissions.submitActive() {
        case .unchanged: return true
        case .submitted: return model.error == nil
        case .rejected: return false
        }
    }
}

/// The filter type menu: each kind, with low- and high-pass slopes in submenus.
struct FilterTypeMenu: View {
    let title: String
    let shape: FilterShape
    let buttonTitle: String
    let choose: (FilterShape) -> Void
    var body: some View {
        Menu(buttonTitle) {
            ForEach(ImportedFilter.Kind.allCases, id: \.self) { kind in
                if kind.hasSlopes {
                    Menu {
                        ForEach(FilterShape.slopes(for: kind), id: \.self) { item($0, title: $0.slope?.label ?? "12 dB/oct with Q") }
                    } label: { checked(shape.kind == kind, title: kind.name) }
                        .help("Choose the slope for a \(kind.name) filter.")
                } else {
                    item(FilterShape(kind: kind), title: kind.name)
                }
            }
        }.auralMenuButton(.small).help("\(title): \(shape.label). Choose the filter shape and, for pass filters, its slope.").accessibilityLabel(title).accessibilityValue(shape.label)
    }
    private func item(_ value: FilterShape, title: String) -> some View {
        Button { choose(value) } label: { checked(shape == value, title: title) }
            .help("Use \(value.label) for this filter.")
    }
    @ViewBuilder private func checked(_ on: Bool, title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

struct FilterColumns: AuralContainerLayout {
    let height: CGFloat
    let scale: CGFloat
    var compact = false
    private let spacing: CGFloat = 7
    private let fixedWidths: [CGFloat] = [24, 0, 60, 79, 66, 58, 22]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 439 * scale, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        precondition(subviews.count == fixedWidths.count, "Filter columns require seven cells.")
        if compact {
            let topY = bounds.minY + 17 * scale
            let typeWidth = max(0, bounds.width - 24 * scale - 60 * scale - 22 * scale - 21 * scale)
            let topCells: [(Int, CGFloat, CGFloat)] = [
                (0, 0, 24 * scale), (1, 31 * scale, typeWidth),
                (2, bounds.width - 89 * scale, 60 * scale), (6, bounds.width - 22 * scale, 22 * scale)
            ]
            for (index, x, width) in topCells {
                subviews[index].place(at: CGPoint(x: bounds.minX + x + width / 2, y: topY), anchor: .center,
                                      proposal: ProposedViewSize(width: width, height: 30 * scale))
            }
            let gap = spacing * scale
            let width = max(0, (bounds.width - 2 * gap) / 3)
            var x = bounds.minX
            for index in 3...5 {
                subviews[index].place(at: CGPoint(x: x + width / 2, y: bounds.minY + 57 * scale), anchor: .center,
                                      proposal: ProposedViewSize(width: width, height: AuralStyle.controlHeight * scale))
                x += width + gap
            }
            return
        }
        let widths = fixedWidths.map { $0 * scale }
        let gap = spacing * scale
        let typeWidth = max(0, bounds.width - widths.reduce(0, +) - gap * 6)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = index == 1 ? typeWidth : widths[index]
            subview.place(at: CGPoint(x: x + width / 2, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(width: width, height: height))
            x += width + gap
        }
    }
}

enum FilterDisplay { case selected, rows, faders }
