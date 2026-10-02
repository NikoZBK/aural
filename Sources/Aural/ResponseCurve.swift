import SwiftUI

struct ResponseCurve: View, Equatable {
    let profile: Profile
    let rate: Double
    let bypass: Bool
    let running: Bool
    var comparisonProfile: Profile? = nil

    // Meter updates stop at this value-only boundary. Local interaction state lives
    // in the child so changing controls cannot be suppressed by this comparison.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profile == rhs.profile && lhs.rate == rhs.rate && lhs.bypass == rhs.bypass &&
            lhs.running == rhs.running && lhs.comparisonProfile == rhs.comparisonProfile
    }
    var body: some View {
        InteractiveResponseCurve(profile: profile, rate: rate, bypass: bypass, running: running,
                                 comparisonProfile: comparisonProfile)
    }
}

private struct InteractiveResponseCurve: View {
    let profile: Profile
    let rate: Double
    let bypass: Bool
    let running: Bool
    let comparisonProfile: Profile?
    @State private var hoverFraction: Double?
    @State private var showFilters = false
    @State private var channel = ResponseChannel.both
    @State private var analysis: ResponseAnalysis?

    private struct Input: Equatable {
        let profile: Profile
        let rate: Double
        let bypass: Bool
        let comparison: Profile?
    }
    private var input: Input { Input(profile: profile, rate: rate, bypass: bypass, comparison: comparisonProfile) }

    private var color: Color { bypass ? AuralStyle.secondary : AuralStyle.accent }
    private var maximumFrequency: Double { min(20000, rate * 0.49) }
    private var frequencySpan: Double { log10(maximumFrequency / 20) }
    private func frequency(at fraction: Double) -> Double { 20 * pow(10, fraction * frequencySpan) }
    private func response(at frequency: Double, channel: ImportedFilter.Channel = .stereo) -> Double {
        bypass ? 0 : profile.response(frequency, rate: rate, channel: channel)
    }
    private var displayedChannels: [ImportedFilter.Channel] {
        analysis?.displayedChannels(channel: channel) ?? [.stereo]
    }
    private var hoverReadout: String {
        let gains = displayedChannels.map { channel in
            (channel == .stereo ? "" : channel.rawValue + " ") + String(format: "%+.2f", response(at: inspectedFrequency, channel: channel))
        }.joined(separator: "  ")
        return String(format: "%.0f Hz  ", inspectedFrequency) + gains + " dB"
    }
    private var inspectedFrequency: Double { frequency(at: hoverFraction ?? log10(1000 / 20) / frequencySpan) }
    private var inspectionValue: String {
        if hoverFraction != nil {
            let gains = displayedChannels.map { channel in
                channel.label + String(format: " %+.2f decibels", response(at: inspectedFrequency, channel: channel))
            }.joined(separator: ", ")
            return String(format: "%.0f hertz, ", inspectedFrequency) + gains
        }
        return bypass ? "Bypassed, flat response" : "Includes preamp, \(rate / 1000) kilohertz \(running ? "processing" : "preview")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AuralSectionLabel(title: "EQ response", systemImage: "waveform.path")
                if analysis?.hasChannelFilters == true {
                    Picker("Response channel", selection: $channel) {
                        ForEach(ResponseChannel.allCases, id: \.self) { channel in
                            Text(channel.label).tag(channel)
                        }
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                        .frame(width: 116, height: 22)
                        .help("Inspect left and right independently. Teal is left, blue is right. Peak/headroom always covers both channels.")
                }
                Spacer(minLength: 8)
                if comparisonProfile != nil {
                    Label("Reference", systemImage: "line.diagonal")
                        .foregroundStyle(AuralStyle.secondary)
                        .help("Dashed line: the captured comparison EQ, including its preamp.")
                }
                Toggle("Filter curves", isOn: $showFilters)
                    .toggleStyle(.button).controlSize(.small)
                    .disabled(bypass)
                    .help("Overlay each enabled filter without preamp. Disabled filters are excluded.")
            }.font(.system(size: 11, weight: .medium)).frame(height: 24)
            GeometryReader { geometry in
                if let analysis {
                    let scale = analysis.scale(showFilters: showFilters, channel: channel)
                    let drawing = ResponsePlotDrawing(analysis: analysis, scale: scale, profile: profile,
                                                      rate: rate, bypass: bypass, channel: channel,
                                                      showFilters: showFilters, hoverFraction: hoverFraction)
                    ResponseCanvas(drawing: drawing)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoverFraction = min(1, max(0, (location.x - 44) / max(1, geometry.size.width - 62)))
                        case .ended: hoverFraction = nil
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Equalizer response, 20 to \(maximumFrequency) hertz, \(scale.lower) to \(scale.upper) decibels")
                    .accessibilityValue(inspectionValue)
                    .accessibilityHint("Adjust to inspect different frequencies")
                    .accessibilityAdjustableAction { direction in
                        let current = hoverFraction ?? log10(1000 / 20) / frequencySpan
                        switch direction {
                        case .increment: hoverFraction = min(1, current + 0.025)
                        case .decrement: hoverFraction = max(0, current - 0.025)
                        @unknown default: break
                        }
                    }
                }
            }
            .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AuralStyle.border))
            HStack(spacing: 14) {
                if hoverFraction != nil {
                    Text(hoverReadout)
                        .foregroundStyle(color)
                } else {
                    Text(bypass ? "BYPASS · UNITY" : String(format: "%g kHz · %@", rate / 1000, running ? "PROCESSING" : "PREVIEW"))
                        .foregroundStyle(AuralStyle.secondary)
                }
                Spacer(minLength: 4)
                if let analysis {
                    ViewThatFits(in: .horizontal) {
                        Text(analysis.peak > 0.05
                             ? String(format: "EQ peak %+.1f dB · above unity", analysis.peak)
                             : String(format: "EQ peak %+.1f dB · %.1f dB headroom", analysis.peak, analysis.peak < 0 ? -analysis.peak : 0))
                        Text(String(format: "EQ peak %+.1f dB", analysis.peak))
                    }
                        .foregroundStyle(analysis.peak > 0.05 ? AuralStyle.warning : AuralStyle.secondary)
                        .help("Estimated maximum EQ gain across both channels and the displayed frequencies, regardless of the channel selected for inspection. Includes preamp; excludes stereo effects and peak protection. This is not a measured audio level or a clipping guarantee.")
                }
                Text("AUTO dB").foregroundStyle(AuralStyle.secondary.opacity(0.7))
                    .help("The vertical scale expands to fit every displayed curve.")
            }.font(.system(size: 10, weight: .medium, design: .monospaced)).lineLimit(1)
        }
        .onChange(of: input, initial: true) { _, input in
            analysis = ResponseAnalysis(profile: input.profile, rate: input.rate, bypass: input.bypass, comparisonProfile: input.comparison)
        }
        .help("Filter and preamp response; stereo effects and peak protection are not plotted. Hover to inspect values. The logarithmic frequency axis ends below the sample rate’s Nyquist limit.")
    }

}

/// Canvas receives one immutable render value. Its closure never reaches back into
/// a View's State storage, which can otherwise leave its retained drawing one edit behind.
private struct ResponseCanvas: View {
    let drawing: ResponsePlotDrawing
    var body: some View {
        Canvas { [drawing] context, size in
            drawing.draw(context: context, size: size)
        }
    }
}

private struct ResponsePlotDrawing {
    let analysis: ResponseAnalysis
    let scale: ResponseScale
    let profile: Profile
    let rate: Double
    let bypass: Bool
    let channel: ResponseChannel
    let showFilters: Bool
    let hoverFraction: Double?

    private var color: Color { bypass ? AuralStyle.secondary : AuralStyle.accent }
    private var maximumFrequency: Double { analysis.maximumFrequency }
    private var frequencySpan: Double { log10(maximumFrequency / 20) }
    private func frequency(at fraction: Double) -> Double { 20 * pow(10, fraction * frequencySpan) }
    private func response(at frequency: Double, channel: ImportedFilter.Channel) -> Double {
        bypass ? 0 : profile.response(frequency, rate: rate, channel: channel)
    }
    private var displayedChannels: [ImportedFilter.Channel] {
        analysis.displayedChannels(channel: channel)
    }
    private func color(for channel: ImportedFilter.Channel) -> Color {
        channel == .right ? AuralStyle.plotColors[1].opacity(bypass ? 0.55 : 1) : color
    }

    func draw(context: GraphicsContext, size: CGSize) {
        let left = 44.0, right = size.width - 18, top = 14.0, bottom = size.height - 27
        let width = max(1, right - left), height = max(1, bottom - top)
        func x(_ frequency: Double) -> Double { left + log10(frequency / 20) / frequencySpan * width }
        func y(_ decibels: Double) -> Double { top + scale.fraction(decibels) * height }
        func line(from: CGPoint, to: CGPoint) -> Path {
            var path = Path(); path.move(to: from); path.addLine(to: to); return path
        }
        func curve(_ values: [Double]) -> Path {
            var path = Path()
            for (index, point) in zip(analysis.frequencies, values).enumerated() {
                let position = CGPoint(x: x(point.0), y: y(point.1))
                if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
            }
            return path
        }

        for db in scale.ticks {
            context.stroke(line(from: CGPoint(x: left, y: y(db)), to: CGPoint(x: right, y: y(db))),
                           with: .color(.white.opacity(db == 0 ? 0.22 : 0.06)), lineWidth: 1)
            context.draw(Text(db == 0 ? "0" : String(format: "%+.0f", db))
                .font(.system(size: 9, design: .monospaced)).foregroundColor(AuralStyle.secondary),
                at: CGPoint(x: left - 9, y: y(db)), anchor: .trailing)
        }
        for decade in [10.0, 100, 1000, 10000] {
            for multiple in 1...9 {
                let frequency = decade * Double(multiple)
                guard (20...maximumFrequency).contains(frequency) else { continue }
                context.stroke(line(from: CGPoint(x: x(frequency), y: top), to: CGPoint(x: x(frequency), y: bottom)),
                               with: .color(.white.opacity(multiple == 1 ? 0.09 : 0.03)), lineWidth: 1)
            }
        }

        if showFilters {
            for trace in analysis.visibleFilters(channel: channel) {
                let traceColor = AuralStyle.plotColors[trace.index % AuralStyle.plotColors.count]
                context.stroke(curve(trace.values), with: .color(traceColor.opacity(0.55)), lineWidth: 1)
            }
        }
        for channel in displayedChannels {
            let traceColor = color(for: channel)
            let values = channel == .right ? analysis.right : analysis.left
            let reference = channel == .right ? analysis.comparisonRight : analysis.comparisonLeft
            if let reference {
                context.stroke(curve(reference), with: .color(traceColor.opacity(0.55)),
                               style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            }
            let combined = curve(values)
            var fill = combined
            fill.addLine(to: CGPoint(x: right, y: y(0)))
            fill.addLine(to: CGPoint(x: left, y: y(0)))
            fill.closeSubpath()
            context.fill(fill, with: .color(traceColor.opacity(0.045)))
            context.stroke(combined, with: .color(traceColor.opacity(0.10)), lineWidth: 5)
            context.stroke(combined, with: .color(traceColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }

        if let hoverFraction {
            let frequency = frequency(at: hoverFraction)
            context.stroke(line(from: CGPoint(x: x(frequency), y: top), to: CGPoint(x: x(frequency), y: bottom)),
                           with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            for channel in displayedChannels {
                let traceColor = color(for: channel)
                let point = CGPoint(x: x(frequency), y: y(response(at: frequency, channel: channel)))
                context.stroke(line(from: CGPoint(x: left, y: point.y), to: CGPoint(x: right, y: point.y)),
                               with: .color(traceColor.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(traceColor))
            }
        }
        let candidates = [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000].filter { $0 < maximumFrequency }
        var labels: [Double] = []
        for candidate in candidates {
            if let last = labels.last, x(candidate) - x(last) < 45 { continue }
            if x(maximumFrequency) - x(candidate) < 45 { continue }
            labels.append(candidate)
        }
        labels.append(maximumFrequency)
        for frequency in labels {
            let label = frequency >= 1000 ? String(format: "%gk", frequency / 1000) : String(format: "%g", frequency)
            context.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundColor(AuralStyle.secondary),
                         at: CGPoint(x: x(frequency), y: size.height - 10), anchor: frequency == maximumFrequency ? .trailing : .center)
        }
    }
}
