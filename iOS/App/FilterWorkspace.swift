import SwiftUI

struct FilterWorkspace: View {
    @EnvironmentObject private var model: AuralModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ParametricDraft
    @State private var error: String?
    private let revision: Int
    init(profile: Profile, revision: Int) {
        _draft = State(initialValue: ParametricDraft(profile)); self.revision = revision
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Edit a working copy. Your sound changes only when you tap Apply.").font(.subheadline).foregroundStyle(.secondary)
                    NumericField(title: "Preamp", text: $draft.preamp, unit: "dB")
                }
                Section {
                    ForEach($draft.filters) { $filter in
                        NavigationLink {
                            FilterDetail(filter: $filter)
                        } label: {
                            HStack {
                                Image(systemName: filter.enabled ? "waveform.path" : "pause.circle").foregroundStyle(filter.enabled ? Color.auralAccent : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(filter.shape.name)
                                    Text("\(filter.frequency) Hz · \(filter.channel.label)").font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(minHeight: 40)
                        }
                        .contextMenu {
                            Button("Duplicate", systemImage: "plus.square.on.square") {
                                do { try draft.duplicateFilter(filter.id) } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                    .onDelete { indices in
                        guard draft.filters.count - indices.count > 0 else { error = "Keep at least one filter. Disable it for a flat response."; return }
                        draft.filters.remove(atOffsets: indices)
                    }
                    .onMove { draft.filters.move(fromOffsets: $0, toOffset: $1) }
                    Button("Add filter", systemImage: "plus") {
                        guard draft.slots < Profile.maxFilters else { error = "All 64 filter slots are in use."; return }
                        draft.filters.append(FilterDraft())
                    }
                } header: { Text("Filters · \(draft.slots)/\(Profile.maxFilters) slots") }
                footer: { Text("Tap a filter for exact values. Use Edit to reorder or remove filters. Steeper slopes use more than one slot.") }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityLabel("Error: " + error) } }
            }
            .scrollContentBackground(.hidden).background { AuralBackground() }
            .navigationTitle("Edit filters").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        do { try model.apply(draft.profile(), selection: model.state.selectedPreset, expectedRevision: revision); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.fontWeight(.semibold)
                }
            }
        }.interactiveDismissDisabled()
    }
}

struct NumericField: View {
    let title: String
    @Binding var text: String
    let unit: String
    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            TextField(title, text: $text).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                .monospacedDigit().autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityLabel(title + (unit.isEmpty ? "" : " in " + unit))
            if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
        }.frame(minHeight: 36)
    }
}

struct FilterDetail: View {
    @Binding var filter: FilterDraft
    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $filter.enabled)
                Picker("Type", selection: $filter.kind) {
                    ForEach(ImportedFilter.Kind.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .onChange(of: filter.kind) { _, kind in if !kind.hasSlopes { filter.slope = nil } }
                if filter.kind.hasSlopes {
                    Picker("Slope", selection: $filter.slope) {
                        Text("12 dB/oct · adjustable Q").tag(Optional<ImportedFilter.Slope>.none)
                        ForEach(ImportedFilter.Slope.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                }
                Picker("Channel", selection: $filter.channel) {
                    ForEach(ImportedFilter.Channel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section {
                NumericField(title: "Frequency", text: $filter.frequency, unit: "Hz")
                if filter.kind.usesGain { NumericField(title: "Gain", text: $filter.gain, unit: "dB") }
                if filter.usesQ { NumericField(title: "Q", text: $filter.q, unit: "") }
            } header: { Text("Exact values") }
            footer: { Text("10–22,000 Hz · −30 to +30 dB · Q 0.05–50. Use a decimal point. Values are preserved at their entered precision.") }
        }.scrollContentBackground(.hidden).background { AuralBackground() }
            .navigationTitle(filter.shape.name).navigationBarTitleDisplayMode(.inline)
    }
}

struct StereoEditor: View {
    @EnvironmentObject private var model: AuralModel
    @Environment(\.dismiss) private var dismiss
    @State private var stereo: StereoSettings
    @State private var leftDelay: String
    @State private var rightDelay: String
    @State private var error: String?
    private let original: Profile
    private let revision: Int
    init(profile: Profile, revision: Int) {
        original = profile; self.revision = revision; _stereo = State(initialValue: profile.stereoSettings)
        _leftDelay = State(initialValue: String(profile.stereoSettings.leftDelayMS))
        _rightDelay = State(initialValue: String(profile.stereoSettings.rightDelayMS))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Changes take effect when you tap Apply.").font(.subheadline).foregroundStyle(.secondary)
                    ValueSlider(title: "Balance", value: $stereo.balance, range: -1...1, unit: "")
                    ValueSlider(title: "Width", value: $stereo.width, range: 0...2, unit: "×")
                    ValueSlider(title: "Crossfeed", value: $stereo.crossfeed, range: 0...1, unit: "")
                    Toggle("Mono", isOn: $stereo.mono)
                    Toggle("Swap left and right", isOn: $stereo.swapChannels)
                } header: { Text("Listening") } footer: { Text("Balance: −1 is left, +1 is right. Width: 1× is unchanged. Crossfeed blends a little of each channel into the other for headphones.") }
                Section("Channel correction") {
                    ValueSlider(title: "Left trim", value: $stereo.leftTrimDB, range: -24...12)
                    ValueSlider(title: "Right trim", value: $stereo.rightTrimDB, range: -24...12)
                    NumericField(title: "Left delay", text: $leftDelay, unit: "ms")
                    NumericField(title: "Right delay", text: $rightDelay, unit: "ms")
                    Toggle("Invert left polarity", isOn: $stereo.invertLeft)
                    Toggle("Invert right polarity", isOn: $stereo.invertRight)
                }
                Section { Button("Reset stereo controls") { stereo = StereoSettings(); leftDelay = "0"; rightDelay = "0" } }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .scrollContentBackground(.hidden).background { AuralBackground() }
            .navigationTitle("Stereo & listening").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        do {
                            guard let left = Double(leftDelay), let right = Double(rightDelay) else { throw AudioFailure(message: "Enter a delay from 0 to 30 ms for each channel.") }
                            stereo.leftDelayMS = left; stereo.rightDelayMS = right
                            try stereo.validate()
                            var next = original; next.stereo = stereo.isNeutral ? nil : stereo
                            try model.apply(next, selection: model.state.selectedPreset, expectedRevision: revision); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.fontWeight(.semibold)
                }
            }
        }.interactiveDismissDisabled()
    }
}
