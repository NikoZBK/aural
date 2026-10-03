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
    private var range: ClosedRange<Double> { model.profile.filters == nil ? -12...12 : -30...30 }

    var body: some View {
        let snapshot = model.profile
        let bands = EQBarBand.bands(in: snapshot)
        GeometryReader { geometry in
            let barHeight = max(64, min(260, geometry.size.height - (snapshot.filters == nil ? 56 : 80)))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(bands, id: \.index) { value in
                        band(value, height: barHeight).frame(width: max(48, geometry.size.width / Double(bands.count)))
                    }
                }.frame(minWidth: geometry.size.width).padding(.vertical, 8)
            }.scrollIndicators(.visible)
        }.frame(minHeight: 170).onDisappear { model.endProfileGesture() }
    }

    @ViewBuilder private func band(_ value: EQBarBand, height: CGFloat) -> some View {
        let index = value.index
        let filter = value.filter
        let frequency = value.frequency
        let gain = value.gain
        let adjustable = filter?.kind.usesGain ?? true
        VStack(spacing: 7) {
            Text(adjustable ? String(format: "%+.1f", gain) : "—")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(AuralStyle.accent)
            EQGainBar(value: gain, range: range, adjustable: adjustable, label: "Band \(index + 1), \(frequency) hertz gain",
                      change: { model.setBandGain(at: index, to: $0) }, begin: {
                guard finishNumericEdit() else { return false }
                model.beginProfileGesture(label: "Band gain")
                return true
            }, end: { model.endProfileGesture() })
                .frame(width: 40, height: height)
                .help(adjustable ? "Drag up to boost or down to cut. Double-click to set 0 dB." : "\(filter?.kind.label ?? "Filter") has no gain control.")
            Text(frequency >= 1000 ? String(format: "%gk", frequency / 1000) : String(format: "%g", frequency))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(AuralStyle.secondary)
            if let filter {
                HStack(spacing: 3) {
                    Toggle("Band \(index + 1) enabled", isOn: Binding(get: {
                        guard let current = model.profile.filters, current.indices.contains(index) else { return filter.enabled }
                        return current[index].enabled
                    }, set: { enabled in
                        if finishNumericEdit() { model.endProfileGesture(); model.setFilterEnabled(at: index, enabled: enabled) }
                    })).labelsHidden().toggleStyle(.checkbox)
                    if filter.effectiveChannel != .stereo {
                        Text(filter.effectiveChannel == .left ? "L" : "R").font(.system(size: 9)).foregroundStyle(AuralStyle.secondary)
                    }
                }
            }
        }.opacity(filter?.enabled == false ? 0.55 : 1)
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

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height - 8
            let position = (1 - EQBarScale.fraction(value, in: range)) * height + 4
            let zero = (1 - EQBarScale.fraction(0, in: range)) * height + 4
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 4).fill(AuralStyle.elevated).frame(width: 18)
                RoundedRectangle(cornerRadius: 3).fill(AuralStyle.accent.opacity(adjustable ? 0.8 : 0.2))
                    .frame(width: 18, height: max(2, abs(zero - position))).offset(y: min(zero, position))
                Rectangle().fill(AuralStyle.secondary).frame(width: 30, height: 1).offset(y: zero)
                RoundedRectangle(cornerRadius: 3).fill(AuralStyle.accent)
                    .frame(width: 30, height: 7).offset(y: position - 3.5).opacity(adjustable ? 1 : 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard adjustable else { return }
                    if !dragging { guard begin() else { return }; dragging = true; focused = true }
                    change(EQBarScale.gain(at: 1 - (event.location.y - 4) / height, in: range))
                }.onEnded { _ in if dragging { dragging = false; end() } })
                .simultaneousGesture(TapGesture(count: 2).onEnded { adjust(to: 0) })
        }.accessibilityElement(children: .ignore).accessibilityLabel(label)
            .accessibilityValue(adjustable ? String(format: "%.2f decibels", value) : "Gain is not adjustable")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjust(to: min(range.upperBound, value + 0.5))
                case .decrement: adjust(to: max(range.lowerBound, value - 0.5))
                @unknown default: break
                }
            }.focusable(adjustable).focused($focused)
            .onKeyPress(.upArrow) { adjust(to: min(range.upperBound, value + 0.5)); return .handled }
            .onKeyPress(.downArrow) { adjust(to: max(range.lowerBound, value - 0.5)); return .handled }
            .onDisappear { if dragging { dragging = false; end() } }
    }
    private func adjust(to value: Double) {
        guard adjustable, begin() else { return }
        focused = true
        change(value)
        end()
    }
}
