import SwiftUI

struct FilterRack: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    @ObservedObject var submissions: PrecisionSubmissionCoordinator
    @Binding var selectedBand: Int
    @Binding var display: FilterDisplay
    var expanded = false
    var compactRows = false
    @State private var selectionRevision = 0
    private var count: Int { model.profile.filters?.count ?? 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * interfaceScale) {
            let headerLayout = expanded ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10 * interfaceScale)) : AnyLayout(HStackLayout(spacing: 10 * interfaceScale))
            headerLayout {
                Picker("Filter view", selection: Binding(get: { display }, set: { next in
                    guard finishNumericEdit() else { selectionRevision += 1; return }
                    if next == .rows && model.profile.filters == nil { model.editGraphicAsFilters() }
                    guard model.error == nil else { selectionRevision += 1; return }
                    display = next
                })) {
                    Text("Selected").tag(FilterDisplay.selected)
                    Text("All rows").tag(FilterDisplay.rows)
                    Text("Faders").tag(FilterDisplay.faders)
                }.pickerStyle(.segmented).labelsHidden().auralFrame(width: expanded ? nil : 218).transition(.identity).id(selectionRevision)
                // A narrow side panel at large zoom keeps the band count on one line
                // by moving it above the actions.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8 * interfaceScale) { bandCount; Spacer(minLength: 0); bandActions }
                    VStack(alignment: .leading, spacing: 8 * interfaceScale) {
                        bandCount
                        HStack(spacing: 8 * interfaceScale) { bandActions }
                    }
                }
            }
            // Retain the native editors across display changes. Hidden editors are
            // disabled and excluded from pointer and accessibility navigation.
            ZStack(alignment: .topLeading) {
                EQBars(model: model, submissions: submissions, compact: true)
                    .background(AuralStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                    .opacity(display == .faders ? 1 : 0)
                    .allowsHitTesting(display == .faders)
                    .accessibilityElement(children: display == .faders ? .contain : .ignore)
                    .accessibilityHidden(display != .faders)
                    .disabled(display != .faders)
                if let filters = model.profile.filters {
                    rows(filters)
                        .opacity(display == .rows ? 1 : 0)
                        .allowsHitTesting(display == .rows)
                        .accessibilityElement(children: display == .rows ? .contain : .ignore)
                        .accessibilityHidden(display != .rows)
                        .disabled(display != .rows)
                }
                selectedInspector
                    .opacity(display == .selected ? 1 : 0)
                    .allowsHitTesting(display == .selected)
                    .accessibilityElement(children: display == .selected ? .contain : .ignore)
                    .accessibilityHidden(display != .selected)
                    .disabled(display != .selected)
            }
            .auralFrame(height: expanded ? nil : 168, alignment: .top)
            .auralFrame(height: expanded ? nil : (display == .selected ? 108 : 168), alignment: .top)
            .frame(maxHeight: expanded ? .infinity : nil, alignment: .top).clipped()
            .onChange(of: display) { _, _ in model.endProfileGesture() }

        }.onDisappear { model.endProfileGesture() }
    }

    private var bandCount: some View {
        AuralSectionLabel(title: "\(count) bands", systemImage: "slider.horizontal.3")
    }

    @ViewBuilder private var bandActions: some View {
        Menu("EQ actions") {
            Menu("New EQ") {
                Button("New flat 10-band EQ") { if finishNumericEdit() { withAuralAnimation { model.useGraphicTemplate(bands: 10) } } }
                Button("New flat 31-band EQ") { if finishNumericEdit() { withAuralAnimation { model.useGraphicTemplate(bands: 31) } } }
            }
            Divider()
            Button("Gains +1 dB") { if finishNumericEdit() { withAuralAnimation { model.transformGains(scale: 1, offset: 1) } } }
            Button("Gains −1 dB") { if finishNumericEdit() { withAuralAnimation { model.transformGains(scale: 1, offset: -1) } } }
            Button("Scale gains to 50%") { if finishNumericEdit() { withAuralAnimation { model.transformGains(scale: 0.5, offset: 0) } } }
            Button("Invert gains") { if finishNumericEdit() { withAuralAnimation { model.transformGains(scale: -1, offset: 0) } } }
            Divider()
            Button("Shift up ⅓ octave") { if finishNumericEdit() { withAuralAnimation { model.shiftFrequencies(octaves: 1.0 / 3) } } }
            Button("Shift down ⅓ octave") { if finishNumericEdit() { withAuralAnimation { model.shiftFrequencies(octaves: -1.0 / 3) } } }
        }.auralMenuButton().fixedSize().help("Adjust all bands together. Undo restores your previous EQ.")
        Button("Reset EQ") { if finishNumericEdit() { withAuralAnimation { model.resetEQ() } } }
            .buttonStyle(AuralButtonStyle()).help("Set band gains, tilt, and preamp to 0 dB. Keep frequencies, Q, filter types, channels, and stereo settings.")
        Button { if finishNumericEdit() { withAuralAnimation { model.addFilter() } } } label: { Image(systemName: "plus") }
            .buttonStyle(AuralButtonStyle()).disabled(count >= Profile.maxFilters).help("Add a parametric filter").accessibilityLabel("Add filter")
    }

    private var selectedInspector: some View {
        VStack(alignment: .leading, spacing: 12 * interfaceScale) {
            let bands = EQBarBand.bands(in: model.profile)
            HStack(spacing: 8 * interfaceScale) {
                Text("Selected filter").auralFont(size: 12).accessibilityHidden(true)
                AuralPicker(title: "Selected filter", value: bands.first { $0.index == selectedBand }.map(Self.bandTitle) ?? "",
                            selection: Binding(get: { selectedBand }, set: { index in
                    selectedBand = index
                    selectionRevision += 1
                })) {
                    ForEach(bands, id: \.index) { band in Text(Self.bandTitle(band)).tag(band.index) }
                }.auralFrame(width: 170)
            }.transition(.identity).id(selectionRevision)
            if let filters = model.profile.filters, filters.indices.contains(selectedBand) {
                VStack(spacing: 0) {
                    columnHeader
                    // Switching filters is instant, like an inspector; a crossfade would
                    // briefly stack two rows.
                    FilterRow(model: model, submissions: submissions, filter: filters[selectedBand], index: selectedBand, compact: compactRows)
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

    private func rows(_ filters: [ImportedFilter]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(filters.indices, id: \.self) { index in
                        FilterRow(model: model, submissions: submissions, filter: filters[index], index: index, compact: compactRows)
                    }
                } header: {
                    columnHeader
                }
            }
        }.background(AuralStyle.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AuralStyle.border))
            .scrollIndicators(.visible)
    }

    // Sharing the scroll viewport also shares its scrollbar inset. A separate
    // header above the scroll view would place the flexible column too far right.
    private var columnHeader: some View {
        VStack(spacing: 0) {
            FilterColumns(height: 26 * interfaceScale, scale: interfaceScale) {
                Text("On").auralFrame(width: 24)
                Text("Filter").auralFrame(maxWidth: .infinity, alignment: .leading)
                Text("Channel").auralFrame(width: 60)
                Text("Hz").auralFrame(width: 79)
                Text("dB").auralFrame(width: 66)
                Text("Q").auralFrame(width: 58)
                Color.clear.auralFrame(width: 22, height: 1)
            }.auralFont(size: 10, weight: .medium).foregroundStyle(AuralStyle.secondary)
                .auralPadding(.horizontal, 10).auralFrame(height: 26).auralFrame(maxWidth: .infinity)
            Divider().overlay(AuralStyle.border)
        }.background(AuralStyle.surface).frame(height: compactRows ? 0 : nil).clipped().accessibilityHidden(true)
    }
}

private struct FilterRow: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    let filter: ImportedFilter
    let index: Int
    var compact = false
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
        Self.updateFilter(model: model, index: index, edit)
    }
    private static func updateFilter(model: Model, index: Int, _ edit: (inout ImportedFilter) -> Void) {
        guard let filters = model.profile.filters, filters.indices.contains(index) else {
            model.error = "The filter layout changed. Try the edit again."
            return
        }
        model.endProfileGesture()
        var next = filters[index]
        edit(&next)
        model.updateFilter(at: index, with: next)
    }
    var body: some View {
        FilterColumns(height: (compact ? 78 : 39) * interfaceScale, scale: interfaceScale, compact: compact) {
            Toggle("Filter \(number) enabled", isOn: Binding(get: { currentFilter.enabled }, set: { enabled in editFilter { $0.enabled = enabled } }))
                .labelsHidden().toggleStyle(.checkbox).auralFrame(width: 24)
            HStack(spacing: 6 * interfaceScale) {
                Text(String(format: "%02d", number)).auralFont(size: 9, design: .monospaced)
                    .foregroundStyle(AuralStyle.secondary).auralFrame(width: 18).accessibilityHidden(true)
                Menu(currentFilter.kind.label.components(separatedBy: " · ")[0]) {
                    ForEach(ImportedFilter.Kind.allCases, id: \.self) { kind in
                        Button {
                            editFilter { $0.kind = kind; if !kind.usesGain { $0.gain = 0 } }
                        } label: {
                            if currentFilter.kind == kind {
                                Label(kind.label.components(separatedBy: " · ")[0], systemImage: "checkmark")
                            } else { Text(kind.label.components(separatedBy: " · ")[0]) }
                        }
                    }
                }.auralMenuButton(.small).fixedSize().accessibilityLabel("Filter \(number) type")
                    .accessibilityValue(currentFilter.kind.label)
            }.auralFrame(maxWidth: .infinity, alignment: .leading)
            Menu(currentFilter.effectiveChannel == .stereo ? "L+R" : currentFilter.effectiveChannel.rawValue) {
                ForEach(ImportedFilter.Channel.allCases, id: \.self) { channel in
                    Button {
                        editFilter { $0.channel = channel == .stereo ? nil : channel }
                    } label: {
                        if currentFilter.effectiveChannel == channel {
                            Label(channel == .stereo ? "L+R" : channel.rawValue, systemImage: "checkmark")
                        } else { Text(channel == .stereo ? "L+R" : channel.rawValue) }
                    }
                }
            }.auralMenuButton(.small).auralFrame(width: 60).accessibilityLabel("Filter \(number) channel")
                .accessibilityValue(currentFilter.effectiveChannel.label)
            PrecisionField(value: filter.frequency, range: 10...22000, label: "Filter \(number) frequency in hertz", decimals: 0, revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model, index] value in
                Self.updateFilter(model: model, index: index) { $0.frequency = value }
            }.auralFrame(width: 79).overlay(alignment: .topLeading) { numericLabel("Hz") }
            if filter.kind.usesGain {
                PrecisionField(value: filter.gain, range: -30...30, label: "Filter \(number) gain in decibels", revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model, index] value in
                    Self.updateFilter(model: model, index: index) { $0.gain = value }
                }.auralFrame(width: 66).overlay(alignment: .topLeading) { numericLabel("dB") }
            } else {
                Text("—").auralFont(size: 11).foregroundStyle(AuralStyle.secondary).auralFrame(width: 66)
                    .accessibilityLabel("Filter \(number) has no gain parameter")
                    .overlay(alignment: .topLeading) { numericLabel("dB") }
            }
            if filter.kind.usesQ {
                PrecisionField(value: filter.q, range: 0.05...50, label: "Filter \(number) Q", decimals: 3, revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model, index] value in
                    Self.updateFilter(model: model, index: index) { $0.q = value }
                }.auralFrame(width: 58).overlay(alignment: .topLeading) { numericLabel("Q") }
            } else {
                Text("—").auralFont(size: 11).foregroundStyle(AuralStyle.secondary).auralFrame(width: 58)
                    .accessibilityLabel("Filter \(number) has a fixed 6 dB per octave slope")
                    .help("This shelf has a fixed 6 dB/octave slope, so it has no Q.")
                    .overlay(alignment: .topLeading) { numericLabel("Q") }
            }
            Menu {
                Button("Duplicate") { if finishNumericEdit() { withAuralAnimation { model.duplicateFilter(at: index) } } }.disabled((model.profile.filters?.count ?? 0) >= Profile.maxFilters)
                Button("Delete filter", role: .destructive) { if finishNumericEdit() { withAuralAnimation { model.deleteFilter(at: index) } } }.disabled(model.profile.filters?.count == 1)
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.primary).auralFrame(width: 22)
                .accessibilityLabel("Filter \(number) actions")
        }.auralPadding(.horizontal, 10).auralFrame(height: compact ? 78 : 39)
            .background(index.isMultiple(of: 2) ? Color.clear : AuralStyle.elevated.opacity(0.32))
            .accessibilityElement(children: .contain).accessibilityLabel("Filter \(number)")
    }

    @ViewBuilder private func numericLabel(_ title: String) -> some View {
        if compact {
            Text(title).auralFont(size: 9, weight: .medium).foregroundStyle(AuralStyle.secondary)
                .offset(y: -15 * interfaceScale).accessibilityHidden(true).allowsHitTesting(false)
        }
    }
}

/// The rack has fixed numeric columns and one flexible type column. Placing them
/// directly avoids HStack's repeated minimum/ideal probes of every native field.
struct FilterColumns: Layout {
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
            var x = bounds.midX - (79 + 66 + 58 + 36) * scale / 2
            for index in 3...5 {
                let width = fixedWidths[index] * scale
                subviews[index].place(at: CGPoint(x: x + width / 2, y: bounds.minY + 57 * scale), anchor: .center,
                                      proposal: ProposedViewSize(width: width, height: 24 * scale))
                x += width + 18 * scale
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
