import AppKit

@MainActor func checkAccessibility() {
    var inspection = ResponseInspection()
    for maximum in [8000.0, 20000] {
        inspection.clear()
        let span = log10(maximum / 20)
        let initial = inspection.position(maximumFrequency: maximum)
        require(abs(20 * pow(10, initial * span) - 1000) < 1e-9, "Unadjusted inspection must start at 1 kHz at each supported rate")
        inspection.adjust(by: 0.025, maximumFrequency: maximum)
        require(inspection.fraction == initial + 0.025, "Keyboard inspection must advance from its current position")
        inspection.adjust(by: -0.025, maximumFrequency: maximum)
        require(abs(inspection.position(maximumFrequency: maximum) - initial) < 1e-12, "Opposite inspection steps must return to the same frequency")
        inspection.adjust(by: -10, maximumFrequency: maximum)
        require(inspection.fraction == 0, "Frequency inspection must stop at the low end of the plot")
        inspection.adjust(by: 10, maximumFrequency: maximum)
        require(inspection.fraction == 1, "Frequency inspection must stop at the high end of the plot")
        inspection.setFraction(0.6)
        require(inspection.position(maximumFrequency: maximum) == 0.6, "Assistive slider edits and keyboard inspection must share one position")
        inspection.clear()
        require(inspection.fraction == nil, "Escape must restore the uninspected plot")
    }
    require(AuralAccessibility.balance(0) == "Centered" && AuralAccessibility.balance(-0.4) == "40 percent left" && AuralAccessibility.balance(0.25) == "25 percent right", "Balance must report channel direction rather than normalized slider position")
    require(AuralAccessibility.percentage(1.5) == "150 percent", "Stereo width must describe actual width, including values over 100 percent")
    require(AuralAccessibility.samplePeak(-90) == "Silent" && AuralAccessibility.samplePeak(-6.12345) == "-6.1 decibels relative to full scale", "Meter values must distinguish silence and bounded, readable audio units")
    print("PASS shared keyboard/assistive curve inspection, frequency bounds, reset, balance direction, stereo width, and output units")
}
