import SwiftUI

struct ResponseCurve: View, Equatable {
    let profile: Profile
    let rate: Double
    let bypass: Bool
    let running: Bool
    @State private var hoverFraction: Double?

    // Peak metering publishes ten times a second; it must not redraw the response.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profile == rhs.profile && lhs.rate == rhs.rate && lhs.bypass == rhs.bypass && lhs.running == rhs.running
    }
    private var color: Color { bypass ? AuralStyle.secondary : AuralStyle.accent }
    private var maximumFrequency: Double { min(20000, rate * 0.49) }
    private var frequencySpan: Double { log10(maximumFrequency / 20) }
    private var frequencyTicks: [(Double, String)] {
        [(20.0, "20 Hz"), (100, "100"), (1000, "1k"), (10000, "10k")].filter { $0.0 < maximumFrequency } +
            [(maximumFrequency, String(format: "%gk", maximumFrequency / 1000))]
    }
    private func response(at frequency: Double) -> Double {
        bypass ? 0 : profile.response(frequency, rate: rate)
    }

    private var inspectionValue: String {
        if let hoverFraction {
            let frequency = 20 * pow(10, hoverFraction * frequencySpan)
            return String(format: "%.0f hertz, %+.2f decibels", frequency, response(at: frequency))
        }
        return bypass ? "Bypassed, flat response" : "Includes preamp, \(rate / 1000) kilohertz \(running ? "processing" : "preview")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AuralSectionLabel(title: "Frequency response")
                Spacer()
                if let hoverFraction {
                    let frequency = 20 * pow(10, hoverFraction * frequencySpan)
                    Text(String(format: "%.0f Hz  ·  %+.2f dB", frequency, response(at: frequency)))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(color)
                } else {
                    Text(bypass ? "Bypass · flat response" : String(format: "%g kHz%@", rate / 1000, running ? "" : " preview"))
                        .font(.system(size: 11)).foregroundStyle(AuralStyle.secondary)
                }
            }.frame(height: 16)
            GeometryReader { geometry in
                Canvas { context, size in
                    let left = 35.0, right = size.width - 18, top = 8.0, bottom = size.height - 24
                    let width = right - left
                    func y(_ db: Double) -> Double { top + (24 - db) / 48 * (bottom - top) }
                    func x(_ frequency: Double) -> Double { left + log10(frequency / 20) / frequencySpan * width }
                    for db in [-24.0, -12, 0, 12, 24] {
                        var line = Path(); line.move(to: CGPoint(x: left, y: y(db))); line.addLine(to: CGPoint(x: right, y: y(db)))
                        context.stroke(line, with: .color(.white.opacity(db == 0 ? 0.18 : 0.065)), lineWidth: 1)
                        context.draw(Text(String(format: "%+.0f", db)).font(.system(size: 10, design: .monospaced)).foregroundColor(AuralStyle.secondary), at: CGPoint(x: 14, y: y(db)))
                    }
                    for (frequency, _) in frequencyTicks {
                        var line = Path(); line.move(to: CGPoint(x: x(frequency), y: top)); line.addLine(to: CGPoint(x: x(frequency), y: bottom))
                        context.stroke(line, with: .color(.white.opacity(0.055)), lineWidth: 1)
                    }
                    var curve = Path()
                    for i in 0...400 {
                        let frequency = 20 * pow(10, Double(i) / 400 * frequencySpan)
                        let point = CGPoint(x: left + Double(i) / 400 * width, y: y(min(24, max(-24, response(at: frequency)))))
                        if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                    }
                    var fill = curve
                    fill.addLine(to: CGPoint(x: right, y: y(0)))
                    fill.addLine(to: CGPoint(x: left, y: y(0)))
                    fill.closeSubpath()
                    context.fill(fill, with: .color(color.opacity(0.10)))
                    context.stroke(curve, with: .color(color.opacity(0.10)), lineWidth: 6)
                    context.stroke(curve, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    if let hoverFraction {
                        let frequency = 20 * pow(10, hoverFraction * frequencySpan)
                        let point = CGPoint(x: x(frequency), y: y(min(24, max(-24, response(at: frequency)))))
                        var marker = Path(); marker.move(to: CGPoint(x: point.x, y: top)); marker.addLine(to: CGPoint(x: point.x, y: bottom))
                        context.stroke(marker, with: .color(color.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(color))
                    }
                    for (frequency, label) in frequencyTicks {
                        context.draw(Text(label).font(.system(size: 10, design: .monospaced)).foregroundColor(AuralStyle.secondary), at: CGPoint(x: x(frequency), y: size.height - 7), anchor: frequency == maximumFrequency ? .trailing : .center)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverFraction = min(1, max(0, (location.x - 35) / max(1, geometry.size.width - 53)))
                    case .ended: hoverFraction = nil
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Equalizer frequency response, 20 hertz to \(maximumFrequency) hertz, displayed from minus 24 to plus 24 decibels")
        .accessibilityValue(inspectionValue)
        .accessibilityHint("Adjust to inspect the response at different frequencies")
        .accessibilityAdjustableAction { direction in
            let current = hoverFraction ?? log10(1000 / 20) / frequencySpan
            switch direction {
            case .increment: hoverFraction = min(1, current + 0.05)
            case .decrement: hoverFraction = max(0, current - 0.05)
            @unknown default: break
            }
        }
        .help("Combined filter and preamp response. Hover to inspect exact values; the display clips at ±24 dB and ends below the sample rate’s Nyquist limit.")
    }
}
