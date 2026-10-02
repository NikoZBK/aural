import SwiftUI

struct FilterRack: View {
    @ObservedObject var model: Model
    @State private var displayBands = false
    private let frequencies: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    private var canShowBands: Bool { model.profile.filters?.allSatisfy { $0.kind == .peak && $0.effectiveChannel == .stereo } ?? true }
    private var count: Int { model.profile.filters?.count ?? 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AuralSectionLabel(title: "\(count) bands", systemImage: "slider.horizontal.3")
                Spacer()
                if canShowBands {
                    Button {
                        if model.profile.filters == nil { model.editGraphicAsFilters(); displayBands = false }
                        else { displayBands.toggle() }
                    } label: {
                        Label(displayBands || model.profile.filters == nil ? "Rows" : "Faders", systemImage: displayBands || model.profile.filters == nil ? "list.bullet" : "slider.vertical.3")
                    }.buttonStyle(AuralButtonStyle())
                        .help("Switch between numeric editing and gain faders")
                }
                Menu("Shape") {
                    Button("Gains +1 dB") { model.transformGains(scale: 1, offset: 1) }
                    Button("Gains −1 dB") { model.transformGains(scale: 1, offset: -1) }
                    Button("Scale gains to 50%") { model.transformGains(scale: 0.5, offset: 0) }
                    Button("Invert gains") { model.transformGains(scale: -1, offset: 0) }
                    Divider()
                    Button("Shift up ⅓ octave") { model.shiftFrequencies(octaves: 1.0 / 3) }
                    Button("Shift down ⅓ octave") { model.shiftFrequencies(octaves: -1.0 / 3) }
                }.fixedSize().help("Transform the curve. Changes outside valid ranges are rejected; Undo restores the curve.")
                Button { model.addFilter() } label: { Image(systemName: "plus") }
                    .buttonStyle(AuralButtonStyle()).disabled(count >= 32).help("Add a parametric filter").accessibilityLabel("Add filter")
            }
            if model.profile.filters == nil || (displayBands && canShowBands) {
                faders
            } else if let filters = model.profile.filters {
                rows(filters)
            }
        }
    }

    private var faders: some View {
        let snapshot = model.profile
        let bandCount = snapshot.filters?.count ?? snapshot.gains.count
        return GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<bandCount, id: \.self) { index in
                        let filter = snapshot.filters?[index]
                        let frequency = filter?.frequency ?? frequencies[index]
                        let gain = filter?.gain ?? snapshot.gains[index]
                        VStack(spacing: 9) {
                            Text(String(format: "%+.1f", gain)).font(.system(size: 11, design: .monospaced)).foregroundStyle(AuralStyle.accent)
                            Slider(value: Binding(get: { currentGain(at: index, fallback: gain) }, set: { value in
                                if let current = model.profile.filters, current.indices.contains(index) {
                                    var updated = current[index]; updated.gain = value; model.updateFilter(at: index, with: updated)
                                } else if model.profile.filters == nil && model.profile.gains.indices.contains(index) {
                                    model.setGraphicGain(at: index, to: value)
                                } else { model.error = "The band layout changed. Try the edit again." }
                            }), in: model.profile.filters == nil ? -12...12 : -30...30,
                                   onEditingChanged: { active in active ? model.beginProfileGesture(label: "Band gain") : model.endProfileGesture() })
                                .frame(width: max(70, min(140, geometry.size.height - 90))).rotationEffect(.degrees(-90))
                                .frame(width: 28, height: max(74, min(144, geometry.size.height - 86)))
                                .accessibilityLabel("Band \(index + 1), \(frequency) hertz gain")
                                .accessibilityValue(String(format: "%.2f decibels", gain))
                            Text(frequency >= 1000 ? String(format: "%gk", frequency / 1000) : String(format: "%g", frequency))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(AuralStyle.secondary)
                            if let filter {
                                Toggle("Band \(index + 1) enabled", isOn: Binding(get: { filter.enabled }, set: { model.setFilterEnabled(at: index, enabled: $0) }))
                                    .labelsHidden().toggleStyle(.checkbox)
                            }
                        }.frame(width: max(48, geometry.size.width / Double(bandCount))).padding(.vertical, 12)
                    }
                }.frame(minWidth: geometry.size.width)
            }.scrollIndicators(.visible)
        }.frame(minHeight: 170).background(AuralStyle.surface, in: RoundedRectangle(cornerRadius: 6))
    }

    private func currentGain(at index: Int, fallback: Double) -> Double {
        // SwiftUI can read the old binding while replacing a 31-band layout with ten bands.
        if let filters = model.profile.filters { return filters.indices.contains(index) ? filters[index].gain : fallback }
        return model.profile.gains.indices.contains(index) ? model.profile.gains[index] : fallback
    }

    private func rows(_ filters: [ImportedFilter]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text("ON").frame(width: 24)
                Text("FILTER").frame(maxWidth: .infinity, alignment: .leading)
                Text("CH").frame(width: 60)
                Text("Hz").frame(width: 79, alignment: .trailing)
                Text("dB").frame(width: 66, alignment: .trailing)
                Text("Q").frame(width: 58, alignment: .trailing)
                Color.clear.frame(width: 22, height: 1)
            }.font(.system(size: 9, weight: .semibold)).foregroundStyle(AuralStyle.secondary)
                .padding(.horizontal, 10).frame(height: 26).accessibilityHidden(true)
            Divider().overlay(AuralStyle.border)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filters.indices, id: \.self) { index in
                        FilterRow(model: model, filter: filters[index], index: index)
                    }
                }
            }.scrollIndicators(.visible)
        }.background(AuralStyle.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AuralStyle.border))
    }
}

private struct FilterRow: View {
    @ObservedObject var model: Model
    let filter: ImportedFilter
    let index: Int
    private var number: Int { index + 1 }
    var body: some View {
        HStack(spacing: 7) {
            Toggle("Filter \(number) enabled", isOn: Binding(get: { filter.enabled }, set: { model.setFilterEnabled(at: index, enabled: $0) }))
                .labelsHidden().toggleStyle(.checkbox).frame(width: 24)
            HStack(spacing: 6) {
                Text(String(format: "%02d", number)).font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(AuralStyle.plotColors[index % AuralStyle.plotColors.count]).frame(width: 18)
                Picker("Filter \(number) type", selection: Binding(get: { filter.kind }, set: { kind in
                    var next = filter; next.kind = kind; if !kind.usesGain { next.gain = 0 }; model.updateFilter(at: index, with: next)
                })) {
                    ForEach(ImportedFilter.Kind.allCases, id: \.self) { kind in Text(kind.label.components(separatedBy: " · ")[0]).tag(kind) }
                }.labelsHidden().font(.system(size: 11))
            }.frame(maxWidth: .infinity, alignment: .leading)
            Picker("Filter \(number) channel", selection: Binding(get: { filter.effectiveChannel }, set: { channel in
                var next = filter; next.channel = channel == .stereo ? nil : channel; model.updateFilter(at: index, with: next)
            })) {
                Text("L+R").tag(ImportedFilter.Channel.stereo)
                Text("L").tag(ImportedFilter.Channel.left)
                Text("R").tag(ImportedFilter.Channel.right)
            }.labelsHidden().frame(width: 60).controlSize(.small)
            PrecisionField(value: filter.frequency, range: 10...22000, label: "Filter \(number) frequency in hertz", decimals: 2, revision: model.editRevision) { value in
                var next = filter; next.frequency = value; model.updateFilter(at: index, with: next)
            }.frame(width: 79)
            if filter.kind.usesGain {
                PrecisionField(value: filter.gain, range: -30...30, label: "Filter \(number) gain in decibels", revision: model.editRevision) { value in
                    var next = filter; next.gain = value; model.updateFilter(at: index, with: next)
                }.frame(width: 66)
            } else {
                Text("—").font(.system(size: 11)).foregroundStyle(AuralStyle.secondary).frame(width: 66)
            }
            PrecisionField(value: filter.q, range: 0.05...50, label: "Filter \(number) Q", decimals: 3, revision: model.editRevision) { value in
                var next = filter; next.q = value; model.updateFilter(at: index, with: next)
            }.frame(width: 58)
            Menu {
                Button("Duplicate") { model.duplicateFilter(at: index) }.disabled((model.profile.filters?.count ?? 0) >= 32)
                Button("Delete filter", role: .destructive) { model.deleteFilter(at: index) }.disabled(model.profile.filters?.count == 1)
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                .accessibilityLabel("Filter \(number) actions")
        }.padding(.horizontal, 10).frame(height: 39)
            .background(index.isMultiple(of: 2) ? Color.clear : AuralStyle.elevated.opacity(0.32))
            .opacity(filter.enabled ? 1 : 0.55)
            .accessibilityElement(children: .contain).accessibilityLabel("Filter \(number)")
    }
}
