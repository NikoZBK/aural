import Foundation
import DSP

/// Loudness compensation from the ISO 226:2003 equal-loudness contours.
///
/// Quiet sound loses bass and the highest treble faster than the midrange. At the
/// reference volume the EQ plays as set. Each decibel the output is turned down lowers
/// the listening level by one phon, and the compensation restores the balance of the
/// reference level: the difference between the two contours, relative to 1 kHz.
///
/// macOS applies the output volume after Aural, so the compensation keeps 1 kHz
/// unchanged and raises the bass and treble; peak protection keeps the boost from clipping.
enum Loudness {
    /// ISO 226:2003 table 1: frequency, exponent αf, transfer magnitude LU (dB) and threshold Tf (dB).
    static let frequencies: [Double] = [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630,
                                        800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500]
    private static let exponents: [Double] = [0.532, 0.506, 0.480, 0.455, 0.432, 0.409, 0.387, 0.367, 0.349, 0.330, 0.315,
                                              0.301, 0.288, 0.276, 0.267, 0.259, 0.253, 0.250, 0.246, 0.244, 0.243, 0.243,
                                              0.243, 0.242, 0.242, 0.245, 0.254, 0.271, 0.301]
    private static let magnitudes: [Double] = [-31.6, -27.2, -23.0, -19.1, -15.9, -13.0, -10.3, -8.1, -6.2, -4.5, -3.1,
                                               -2.0, -1.1, -0.4, 0.0, 0.3, 0.5, 0.0, -2.7, -4.1, -1.0, 1.7, 2.5, 1.2,
                                               -2.1, -7.1, -11.2, -10.7, -3.1]
    private static let thresholds: [Double] = [78.5, 68.7, 59.5, 51.1, 44.0, 37.5, 31.5, 26.5, 22.1, 17.9, 14.4, 11.4,
                                               8.6, 6.2, 4.4, 3.0, 2.2, 2.4, 3.5, 1.7, -1.3, -4.2, -6.0, -5.4, -1.5,
                                               6.0, 12.6, 13.9, 12.3]
    static let referenceLevels: [Double] = [70, 75, 80, 85, 90]
    static let defaultReferenceLevel = 80.0
    /// The deepest compensation, 40 phon below the reference: about +21 dB at 20 Hz.
    static let maximumDepth = 40.0
    static let filterCount = bands.count

    /// The sound pressure level in dB of a tone at `frequencies[index]` heard at `phon`: ISO 226:2003 formula (1).
    static func pressure(at index: Int, phon: Double) -> Double {
        let exponent = exponents[index], magnitude = magnitudes[index]
        let a = 4.47e-3 * (pow(10, 0.025 * phon) - 1.15) + pow(0.4 * pow(10, (thresholds[index] + magnitude) / 10 - 9), exponent)
        return 10 / exponent * log10(a) - magnitude + 94
    }

    /// The listening level in phon, in 0.1 phon steps: the reference level less the volume
    /// reduction. Louder than the reference plays as set, and quieter stops at `maximumDepth`.
    static func listeningLevel(volume: Double, referenceVolume: Double, referenceLevel: Double) -> Double {
        let reduction = volume.isNaN ? 0 : min(0, max(-maximumDepth, volume - referenceVolume))
        return ((referenceLevel + reduction) * 10).rounded() / 10
    }

    /// The compensation in dB at each table frequency: how much more each tone needs at
    /// `level` than at `reference` to keep its loudness relative to 1 kHz.
    static func curve(level: Double, reference: Double) -> [Double] {
        let raw = frequencies.indices.map { pressure(at: $0, phon: level) - pressure(at: $0, phon: reference) }
        let center = raw[frequencies.firstIndex(of: 1000)!]
        return raw.map { $0 - center }
    }

    /// The compensation between table frequencies, interpolated on a log-frequency scale.
    /// Outside 20 Hz–12.5 kHz, the standard's range, it holds the end values.
    static func compensation(at frequency: Double, curve: [Double]) -> Double {
        guard frequency > frequencies[0] else { return curve[0] }
        guard let upper = frequencies.firstIndex(where: { $0 >= frequency }) else { return curve[curve.count - 1] }
        let lower = upper - 1
        let t = log(frequency / frequencies[lower]) / log(frequencies[upper] / frequencies[lower])
        return curve[lower] + t * (curve[upper] - curve[lower])
    }

    /// Filters that follow `curve(level:reference:)` within about 1.2 dB from 20 Hz to
    /// 12.5 kHz, or none at or above the reference. A wide 20 Hz peak lifts the deep bass
    /// without boosting subsonic content, octave peaks shape 40 Hz–5 kHz, and a 10 kHz
    /// shelf holds the treble boost to the top of the range.
    static func filters(level: Double, reference: Double) -> [EQFilter] {
        guard level < reference else { return [] }
        let curve = curve(level: level, reference: reference)
        let target = grid.map { compensation(at: $0, curve: curve) }
        guard let gains = fit(target) else { return [] }
        return zip(bands, gains).map { band, gain in
            EQFilter(frequency: band.frequency, gain: gain, q: band.q, type: UInt32(band.shelf ? EQFilterHighShelf : EQFilterPeak),
                     disabled: false, channel: UInt32(EQChannelStereo))
        }
    }

    private static let bands: [(frequency: Double, q: Double, shelf: Bool)] =
        [(frequency: 20, q: 0.7, shelf: false)]
        + [40, 80, 160, 315, 630, 1250, 2500, 5000].map { (frequency: $0, q: 1.4, shelf: false) }
        + [(frequency: 10000, q: 0.707, shelf: true)]
    /// Sixth-octave points from 20 Hz to 12.5 kHz.
    private static let grid: [Double] = (0...55).map { 20 * pow(2, Double($0) / 6) } + [12500]

    /// One band's level in dB: the analog prototype the engine's filters follow at every sample rate.
    private static func level(_ band: Int, gain: Double, at frequency: Double) -> Double {
        let (center, q, shelf) = bands[band]
        let x = frequency / center
        if shelf {
            let a = pow(10, gain / 40), u = sqrt(a) * x / q
            let numerator = (1 - a * x * x) * (1 - a * x * x) + u * u, denominator = (a - x * x) * (a - x * x) + u * u
            return gain / 2 + 10 * log10(numerator / denominator)
        }
        let a2 = pow(10, gain / 20), u = 1 - x * x, r = x * x / (q * q)
        return 10 * log10((u * u + a2 * r) / (u * u + r / a2))
    }

    /// Least-squares band gains for the target levels on `grid`, by Gauss–Newton.
    /// Each band contributes its own term, so its column of the Jacobian needs only that band.
    private static func fit(_ target: [Double]) -> [Double]? {
        var gains = Array(repeating: 0.0, count: bands.count)
        for _ in 0..<30 {
            var columns = [[Double]](), residual = target
            for band in bands.indices {
                var column = [Double]()
                for (point, frequency) in grid.enumerated() {
                    residual[point] -= level(band, gain: gains[band], at: frequency)
                    column.append((level(band, gain: gains[band] + 1e-4, at: frequency) - level(band, gain: gains[band] - 1e-4, at: frequency)) / 2e-4)
                }
                columns.append(column)
            }
            var normal = columns.map { row in columns.map { column in zip(row, column).reduce(0) { $0 + $1.0 * $1.1 } } }
            var step = columns.map { column in zip(column, residual).reduce(0) { $0 + $1.0 * $1.1 } }
            GraphicEQ.eliminate(&normal, &step)
            guard step.allSatisfy(\.isFinite) else { return nil }
            for band in bands.indices { gains[band] += step[band] }
            if step.allSatisfy({ abs($0) < 1e-6 }) { break }
        }
        return gains.allSatisfy({ $0.isFinite && abs($0) <= 30 }) ? gains : nil
    }
}
