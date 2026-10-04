import Foundation

/// Freeze the coordinate scale and starting values for one pointer gesture.
/// Translations are always relative to the original point, never accumulated.
struct CurveDrag {
    let band: EQBarBand
    let scale: ResponseScale
    let size: CGSize
    let maximumFrequency: Double

    func values(translation: CGSize) -> (frequency: Double, gain: Double) {
        let span = log10(maximumFrequency / 20)
        let frequency = band.filter == nil || translation.width == 0 ? band.frequency
            : min(maximumFrequency, max(20, band.frequency * pow(10, translation.width / max(1, size.width - 62) * span)))
        let range: ClosedRange<Double> = band.filter == nil ? -12...12 : -30...30
        let gain = band.filter?.kind.usesGain == false || translation.height == 0 ? band.gain
            : min(range.upperBound, max(range.lowerBound, band.gain - translation.height / max(1, size.height - 41) * (scale.upper - scale.lower)))
        return (frequency, gain)
    }
}
