import SwiftUI

struct FilterEditor: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: ParametricDraft
    @State private var error: String?
    @State private var history = EditHistory<ParametricDraft>()
    @State private var restoringHistory = false
    @State private var sourceRevision: Int
    private var sourceChanged: Bool { sourceRevision != model.editRevision }
    // This view applies zoom to its own body, so the environment above it still reads 1.
    private var interfaceScale: CGFloat { model.interfaceZoom.scale }
    private var sourceChangeNotice: String? { sourceChanged ? "The active EQ changed while this draft was open. Your draft is retained; reload the current EQ before applying edits." : nil }

    init(model: Model) {
        self.model = model
        _draft = State(initialValue: ParametricDraft(model.profile))
        _sourceRevision = State(initialValue: model.editRevision)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * interfaceScale) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16 * interfaceScale) {
                    preamp
                    preview
                    filterList
                    guidance
                }
            }.scrollIndicators(.visible)
            if let sourceChangeNotice {
                HStack(alignment: .top, spacing: 12 * interfaceScale) {
                    AuralNotice(message: sourceChangeNotice, isError: true)
                    Button("Reload current EQ") { withAuralAnimation { reloadCurrent() } }.buttonStyle(AuralButtonStyle())
                        .help("Replace this editor's draft with the current EQ and clear its local undo history")
                }
                .transition(.auralReveal(.bottom, reduceMotion: reduceMotion))
            }
            if let error {
                AuralNotice(message: error, isError: true)
                    .transition(.auralReveal(.bottom, reduceMotion: reduceMotion))
            }
            footer
        }
        .auralAnimation(value: [error, sourceChangeNotice])
        .auralFont(size: 13)
        .textFieldStyle(.roundedBorder)
        .auralPadding(24)
        .auralFrame(minWidth: 900, idealWidth: 930, minHeight: 520, idealHeight: 750)
        .auralZoom(model)
        .auralAppearance(model.theme)
        .background(HistoryKeyboardShortcuts(canUndo: history.canUndo, canRedo: history.canRedo,
                                            undo: undoDraft, redo: redoDraft))
        .auralAnnouncement(error ?? sourceChangeNotice)
        .onChange(of: draft) { previous, _ in
            if restoringHistory { restoringHistory = false }
            else { history.record(previous) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14 * interfaceScale) {
            Image(systemName: "slider.horizontal.3")
                .auralFont(size: 22, weight: .medium)
                .foregroundStyle(AuralStyle.secondary)
                .auralFrame(width: 46, height: 46)
                .background(AuralStyle.elevated, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5 * interfaceScale) {
                Text("Filter editor").auralFont(size: 24, weight: .semibold)
                Text("Check your changes before applying them.")
                    .foregroundStyle(AuralStyle.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5 * interfaceScale) {
                Text("\(draft.filters.count) / \(Profile.maxFilters)")
                    .contentTransition(.numericText(value: Double(draft.filters.count)))
                    .auralFont(size: 16, weight: .medium, design: .monospaced)
                    .foregroundStyle(Color.primary)
                Text("filters").foregroundStyle(AuralStyle.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(draft.filters.count) of \(Profile.maxFilters) filters")
        }
    }

    private var preview: some View {
        Group {
            switch Result(catching: { try draft.profile() }) {
            case .success(let profile):
                ResponseCurve(profile: profile, rate: model.responseRate, bypass: false, running: false)
                    .equatable().frame(height: 240).auralPanel(padding: 14)
            case .failure(let failure):
                AuralNotice(message: "Preview unavailable: " + failure.localizedDescription, isError: true)
            }
        }
        // Partial numeric input must not make the form jump while a field is focused.
        // The fixed height is the curve plus its zoomed panel padding.
        .frame(height: 240 + 2 * 14 * interfaceScale, alignment: .top)
    }

    private var preamp: some View {
        HStack(spacing: 16 * interfaceScale) {
            VStack(alignment: .leading, spacing: 4 * interfaceScale) {
                Text("Preamp").fontWeight(.semibold)
                Text("Overall level before the filters")
                    .auralFont(size: 12).foregroundStyle(AuralStyle.secondary)
            }
            Spacer()
            TextField("Preamp", text: $draft.preamp)
                .auralFont(size: 14, design: .monospaced)
                .multilineTextAlignment(.trailing)
                .auralFrame(width: 84)
                .accessibilityLabel("Parametric preamp in decibels")
                .accessibilityHint("Enter a number from minus 60 to plus 24")
            Text("dB").foregroundStyle(AuralStyle.secondary)
            Divider().auralFrame(height: 30)
            Text("−60 to +24 dB")
                .auralFont(size: 12).foregroundStyle(AuralStyle.secondary)
        }
        .auralPanel(padding: 16)
    }

    private var filterList: some View {
        VStack(alignment: .leading, spacing: 14 * interfaceScale) {
            HStack {
                AuralSectionLabel(title: "Filters", systemImage: "line.3.horizontal.decrease")
                Spacer()
                Button("Add filter", systemImage: "plus") { withAuralAnimation { draft.filters.append(FilterDraft()) } }
                    .buttonStyle(AuralButtonStyle())
                    .disabled(draft.filters.count >= Profile.maxFilters)
                    .help("Add a peak filter. You can use up to \(Profile.maxFilters) filters.")
            }
            if draft.filters.isEmpty {
                VStack(spacing: 10 * interfaceScale) {
                    Image(systemName: "waveform.path")
                        .auralFont(size: 28).foregroundStyle(AuralStyle.secondary)
                        .accessibilityHidden(true)
                    Text("No filters added yet").fontWeight(.medium)
                    Text("Add at least one filter before applying your EQ.")
                        .auralFont(size: 12).foregroundStyle(AuralStyle.secondary)
                }
                .auralFrame(maxWidth: .infinity, minHeight: 140)
                .transition(.opacity)
            } else {
                columnHeadings
                VStack(spacing: 4 * interfaceScale) {
                    ForEach($draft.filters) { $filter in
                        if let index = draft.filters.firstIndex(where: { $0.id == filter.id }) {
                            filterRow($filter, number: index + 1)
                                .transition(.auralReveal(reduceMotion: reduceMotion))
                        }
                    }
                }
            }
        }
        .auralPanel(padding: 16)
    }

    private var columnHeadings: some View {
        HStack(spacing: 8 * interfaceScale) {
            Text("#").auralFrame(width: 24)
            Text("On").auralFrame(width: 28)
            Text("Type").auralFrame(width: 166, alignment: .leading)
            Text("Channel").auralFrame(width: 66, alignment: .leading)
            Text("Frequency · Hz").auralFrame(width: 122, alignment: .leading)
            Text("Gain · dB").auralFrame(width: 100, alignment: .leading)
            Text("Q").auralFrame(width: 80, alignment: .leading)
            Spacer(minLength: 0)
        }
        .auralFont(size: 11, weight: .medium)
        .foregroundStyle(AuralStyle.secondary)
        .accessibilityHidden(true)
    }

    private func filterRow(_ filter: Binding<FilterDraft>, number: Int) -> some View {
        let id = filter.wrappedValue.id
        return HStack(spacing: 8 * interfaceScale) {
            Text(String(format: "%02d", number))
                .auralFont(size: 11, weight: .medium, design: .monospaced)
                .foregroundStyle(AuralStyle.secondary)
                .auralFrame(width: 24)
                .accessibilityHidden(true)
            Toggle("Filter \(number) enabled", isOn: filter.enabled)
                .labelsHidden().toggleStyle(.checkbox).auralFrame(width: 28)
                .help("Enable or bypass filter \(number)")
            Picker("Filter \(number) type", selection: filter.kind) {
                ForEach(ImportedFilter.Kind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .labelsHidden().auralFrame(width: 166)
            Picker("Filter \(number) channel", selection: filter.channel) {
                Text("L+R").tag(ImportedFilter.Channel.stereo)
                Text("Left").tag(ImportedFilter.Channel.left)
                Text("Right").tag(ImportedFilter.Channel.right)
                Text("Mid").tag(ImportedFilter.Channel.mid)
                Text("Side").tag(ImportedFilter.Channel.side)
            }.labelsHidden().auralFrame(width: 66)
            TextField("Frequency", text: filter.frequency)
                .auralFrame(width: 122)
                .accessibilityLabel("Filter \(number) frequency in hertz")
                .accessibilityHint("Enter a number from 10 to 22000")
            if filter.wrappedValue.kind.usesGain {
                TextField("Gain", text: filter.gain)
                    .auralFrame(width: 100)
                    .accessibilityLabel("Filter \(number) gain in decibels")
                    .accessibilityHint("Enter a number from minus 30 to plus 30")
            } else {
                Text("—").foregroundStyle(AuralStyle.secondary).auralFrame(width: 100)
                    .accessibilityLabel("Filter \(number) has no gain parameter")
                    .help("This filter uses frequency and Q. Adjust preamp to change the overall level.")
            }
            if filter.wrappedValue.kind.usesQ {
                TextField("Q", text: filter.q)
                    .auralFrame(width: 80)
                    .accessibilityLabel("Filter \(number) Q")
                    .accessibilityHint("Enter a number from 0.05 to 50")
            } else {
                Text("—").foregroundStyle(AuralStyle.secondary).auralFrame(width: 80)
                    .accessibilityLabel("Filter \(number) has a fixed 6 dB per octave slope")
                    .help("This shelf has a fixed 6 dB/octave slope, so it has no Q.")
            }
            Menu {
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    do { try withAuralAnimation { try draft.duplicateFilter(id) }; error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(draft.filters.count >= Profile.maxFilters)
                Button("Move up", systemImage: "arrow.up") {
                    do { try withAuralAnimation { try draft.moveFilter(id, by: -1) }; error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(draft.filters.first?.id == id)
                Button("Move down", systemImage: "arrow.down") {
                    do { try withAuralAnimation { try draft.moveFilter(id, by: 1) }; error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(draft.filters.last?.id == id)
            } label: {
                Image(systemName: "ellipsis.circle").auralFont(size: 15)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.primary).auralFrame(width: 24)
            .help("Duplicate or reorder filter \(number)")
            .accessibilityLabel("Filter \(number) actions")
            Button {
                withAuralAnimation { draft.filters.removeAll { $0.id == id } }
            } label: {
                Image(systemName: "minus.circle").auralFont(size: 15).auralFrame(width: 24, height: 28)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AuralStyle.secondary)
            .help("Remove filter \(number)")
            .accessibilityLabel("Remove filter \(number)")
        }
        .auralFont(size: 12)
        .monospacedDigit()
        .auralFrame(minHeight: 44)
        .background(number.isMultiple(of: 2) ? AuralStyle.elevated.opacity(0.6) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter \(number)")
    }

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 5 * interfaceScale) {
            Text("10–22,000 Hz  ·  Gain −30 to +30 dB  ·  Q 0.05–50")
            Text("Pass and notch filters use frequency and Q. All-pass changes phase, so its magnitude graph is flat.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .auralFont(size: 12)
        .foregroundStyle(AuralStyle.secondary)
    }

    private func restoreDraft(_ next: ParametricDraft) {
        // A no-op replacement has no onChange callback to consume suppression.
        restoringHistory = next != draft
        draft = next
    }

    private func reloadCurrent() {
        restoreDraft(ParametricDraft(model.profile))
        sourceRevision = model.editRevision
        history = EditHistory<ParametricDraft>()
        error = nil
    }

    private var footer: some View {
        VStack(spacing: 14 * interfaceScale) {
            Divider().overlay(AuralStyle.border)
            HStack(spacing: 8 * interfaceScale) {
                Button("Undo", systemImage: "arrow.uturn.backward", action: undoDraft)
                .buttonStyle(AuralButtonStyle()).disabled(!history.canUndo)
                .keyboardShortcut("z", modifiers: [.command])
                Button("Redo", systemImage: "arrow.uturn.forward", action: redoDraft)
                .buttonStyle(AuralButtonStyle()).disabled(!history.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction).buttonStyle(AuralButtonStyle())
                Button("Apply EQ") {
                    guard !sourceChanged else {
                        error = "The active EQ changed. Reload the current EQ before applying this draft."
                        return
                    }
                    do {
                        let profile = try draft.profile()
                        let previousProfile = model.profile
                        let previousOutput = model.selectedUID
                        let previousPreset = model.selectedPresetName
                        if model.replaceProfile(profile) { dismiss() }
                        else {
                            // Rejected audio settings also invalidate inline field drafts.
                            // Keep this editor usable if that failed Apply left its source intact.
                            if model.profile == previousProfile && model.selectedUID == previousOutput &&
                                model.selectedPresetName == previousPreset {
                                sourceRevision = model.editRevision
                            }
                            error = model.error
                        }
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(AuralButtonStyle(prominent: true)).disabled(sourceChanged)
            }
            Text("Changes stay in this editor until you apply.")
                .auralFont(size: 12).foregroundStyle(AuralStyle.secondary)
                .auralFrame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func undoDraft() {
        do { let previous = try history.undo(draft); withAuralAnimation { restoreDraft(previous) }; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func redoDraft() {
        do { let next = try history.redo(draft); withAuralAnimation { restoreDraft(next) }; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
