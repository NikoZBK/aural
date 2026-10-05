import SwiftUI

/// Pointer hover stays transient; keyboard and assistive inspection share a
/// persistent position that is independent of EQ edits and audio processing.
struct ResponseInspection {
    private(set) var fraction: Double?
    func position(maximumFrequency: Double) -> Double { fraction ?? log10(1000 / 20) / log10(maximumFrequency / 20) }
    mutating func setFraction(_ value: Double) { fraction = min(1, max(0, value)) }
    mutating func adjust(by step: Double, maximumFrequency: Double) { setFraction(position(maximumFrequency: maximumFrequency) + step) }
    mutating func clear() { fraction = nil }
}

struct ResponseCurve: View, Equatable {
    let profile: Profile
    let rate: Double
    let bypass: Bool
    let running: Bool
    var comparisonProfile: Profile? = nil
    var selectedBand: Int? = nil
    var selectBand: ((Int) -> Void)? = nil
    var beginDrag: ((Int) -> EQBarBand?)? = nil
    var changeDrag: ((Int, Double, Double) -> Bool)? = nil
    var endDrag: ((Int) -> Void)? = nil
    var minimumPlotHeight: CGFloat = 80

    // Meter updates stop at this value-only boundary. Local interaction state lives
    // in the child so changing controls cannot be suppressed by this comparison.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profile == rhs.profile && lhs.rate == rhs.rate && lhs.bypass == rhs.bypass &&
            lhs.running == rhs.running && lhs.comparisonProfile == rhs.comparisonProfile &&
            lhs.selectedBand == rhs.selectedBand && lhs.minimumPlotHeight == rhs.minimumPlotHeight &&
            (lhs.selectBand == nil) == (rhs.selectBand == nil) && (lhs.beginDrag == nil) == (rhs.beginDrag == nil)
    }
    var body: some View {
        InteractiveResponseCurve(profile: profile, rate: rate, bypass: bypass, running: running,
                                 comparisonProfile: comparisonProfile, selectedBand: selectedBand, selectBand: selectBand,
                                 beginDrag: beginDrag, changeDrag: changeDrag, endDrag: endDrag, minimumPlotHeight: minimumPlotHeight)
    }
}

private struct InteractiveResponseCurve: View {
    let profile: Profile
    let rate: Double
    let bypass: Bool
    let running: Bool
    let comparisonProfile: Profile?
    let selectedBand: Int?
    let selectBand: ((Int) -> Void)?
    let beginDrag: ((Int) -> EQBarBand?)?
    let changeDrag: ((Int, Double, Double) -> Bool)?
    let endDrag: ((Int) -> Void)?
    let minimumPlotHeight: CGFloat
    @State private var drag: CurveDrag?
    @State private var dragRejected = false
    @Environment(\.self) private var environment
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @State private var hoverFraction: Double?
    @State private var inspection = ResponseInspection()
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var plotFocused: Bool
    @State private var showFilters = false
    @State private var channel = ResponseChannel.both
    @State private var result: AnalysisResult?
    @State private var showHarman = true
    @State private var chosenHarmanTarget: HarmanTarget?
    @State private var harmanReference: HarmanReference?
    @State private var harmanError: String?

    private var harmanTarget: HarmanTarget { chosenHarmanTarget ?? HarmanTarget.suggested(for: profile) }
    private var reference: HarmanReference? { showHarman && harmanReference?.target == harmanTarget ? harmanReference : nil }
    private struct ReferenceRequest: Equatable { let target: HarmanTarget; let enabled: Bool }
    private var referenceRequest: ReferenceRequest { ReferenceRequest(target: harmanTarget, enabled: showHarman) }

    private struct Input: Equatable, Sendable {
        let profile: Profile
        let rate: Double
        let bypass: Bool
        let comparison: Profile?
    }
    private struct AnalysisResult {
        let input: Input
        let analysis: ResponseAnalysis
    }
    private var input: Input { Input(profile: profile, rate: rate, bypass: bypass, comparison: comparisonProfile) }
    // During a drag retain the last completed trace and the original scale so
    // background analysis cannot detach the active pointer gesture. Points use
    // current values; the worker replaces the trace as results become available.
    private var analysis: ResponseAnalysis? { result?.input == input || drag != nil ? result?.analysis : nil }
    private var hasChannelFilters: Bool {
        ((profile.filters ?? []) + (comparisonProfile?.filters ?? [])).contains {
            $0.enabled && $0.effectiveChannel != .stereo
        }
    }

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
    private var inspectionPosition: Double { inspection.position(maximumFrequency: maximumFrequency) }
    private var inspectedFrequency: Double { frequency(at: hoverFraction ?? inspectionPosition) }
    private var inspectionValue: String {
        // The slider's value describes its own position. Pointer hover is a
        // separate visual readout and must not change the spoken slider value.
        let frequency = frequency(at: inspectionPosition)
        let gains = displayedChannels.map { channel in
            channel.label + String(format: " %+.2f decibels", response(at: frequency, channel: channel))
        }.joined(separator: ", ")
        let targetValue = reference?.decibels(at: frequency).map {
            String(format: ", %@ acoustic target %+.2f decibels relative to 1 kilohertz", harmanTarget.label, $0)
        } ?? ""
        return String(format: "%.0f hertz, ", frequency) + gains + (bypass ? ", bypassed" : (running ? ", processing" : ", preview")) + targetValue
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            AuralSectionLabel(title: "EQ curve", systemImage: "waveform.path").fixedSize()
            if hasChannelFilters {
                Picker("Response channel", selection: $channel) {
                    ForEach(ResponseChannel.allCases, id: \.self) { channel in
                        Text(channel.label).tag(channel)
                    }
                }.pickerStyle(.segmented).labelsHidden().auralControlSize(.small)
                    .auralFrame(width: 116, height: 22)
                    .help("Inspect left and right independently. Left uses your accent color; right is dotted blue. Peak/headroom always covers both channels.")
            }
            Spacer(minLength: 8)
            if comparisonProfile != nil {
                Group {
                    if compact { Image(systemName: "line.diagonal").accessibilityLabel("A/B comparison curve") }
                    else { Label("A/B", systemImage: "line.diagonal") }
                }.fixedSize().foregroundStyle(AuralStyle.secondary)
                    .help("Dashed line: the captured comparison EQ, including its preamp.")
            }
            Menu {
                Toggle("Show Harman reference", isOn: $showHarman)
                Divider()
                Picker("Harman target", selection: $chosenHarmanTarget) {
                    Text("Automatic (\(HarmanTarget.suggested(for: profile).label))").tag(Optional<HarmanTarget>.none)
                    ForEach(HarmanTarget.allCases, id: \.self) { target in Text(target.label).tag(Optional(target)) }
                }
                Divider()
                Link("View published target data", destination: harmanTarget.sourceURL)
            } label: {
                Text("Harman").foregroundStyle(showHarman ? AuralStyle.plotColors[2] : AuralStyle.secondary)
            }.menuStyle(.borderlessButton).fixedSize().disabled(drag != nil)
                .accessibilityLabel("Harman acoustic reference")
                .help("Display a Harman acoustic target normalized to 0 dB at 1 kHz. It is a visual reference; the solid EQ curve shows gain, not a measured headphone response. The reference never changes audio.")
            Toggle(isOn: $showFilters) {
                if compact { Image(systemName: "line.3.horizontal.decrease") }
                else { Text("Filter curves") }
            }
            .toggleStyle(.button).auralControlSize(.small).fixedSize()
            .accessibilityLabel("Filter curves")
            .disabled(bypass)
            .help("Overlay each enabled filter without preamp. Disabled filters are excluded.")
        }.auralFont(size: 11, weight: .medium)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                header(compact: false)
                header(compact: true)
            }.auralFrame(minHeight: 24).fixedSize(horizontal: false, vertical: true)
            // Canvas and curve gestures share one logical coordinate system.
            // Only this pure SwiftUI drawing scales geometrically; AppKit-backed
            // controls above and below it use explicit font and frame sizes.
            InterfaceZoomLayout(scale: interfaceScale) {
                GeometryReader { geometry in
                    if let analysis {
                        let referenceSamples = reference?.plottedSamples(maximumFrequency: maximumFrequency) ?? []
                        let scale = drag?.scale ?? analysis.scale(showFilters: showFilters, channel: channel, referenceValues: referenceSamples.map(\.decibels))
                        let drawing = ResponsePlotDrawing(analysis: analysis, scale: scale, profile: profile,
                                                          rate: rate, bypass: bypass, channel: channel,
                                                          showFilters: showFilters, hoverFraction: hoverFraction ?? inspection.fraction, highContrast: contrast == .increased,
                                                          referenceSamples: referenceSamples)
                        ZStack(alignment: .topLeading) {
                            ResponseCanvas(drawing: drawing)
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    hoverFraction = min(1, max(0, (location.x - 44) / max(1, geometry.size.width - 62)))
                                case .ended: hoverFraction = nil
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(plotFocused ? Color.primary : .clear, lineWidth: 2))
                            .focusable().focused($plotFocused)
                            .onKeyPress(.rightArrow) { inspect(by: 0.025); return .handled }
                            .onKeyPress(.leftArrow) { inspect(by: -0.025); return .handled }
                            .onExitCommand { inspection.clear(); plotFocused = false }
                            .accessibilityRepresentation {
                                Slider(value: Binding(get: { inspectionPosition }, set: { inspection.setFraction($0); hoverFraction = nil }), in: 0...1, step: 0.025) {
                                    Text("Equalizer response")
                                }
                                .accessibilityLabel("Equalizer response, 20 to \(maximumFrequency) hertz, \(scale.lower) to \(scale.upper) decibels")
                                .accessibilityValue(inspectionValue)
                                .accessibilityHint("Left and Right arrows inspect frequencies. Escape clears inspection. This does not change your EQ.")
                                .accessibilityAdjustableAction { direction in
                                    switch direction {
                                    case .increment: inspect(by: 0.025)
                                    case .decrement: inspect(by: -0.025)
                                    @unknown default: break
                                    }
                                }
                            }
                            .accessibilitySortPriority(Double((profile.filters?.count ?? profile.gains.count) + 1))
                            if let selectBand {
                                ForEach(EQBarBand.bands(in: profile), id: \.index) { band in
                                    if (20...maximumFrequency).contains(band.frequency), channel.includes(band.filter?.effectiveChannel ?? .stereo) {
                                        filterPoint(band, selectBand: selectBand, scale: scale, size: geometry.size)
                                    }
                                }
                            }
                        }.coordinateSpace(name: "response-plot").clipped()
                            .accessibilityElement(children: .contain).accessibilityLabel("EQ curve")
                    } else {
                        Text("Updating curve…").font(.caption).foregroundStyle(AuralStyle.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .environment(\.auralInterfaceScale, 1)
                .scaleEffect(interfaceScale, anchor: .topLeading)
            }
            .auralFrame(minHeight: minimumPlotHeight)

            if let reference {
                Text("Dashed: \(reference.target.label) acoustic target · 0 dB at 1 kHz. Solid: EQ gain.")
                    .auralFont(size: 10).foregroundStyle(AuralStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let harmanError, showHarman {
                Text(harmanError).auralFont(size: 10).foregroundStyle(AuralStyle.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                if hoverFraction != nil || inspection.fraction != nil {
                    Text(hoverReadout)
                        .foregroundStyle(Color.primary)
                } else {
                    Text(bypass ? "Bypassed · 0 dB" : String(format: "%g kHz · %@", rate / 1000, running ? "Processing" : "Preview"))
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
            }.auralFont(size: 10, weight: .medium, design: .monospaced).lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { finishDrag() }
        .auralAnnouncement(harmanError)
        .task(id: referenceRequest) {
            let request = referenceRequest
            harmanError = nil
            guard request.enabled else { harmanReference = nil; return }
            do {
                let loaded = try await HarmanReferenceLibrary.shared.reference(request.target)
                try Task.checkCancellation()
                harmanReference = loaded
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                harmanReference = nil; harmanError = "Could not load Harman reference: " + error.localizedDescription
            }
        }
        .task(id: input) {
            let input = input
            let updated = await EQAnalysisWorker.shared.calculate {
                ResponseAnalysis(profile: input.profile, rate: input.rate, bypass: input.bypass, comparisonProfile: input.comparison)
            }
            guard !Task.isCancelled, let updated else { return }
            result = AnalysisResult(input: input, analysis: updated)
        }

    }

    private func filterPoint(_ band: EQBarBand, selectBand: @escaping (Int) -> Void, scale: ResponseScale, size: CGSize) -> some View {
        let responseChannel: ImportedFilter.Channel = band.filter?.effectiveChannel == .right || channel == .right ? .right : .left
        let gain = response(at: band.frequency, channel: responseChannel)
        let selected = selectedBand == band.index
        let states: [String?] = [selected ? "Selected" : nil, band.filter?.enabled == false ? "Bypassed" : nil]
        let help = band.filter == nil ? "Click to edit. Drag vertically to change gain." : band.filter?.kind.usesGain == false ? "Click to edit. Drag horizontally to change frequency." : "Click to edit. Drag horizontally for frequency and vertically for gain."
        return Button { selectBand(band.index) } label: {
            Text("\(band.index + 1)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                .frame(width: 22, height: 22)
                .background(selected ? AuralStyle.accent : AuralStyle.surface, in: Circle())
                .overlay(Circle().strokeBorder(AuralStyle.accent, style: StrokeStyle(lineWidth: 1, dash: band.filter?.enabled == false ? [2, 2] : [])))
        }.buttonStyle(.plain)
            .foregroundStyle(selected ? AuralStyle.accentForeground(in: environment) : Color.primary)
            .position(x: 44 + log10(band.frequency / 20) / frequencySpan * max(1, size.width - 62),
                      y: 14 + min(1, max(0, scale.fraction(gain))) * max(1, size.height - 41))
            .zIndex(selected ? 1 : 0)
            .accessibilityLabel(String(format: "Select filter %d, %.0f hertz", band.index + 1, band.frequency))
            .accessibilityValue(states.compactMap { $0 }.joined(separator: ", "))
            .accessibilitySortPriority(Double((profile.filters?.count ?? profile.gains.count) - band.index))
            .accessibilityHint("Opens the exact filter controls below the curve")
            .help(help)
            .highPriorityGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("response-plot"))
                .onChanged { event in
                    guard !dragRejected else { return }
                    if drag == nil {
                        guard let currentBand = beginDrag?(band.index) else { dragRejected = true; return }
                        drag = CurveDrag(band: currentBand, scale: scale, size: size, maximumFrequency: maximumFrequency)
                    }
                    guard let drag else { return }
                    let values = drag.values(translation: event.translation)
                    if changeDrag?(drag.band.index, values.frequency, values.gain) != true { dragRejected = true }
                }
                .onEnded { _ in finishDrag() })
    }

    private func inspect(by step: Double) {
        inspection.adjust(by: step, maximumFrequency: maximumFrequency)
        hoverFraction = nil
    }

    private func finishDrag() {
        let index = drag?.band.index
        drag = nil
        dragRejected = false
        if let index { endDrag?(index) }
    }

}

/// Canvas receives one immutable render value. Its closure never reaches back into
/// a View's State storage, which can otherwise leave its retained drawing one edit behind.
private struct ResponseCanvas: View {
    let drawing: ResponsePlotDrawing
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        // An unchanged EQ still needs to redraw when the inherited appearance changes.
        Canvas { [drawing] context, size in
            drawing.draw(context: context, size: size)
        }.environment(\.colorScheme, colorScheme)
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
    let highContrast: Bool
    let referenceSamples: [HarmanReference.Sample]

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
        channel == .right && !bypass ? AuralStyle.plotColors[1] : color
    }

    func draw(context: GraphicsContext, size: CGSize) {
        let left = 44.0, right = size.width - 18, top = 14.0, bottom = size.height - 27
        let width = max(1, right - left), height = max(1, bottom - top)
        func x(_ frequency: Double) -> Double { left + log10(frequency / 20) / frequencySpan * width }
        func y(_ decibels: Double) -> Double { top + scale.fraction(decibels) * height }
        func line(from: CGPoint, to: CGPoint) -> Path {
            var path = Path(); path.move(to: from); path.addLine(to: to); return path
        }
        func curve(_ values: [Double], frequencies: [Double]? = nil) -> Path {
            var path = Path()
            for (index, point) in zip(frequencies ?? analysis.frequencies, values).enumerated() {
                let position = CGPoint(x: x(point.0), y: y(point.1))
                if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
            }
            return path
        }

        for db in scale.ticks {
            context.stroke(line(from: CGPoint(x: left, y: y(db)), to: CGPoint(x: right, y: y(db))),
                           with: .color(AuralStyle.grid.opacity(db == 0 ? (highContrast ? 0.6 : 0.22) : (highContrast ? 0.2 : 0.06))), lineWidth: 1)
            context.draw(Text(db == 0 ? "0" : String(format: "%+.0f", db))
                .font(.system(size: 9, design: .monospaced)).foregroundColor(AuralStyle.secondary),
                at: CGPoint(x: left - 9, y: y(db)), anchor: .trailing)
        }
        for decade in [10.0, 100, 1000, 10000] {
            for multiple in 1...9 {
                let frequency = decade * Double(multiple)
                guard (20...maximumFrequency).contains(frequency) else { continue }
                context.stroke(line(from: CGPoint(x: x(frequency), y: top), to: CGPoint(x: x(frequency), y: bottom)),
                               with: .color(AuralStyle.grid.opacity(multiple == 1 ? (highContrast ? 0.3 : 0.09) : (highContrast ? 0.12 : 0.03))), lineWidth: 1)
            }
        }

        if !referenceSamples.isEmpty {
            context.stroke(curve(referenceSamples.map(\.decibels), frequencies: referenceSamples.map(\.frequency)),
                           with: .color(AuralStyle.plotColors[2]),
                           style: StrokeStyle(lineWidth: highContrast ? 2.5 : 1.7, dash: [8, 3, 2, 3]))
        }
        if showFilters {
            for trace in analysis.visibleFilters(channel: channel) {
                let traceColor = AuralStyle.plotColors[trace.index % AuralStyle.plotColors.count]
                context.stroke(curve(trace.values), with: .color(traceColor), lineWidth: highContrast ? 2 : 1)
            }
        }
        for channel in displayedChannels {
            let traceColor = color(for: channel)
            let values = channel == .right ? analysis.right : analysis.left
            let reference = channel == .right ? analysis.comparisonRight : analysis.comparisonLeft
            if let reference {
                context.stroke(curve(reference), with: .color(traceColor),
                               style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            }
            let combined = curve(values)
            var fill = combined
            fill.addLine(to: CGPoint(x: right, y: y(0)))
            fill.addLine(to: CGPoint(x: left, y: y(0)))
            fill.closeSubpath()
            context.fill(fill, with: .color(traceColor.opacity(0.045)))
            context.stroke(combined, with: .color(traceColor),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: channel == .right ? [2, 3] : []))
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
