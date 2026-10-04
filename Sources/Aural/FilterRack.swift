import SwiftUI

struct FilterRack: View {
    @ObservedObject var model: Model
    @ObservedObject var submissions: PrecisionSubmissionCoordinator
    @Binding var selectedBand: Int
    @Binding var display: FilterDisplay
    @State private var selectionRevision = 0
    private var count: Int { model.profile.filters?.count ?? 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AuralSectionLabel(title: "\(count) bands", systemImage: "slider.horizontal.3")
                Spacer()
                Picker("Filter view", selection: Binding(get: { display }, set: { next in
                    guard finishNumericEdit() else { selectionRevision += 1; return }
                    if next == .rows && model.profile.filters == nil { model.editGraphicAsFilters() }
                    guard model.error == nil else { selectionRevision += 1; return }
                    display = next
                })) {
                    Text("Selected").tag(FilterDisplay.selected)
                    Text("All rows").tag(FilterDisplay.rows)
                    Text("Faders").tag(FilterDisplay.faders)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 218).id(selectionRevision)
                Menu("EQ actions") {
                    Menu("New EQ") {
                        Button("New flat 10-band EQ") { if finishNumericEdit() { model.useGraphicTemplate(bands: 10) } }
                        Button("New flat 31-band EQ") { if finishNumericEdit() { model.useGraphicTemplate(bands: 31) } }
                    }
                    Divider()
                    Button("Gains +1 dB") { if finishNumericEdit() { model.transformGains(scale: 1, offset: 1) } }
                    Button("Gains −1 dB") { if finishNumericEdit() { model.transformGains(scale: 1, offset: -1) } }
                    Button("Scale gains to 50%") { if finishNumericEdit() { model.transformGains(scale: 0.5, offset: 0) } }
                    Button("Invert gains") { if finishNumericEdit() { model.transformGains(scale: -1, offset: 0) } }
                    Divider()
                    Button("Shift up ⅓ octave") { if finishNumericEdit() { model.shiftFrequencies(octaves: 1.0 / 3) } }
                    Button("Shift down ⅓ octave") { if finishNumericEdit() { model.shiftFrequencies(octaves: -1.0 / 3) } }
                }.fixedSize().help("Adjust all bands together. Undo restores your previous EQ.")
                Button("Reset EQ") { if finishNumericEdit() { model.resetEQ() } }
                    .buttonStyle(AuralButtonStyle()).help("Set band gains and preamp to 0 dB. Keep frequencies, Q, filter types, channels, and stereo settings.")
                Button { if finishNumericEdit() { model.addFilter() } } label: { Image(systemName: "plus") }
                    .buttonStyle(AuralButtonStyle()).disabled(count >= 32).help("Add a parametric filter").accessibilityLabel("Add filter")
            }
            // Retain the native editors across display changes. Hidden editors are
            // disabled and excluded from pointer and accessibility navigation.
            ZStack(alignment: .topLeading) {
                EQBars(model: model, submissions: submissions, compact: true)
                    .background(AuralStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                    .auralGlassVisibility(display == .faders)
                    .opacity(display == .faders ? 1 : 0)
                    .allowsHitTesting(display == .faders)
                    .accessibilityElement(children: display == .faders ? .contain : .ignore)
                    .accessibilityHidden(display != .faders)
                    .disabled(display != .faders)
                if let filters = model.profile.filters {
                    rows(filters)
                        .auralGlassVisibility(display == .rows)
                        .opacity(display == .rows ? 1 : 0)
                        .allowsHitTesting(display == .rows)
                        .accessibilityElement(children: display == .rows ? .contain : .ignore)
                        .accessibilityHidden(display != .rows)
                        .disabled(display != .rows)
                }
                selectedInspector
                    .auralGlassVisibility(display == .selected)
                    .opacity(display == .selected ? 1 : 0)
                    .allowsHitTesting(display == .selected)
                    .accessibilityElement(children: display == .selected ? .contain : .ignore)
                    .accessibilityHidden(display != .selected)
                    .disabled(display != .selected)
            }
            .frame(height: 168, alignment: .top)
            .frame(height: display == .selected ? 108 : 168, alignment: .top).clipped()
            .onChange(of: display) { _, _ in model.endProfileGesture() }

        }.onDisappear { model.endProfileGesture() }
    }

    private var selectedInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Selected filter", selection: Binding(get: { selectedBand }, set: { index in
                selectedBand = index
                selectionRevision += 1
            })) {
                ForEach(EQBarBand.bands(in: model.profile), id: \.index) { band in
                    Text("\(band.index + 1) · \(band.frequency, specifier: "%g") Hz\(band.filter?.enabled == false ? " · Off" : "")").tag(band.index)
                }
            }.frame(width: 230).id(selectionRevision)
            if let filters = model.profile.filters, filters.indices.contains(selectedBand) {
                VStack(spacing: 0) {
                    columnHeader
                    FilterRow(model: model, submissions: submissions, filter: filters[selectedBand], index: selectedBand)
                        .id(selectedBand)
                }
            } else if model.profile.gains.indices.contains(selectedBand) {
                HStack(spacing: 12) {
                    Text("Gain").font(.system(size: 12))
                    PrecisionField(value: model.profile.gains[selectedBand], range: -12...12, label: "Band \(selectedBand + 1) gain in decibels", revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model, selectedBand] value in
                        model.endProfileGesture(); model.setBandGain(at: selectedBand, to: value)
                    }.frame(width: 80).id(selectedBand)
                    Text("dB").font(.system(size: 11)).foregroundStyle(AuralStyle.secondary)
                    Spacer()
                    Button("Edit filter parameters…") { if finishNumericEdit() { model.editGraphicAsFilters() } }
                        .buttonStyle(AuralButtonStyle()).help("Convert these graphic bands to editable filters, preserving their response.")
                }
            }
            Spacer(minLength: 0)
        }
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
                        FilterRow(model: model, submissions: submissions, filter: filters[index], index: index)
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
            FilterColumns(height: 26) {
                Text("On").frame(width: 24)
                Text("Filter").frame(maxWidth: .infinity, alignment: .leading)
                Text("Channel").frame(width: 60)
                Text("Hz").frame(width: 79)
                Text("dB").frame(width: 66)
                Text("Q").frame(width: 58)
                Color.clear.frame(width: 22, height: 1)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(AuralStyle.secondary)
                .padding(.horizontal, 10).frame(height: 26)
            Divider().overlay(AuralStyle.border)
        }.background(AuralStyle.surface).accessibilityHidden(true)
    }
}

private struct FilterRow: View {
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    let filter: ImportedFilter
    let index: Int
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
        FilterColumns(height: 39) {
            Toggle("Filter \(number) enabled", isOn: Binding(get: { currentFilter.enabled }, set: { enabled in editFilter { $0.enabled = enabled } }))
                .labelsHidden().toggleStyle(.checkbox).frame(width: 24)
            HStack(spacing: 6) {
                Text(String(format: "%02d", number)).font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(AuralStyle.secondary).frame(width: 18).accessibilityHidden(true)
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
                }.font(.system(size: 11)).fixedSize().accessibilityLabel("Filter \(number) type")
                    .accessibilityValue(currentFilter.kind.label)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Menu(currentFilter.effectiveChannel == .stereo ? "L+R" : currentFilter.effectiveChannel.rawValue) {
                ForEach([ImportedFilter.Channel.stereo, .left, .right], id: \.self) { channel in
                    Button {
                        editFilter { $0.channel = channel == .stereo ? nil : channel }
                    } label: {
                        if currentFilter.effectiveChannel == channel {
                            Label(channel == .stereo ? "L+R" : channel.rawValue, systemImage: "checkmark")
                        } else { Text(channel == .stereo ? "L+R" : channel.rawValue) }
                    }
                }
            }.frame(width: 60).controlSize(.small).accessibilityLabel("Filter \(number) channel")
                .accessibilityValue(currentFilter.effectiveChannel.label)
            PrecisionField(value: filter.frequency, range: 10...22000, label: "Filter \(number) frequency in hertz", decimals: 2, revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model, index] value in
                Self.updateFilter(model: model, index: index) { $0.frequency = value }
            }.frame(width: 79)
            if filter.kind.usesGain {
                PrecisionField(value: filter.gain, range: -30...30, label: "Filter \(number) gain in decibels", revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model, index] value in
                    Self.updateFilter(model: model, index: index) { $0.gain = value }
                }.frame(width: 66)
            } else {
                Text("—").font(.system(size: 11)).foregroundStyle(AuralStyle.secondary).frame(width: 66)
                    .accessibilityLabel("Filter \(number) has no gain parameter")
            }
            PrecisionField(value: filter.q, range: 0.05...50, label: "Filter \(number) Q", decimals: 3, revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model, index] value in
                Self.updateFilter(model: model, index: index) { $0.q = value }
            }.frame(width: 58)
            Menu {
                Button("Duplicate") { if finishNumericEdit() { model.duplicateFilter(at: index) } }.disabled((model.profile.filters?.count ?? 0) >= 32)
                Button("Delete filter", role: .destructive) { if finishNumericEdit() { model.deleteFilter(at: index) } }.disabled(model.profile.filters?.count == 1)
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                .accessibilityLabel("Filter \(number) actions")
        }.padding(.horizontal, 10).frame(height: 39)
            .background(index.isMultiple(of: 2) ? Color.clear : AuralStyle.elevated.opacity(0.32))
            .accessibilityElement(children: .contain).accessibilityLabel("Filter \(number)")
    }
}

/// The rack has fixed numeric columns and one flexible type column. Placing them
/// directly avoids HStack's repeated minimum/ideal probes of every native field.
private struct FilterColumns: Layout {
    let height: CGFloat
    private let spacing: CGFloat = 7
    private let fixedWidths: [CGFloat] = [24, 0, 60, 79, 66, 58, 22]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 439, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        precondition(subviews.count == fixedWidths.count, "Filter columns require seven cells.")
        let typeWidth = max(0, bounds.width - fixedWidths.reduce(0, +) - spacing * 6)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = index == 1 ? typeWidth : fixedWidths[index]
            subview.place(at: CGPoint(x: x + width / 2, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(width: width, height: height))
            x += width + spacing
        }
    }
}

enum FilterDisplay { case selected, rows, faders }
