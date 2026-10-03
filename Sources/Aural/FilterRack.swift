import SwiftUI

struct FilterRack: View {
    @ObservedObject var model: Model
    @ObservedObject var submissions: PrecisionSubmissionCoordinator
    @State private var displayBands = true
    private var count: Int { model.profile.filters?.count ?? 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AuralSectionLabel(title: "\(count) bands", systemImage: "slider.horizontal.3")
                Spacer()
                Group {
                    Button {
                        guard finishNumericEdit() else { return }
                        if model.profile.filters == nil { model.editGraphicAsFilters(); displayBands = false }
                        else { displayBands.toggle() }
                    } label: {
                        Label(displayBands || model.profile.filters == nil ? "Rows" : "Faders", systemImage: displayBands || model.profile.filters == nil ? "list.bullet" : "slider.vertical.3")
                    }.buttonStyle(AuralButtonStyle())
                        .help("Switch between numeric editing and gain faders")
                }
                Menu("Adjust EQ") {
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
            if model.profile.filters == nil || displayBands {
                EQBars(model: model, submissions: submissions)
                    .background(AuralStyle.surface, in: RoundedRectangle(cornerRadius: 6))
            } else if let filters = model.profile.filters {
                rows(filters)
            }
        }.onDisappear { model.endProfileGesture() }
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
                Text("ON").frame(width: 24)
                Text("FILTER").frame(maxWidth: .infinity, alignment: .leading)
                Text("CH").frame(width: 60)
                Text("Hz").frame(width: 79)
                Text("dB").frame(width: 66)
                Text("Q").frame(width: 58)
                Color.clear.frame(width: 22, height: 1)
            }.font(.system(size: 9, weight: .semibold)).foregroundStyle(AuralStyle.secondary)
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
                    .foregroundStyle(AuralStyle.plotColors[index % AuralStyle.plotColors.count]).frame(width: 18)
                Picker("Filter \(number) type", selection: Binding(get: { currentFilter.kind }, set: { kind in
                    editFilter { $0.kind = kind; if !kind.usesGain { $0.gain = 0 } }
                })) {
                    ForEach(ImportedFilter.Kind.allCases, id: \.self) { kind in Text(kind.label.components(separatedBy: " · ")[0]).tag(kind) }
                }.labelsHidden().font(.system(size: 11))
            }.frame(maxWidth: .infinity, alignment: .leading)
            Picker("Filter \(number) channel", selection: Binding(get: { currentFilter.effectiveChannel }, set: { channel in
                editFilter { $0.channel = channel == .stereo ? nil : channel }
            })) {
                Text("L+R").tag(ImportedFilter.Channel.stereo)
                Text("L").tag(ImportedFilter.Channel.left)
                Text("R").tag(ImportedFilter.Channel.right)
            }.labelsHidden().frame(width: 60).controlSize(.small)
            PrecisionField(value: filter.frequency, range: 10...22000, label: "Filter \(number) frequency in hertz", decimals: 2, revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model, index] value in
                Self.updateFilter(model: model, index: index) { $0.frequency = value }
            }.frame(width: 79)
            if filter.kind.usesGain {
                PrecisionField(value: filter.gain, range: -30...30, label: "Filter \(number) gain in decibels", revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model, index] value in
                    Self.updateFilter(model: model, index: index) { $0.gain = value }
                }.frame(width: 66)
            } else {
                Text("—").font(.system(size: 11)).foregroundStyle(AuralStyle.secondary).frame(width: 66)
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
            .opacity(filter.enabled ? 1 : 0.55)
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
