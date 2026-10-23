import SwiftUI

struct EQBarBand: Equatable {
    let index: Int
    let frequency: Double
    let gain: Double
    let filter: ImportedFilter?

    static func bands(in profile: Profile) -> [Self] {
        if let filters = profile.filters {
            return filters.enumerated().map { Self(index: $0.offset, frequency: $0.element.frequency, gain: $0.element.gain, filter: $0.element) }
        }
        return zip(ProfileTools.graphicFrequencies, profile.gains).enumerated().map {
            Self(index: $0.offset, frequency: $0.element.0, gain: $0.element.1, filter: nil)
        }
    }
}

/// Shared gain controls edit the active bands without converting imported filters.
struct EQBars: View {
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    var compact = false
    var showParameters = false
    var active = true
    var moveFilter: ((Int, Int) -> Void)? = nil

    var body: some View {
        EQBarsContent(model: model, presentation: EQBarsPresentation(model: model), submissions: submissions, compact: compact, showParameters: showParameters,
                      active: active, moveFilter: moveFilter)
    }
}

struct EQBarsPresentation: Equatable {
    let profile: Profile
    let soloed: Int?
    let canSolo: Bool
    @MainActor init(model: Model) {
        profile = model.profile
        soloed = model.soloBand
        canSolo = model.running && !model.bypass
    }
}

/// The rack already observes the document. Its inactive editor can retain this
/// value without an independent subscription refreshing every hidden fader.
struct EQBarsContent: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    let model: Model
    let presentation: EQBarsPresentation
    let submissions: PrecisionSubmissionCoordinator
    var compact = false
    var showParameters = false
    var active = true
    var moveFilter: ((Int, Int) -> Void)? = nil
    private var range: ClosedRange<Double> { presentation.profile.filters == nil ? -12...12 : -30...30 }

    var body: some View {
        let snapshot = presentation.profile
        let bands = EQBarBand.bands(in: snapshot)
        GeometryReader { geometry in
            let barHeight = showParameters
                ? max(64 * interfaceScale, min(180 * interfaceScale, geometry.size.height - 204 * interfaceScale))
                : max(64, min(260, geometry.size.height - (snapshot.filters == nil ? 56 : 80) * interfaceScale))
            let spacing: CGFloat = showParameters ? 8 * interfaceScale : 0
            let minimumWidth: CGFloat = (showParameters ? 96 : 48) * interfaceScale
            let bandWidth = max(minimumWidth, (geometry.size.width - spacing * CGFloat(max(0, bands.count - 1))) / CGFloat(bands.count))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(bands, id: \.index) { value in
                        EQBandContent(model: model, submissions: submissions, value: value, height: barHeight, range: range,
                                      showParameters: showParameters, soloed: presentation.soloed == value.index,
                                      actions: value.filter.map { FilterActionsState(model: model, index: value.index, filter: $0) },
                                      moveFilter: moveFilter).equatable().frame(width: bandWidth)
                    }
                }.frame(minWidth: geometry.size.width).auralPadding(.vertical, 8)
            }.scrollDisabled(!active).scrollIndicators(active ? .visible : .hidden)
        }.auralFrame(minHeight: showParameters ? 300 : (compact ? 130 : 170)).onDisappear { model.endProfileGesture() }
    }
}

/// A gain change only redraws its own strip. The model remains live for actions
/// and stale-draft validation, but is not a broad observation dependency here.
private struct EQBandContent: View, Equatable {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    let model: Model
    let submissions: PrecisionSubmissionCoordinator
    let value: EQBarBand
    let height: CGFloat
    let range: ClosedRange<Double>
    let showParameters: Bool
    let soloed: Bool
    let actions: FilterActionsState?
    let moveFilter: ((Int, Int) -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.submissions === rhs.submissions && lhs.value == rhs.value && lhs.height == rhs.height &&
            lhs.range == rhs.range && lhs.showParameters == rhs.showParameters && lhs.soloed == rhs.soloed && lhs.actions == rhs.actions &&
            (lhs.moveFilter == nil) == (rhs.moveFilter == nil)
    }

    var body: some View {
        Group {
            if showParameters { parameterBand(value, height: height) }
            else { band(value, height: height) }
        }
    }

    /// A Peace-style bank: each fader owns the exact values immediately beneath it.
    private func parameterBand(_ value: EQBarBand, height: CGFloat) -> some View {
        let index = value.index
        let filter = value.filter
        return VStack(spacing: 7 * interfaceScale) {
            HStack(spacing: 3 * interfaceScale) {
                Text(String(format: "%02d", index + 1)).auralFont(size: 11, weight: .semibold, design: .monospaced)
                    .foregroundStyle(soloed ? AuralStyle.warning : AuralStyle.accent)
                if let filter {
                    Toggle("Filter \(index + 1) enabled", isOn: Binding(get: { filter.enabled }, set: { enabled in
                        if finishNumericEdit() { model.endProfileGesture(); model.setFilterEnabled(at: index, enabled: enabled) }
                    })).labelsHidden().toggleStyle(.checkbox)
                    if filter.effectiveChannel != .stereo {
                        Text(filter.effectiveChannel.rawValue).auralFont(size: 9).foregroundStyle(AuralStyle.secondary)
                            .help(filter.effectiveChannel.label)
                    }
                    Spacer(minLength: 0)
                    FilterActionsMenu(model: model, submissions: submissions, index: index, filter: filter,
                                      move: moveFilter.map { action in { offset in action(index, offset) } }, horizontal: true, includeChannel: true)
                } else {
                    Text("Graphic").auralFont(size: 9).foregroundStyle(AuralStyle.secondary)
                }
            }.auralFrame(height: 22)
            gainBar(value, height: height)
            VStack(spacing: 5 * interfaceScale) {
                parameterRow("Hz") {
                    if let filter {
                        PrecisionField(value: filter.frequency, range: 10...22000, label: "Filter \(index + 1) frequency in hertz", decimals: 0,
                                       revision: model.editRevision, currentRevision: { model.editRevision }, submissions: submissions) { number in
                            FilterParameterEditing.update(model: model, index: index) { $0.frequency = number }
                        }
                    } else {
                        fixedParameter(String(format: "%.0f", value.frequency))
                            .accessibilityLabel("Band \(index + 1) frequency, \(value.frequency) hertz, fixed graphic frequency")
                            .help("Choose Edit parameters to make frequency and Q editable.")
                    }
                }
                parameterRow("dB") {
                    if filter?.kind.usesGain ?? true {
                        PrecisionField(value: value.gain, range: range, label: "Filter \(index + 1) gain in decibels",
                                       revision: model.editRevision, currentRevision: { model.editRevision }, submissions: submissions) { number in
                            model.endProfileGesture(); model.setBandGain(at: index, to: number)
                        }
                    } else {
                        fixedParameter("—").accessibilityLabel("Filter \(index + 1) has no gain parameter")
                    }
                }
                parameterRow("Q") {
                    if let filter, filter.usesQ {
                        PrecisionField(value: filter.q, range: 0.05...50, label: "Filter \(index + 1) Q", decimals: 3,
                                       revision: model.editRevision, currentRevision: { model.editRevision }, submissions: submissions) { number in
                            FilterParameterEditing.update(model: model, index: index) { $0.q = number }
                        }
                    } else {
                        fixedParameter(filter == nil ? String(format: "%.3f", GraphicEQ.q) : "—")
                            .accessibilityLabel("Filter \(index + 1) Q is fixed")
                            .help(filter?.shape.fixedQHelp ?? "Choose Edit parameters to make frequency and Q editable.")
                    }
                }
            }
            if let filter {
                FilterTypeMenu(title: "Filter \(index + 1) type", shape: filter.shape, buttonTitle: filter.shape.name) { shape in
                    if finishNumericEdit() {
                        FilterParameterEditing.update(model: model, index: index) { $0.shape = shape; if !shape.kind.usesGain { $0.gain = 0 } }
                    }
                }
            }
        }
        .auralPadding(.horizontal, 4).auralPadding(.vertical, 8)
        .background(AuralStyle.plotBackground, in: RoundedRectangle(cornerRadius: 10 * interfaceScale))
        .overlay(RoundedRectangle(cornerRadius: 10 * interfaceScale).strokeBorder(AuralStyle.border))
        .accessibilityElement(children: .contain).accessibilityLabel("Filter \(index + 1)")
        .accessibilityValue(filter?.enabled == false ? "Disabled" : (soloed ? "Soloed" : ""))
    }

    private func parameterRow<Content: View>(_ unit: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4 * interfaceScale) {
            Text(unit).auralFont(size: 10).foregroundStyle(AuralStyle.secondary).auralFrame(width: 16, alignment: .leading)
                .accessibilityHidden(true)
            content().auralFrame(width: 66)
        }.auralFrame(height: 27)
    }

    private func fixedParameter(_ text: String) -> some View {
        Text(text).auralFont(size: 11, design: .monospaced).foregroundStyle(AuralStyle.secondary)
            .auralFrame(maxWidth: .infinity, minHeight: 27, alignment: .trailing)
    }

    private func gainBar(_ value: EQBarBand, height: CGFloat) -> some View {
        let adjustable = value.filter?.kind.usesGain ?? true
        return EQGainBar(value: value.gain, range: range, adjustable: adjustable,
                         label: String(format: "Band %d, %.0f hertz gain", value.index + 1, value.frequency),
                         change: { model.setBandGain(at: value.index, to: $0) }, begin: {
            guard finishNumericEdit() else { return false }
            model.beginProfileGesture(label: "Band gain")
            return true
        }, end: { model.endProfileGesture() })
            .frame(width: 40 * interfaceScale, height: height)
            .help(adjustable ? "Drag or use Up and Down arrows to adjust gain. Double-click or press zero to reset."
                            : "\(value.filter?.shape.label ?? "Filter") has no gain control.")
    }

    @ViewBuilder private func band(_ value: EQBarBand, height: CGFloat) -> some View {
        let index = value.index
        let filter = value.filter
        let frequency = value.frequency
        let gain = value.gain
        let adjustable = filter?.kind.usesGain ?? true
        VStack(spacing: 7 * interfaceScale) {
            Text(adjustable ? String(format: "%+.1f", gain) : "—")
                .auralFont(size: 11, design: .monospaced).foregroundStyle(Color.primary)
            gainBar(value, height: height)
            Text(frequency >= 1000 ? String(format: "%.3gk", frequency / 1000) : String(format: "%.0f", frequency))
                .auralFont(size: 10, design: .monospaced).foregroundStyle(AuralStyle.secondary)
                .lineLimit(1).help(String(format: "%.0f Hz", frequency))
            if let filter {
                HStack(spacing: 3 * interfaceScale) {
                    Toggle("Band \(index + 1) enabled", isOn: Binding(get: {
                        guard let current = model.profile.filters, current.indices.contains(index) else { return filter.enabled }
                        return current[index].enabled
                    }, set: { enabled in
                        if finishNumericEdit() { model.endProfileGesture(); model.setFilterEnabled(at: index, enabled: enabled) }
                    })).labelsHidden().toggleStyle(.checkbox)
                    if filter.effectiveChannel != .stereo {
                        Text(filter.effectiveChannel.rawValue).auralFont(size: 9).foregroundStyle(AuralStyle.secondary)
                    }
                }
            }
        }
    }
    private func finishNumericEdit() -> Bool {
        switch submissions.submitActive() {
        case .unchanged: return true
        case .submitted: return model.error == nil
        case .rejected: return false
        }
    }
}

enum EQBarScale {
    static func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
        (min(range.upperBound, max(range.lowerBound, value)) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
    static func gain(at fraction: Double, in range: ClosedRange<Double>) -> Double {
        range.lowerBound + min(1, max(0, fraction)) * (range.upperBound - range.lowerBound)
    }
}

private struct EQGainBar: View {
    let value: Double
    let range: ClosedRange<Double>
    let adjustable: Bool
    let label: String
    let change: (Double) -> Void
    let begin: () -> Bool
    let end: () -> Void
    @State private var dragging = false
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height - 8
            // Gain changes pixels, not layout. Resizing a stack of shapes on every
            // pointer event invalidates the surrounding retained editor's layout.
            Canvas { [value, range, adjustable, colorScheme, contrast] context, size in
                let height = size.height - 8
                let accent = AuralStyle.staticAccent(for: colorScheme, increasedContrast: contrast == .increased)
                let position = (1 - EQBarScale.fraction(value, in: range)) * height + 4
                let zero = (1 - EQBarScale.fraction(0, in: range)) * height + 4
                context.fill(Path(roundedRect: CGRect(x: (size.width - 18) / 2, y: 0, width: 18, height: size.height), cornerRadius: 4),
                             with: .color(AuralStyle.elevated))
                context.fill(Path(roundedRect: CGRect(x: (size.width - 18) / 2, y: min(zero, position), width: 18, height: max(2, abs(zero - position))), cornerRadius: 3),
                             with: .color(accent.opacity(adjustable ? 0.8 : 0.2)))
                context.fill(Path(CGRect(x: (size.width - 30) / 2, y: zero, width: 30, height: 1)), with: .color(AuralStyle.secondary))
                if adjustable {
                    context.fill(Path(roundedRect: CGRect(x: (size.width - 30) / 2, y: position - 3.5, width: 30, height: 7), cornerRadius: 3),
                                 with: .color(accent))
                }
            }.environment(\.colorScheme, colorScheme)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard adjustable else { return }
                    if !dragging { guard begin() else { return }; dragging = true; focused = true }
                    let position = Double((event.location.y - 4) / height)
                    change(EQBarScale.gain(at: 1 - position, in: range))
                }.onEnded { _ in if dragging { dragging = false; end() } })
                .simultaneousGesture(TapGesture(count: 2).onEnded { adjust(to: 0) })
        }.overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(focused ? Color.primary : .clear, lineWidth: 2))
            .accessibilityRepresentation {
                if adjustable {
                    Slider(value: Binding(get: { value }, set: { adjust(to: $0) }), in: range, step: 0.5) { Text(label) }
                        .accessibilityValue(AuralAccessibility.decibels(value))
                        .accessibilityHint("Up and Down arrows adjust gain. Press zero to reset.")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: adjust(to: min(range.upperBound, value + 0.5))
                            case .decrement: adjust(to: max(range.lowerBound, value - 0.5))
                            @unknown default: break
                            }
                        }
                        .accessibilityAction(named: "Reset gain to zero") { adjust(to: 0) }
                } else {
                    Text("\(label). Gain is not adjustable")
                }
            }.focusable(adjustable).focused($focused)
            .onKeyPress(.upArrow) { adjust(to: min(range.upperBound, value + 0.5)); return .handled }
            .onKeyPress(.downArrow) { adjust(to: max(range.lowerBound, value - 0.5)); return .handled }
            .onKeyPress("0") { adjust(to: 0); return .handled }
            .onDisappear { if dragging { dragging = false; end() } }
    }
    private func adjust(to value: Double) {
        guard adjustable, begin() else { return }
        focused = true
        change(value)
        end()
    }
}
