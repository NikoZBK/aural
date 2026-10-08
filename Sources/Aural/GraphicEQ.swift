import Foundation

/// Each of the ten graphic sliders sets the level heard at its band centre.
///
/// The bands are Q 1.4 peaks an octave apart, so neighbours overlap: used directly
/// as gains, ten +6 dB sliders would measure +8.9 dB near 500 Hz. Band
/// gains are solved instead, so the combined response at every centre equals its slider.
enum GraphicEQ {
    static let frequencies: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let q = 1.4

    /// One band's level in dB: the analog prototype of the engine's peak filter.
    static func level(band: Int, gain: Double, at frequency: Double) -> Double {
        let x = frequency / frequencies[band], a2 = pow(10, gain / 20), u = 1 - x * x, r = x * x / (q * q)
        return 10 * log10((u * u + a2 * r) / (u * u + r / a2))
    }

    /// Band gains for filters that have no fixed sample rate, such as a graphic
    /// profile converted to parametric filters or exported as text.
    static func bandGains(for sliders: [Double]) -> [Double] {
        cache.value(for: sliders, rate: 0) { solve(sliders, bands: Array(sliders.indices), level: level) }
    }

    /// Band gains for one sample rate. `level` is the engine's response to one band;
    /// bands at or above 0.49 × rate, which the engine disables, are left at 0 dB.
    static func bandGains(for sliders: [Double], rate: Double, level: (_ band: Int, _ gain: Double, _ frequency: Double) -> Double) -> [Double] {
        cache.value(for: sliders, rate: rate) {
            solve(sliders, bands: sliders.indices.filter { frequencies[$0] < rate * 0.49 }, level: level)
        }
    }

    /// Sliders that reproduce raw band gains, as Aural 1.3 and earlier stored them: their
    /// combined level at each centre, in 0.1 dB steps. Nil when one leaves the ±12 dB slider range.
    static func sliders(forBandGains gains: [Double]) -> [Double]? {
        guard gains.count == frequencies.count, gains.allSatisfy(\.isFinite) else { return nil }
        let sliders = frequencies.map { frequency in
            (gains.indices.reduce(0) { $0 + level(band: $1, gain: gains[$1], at: frequency) } * 10).rounded() / 10 + 0
        }
        return sliders.allSatisfy { abs($0) <= 12 } ? sliders : nil
    }

    /// Newton's method on the dB levels at the centres. The analog prototype's analytic
    /// Jacobian is exact for `level` above and close enough for a digital filter's
    /// response that the solution converges within ten steps at any sample rate.
    private static func solve(_ sliders: [Double], bands: [Int], level: (Int, Double, Double) -> Double) -> [Double] {
        guard sliders.count == frequencies.count, sliders.allSatisfy(\.isFinite) else { return sliders }
        var gains = Array(repeating: 0.0, count: sliders.count)
        for band in bands { gains[band] = sliders[band] }
        for _ in 0..<50 {
            var jacobian = bands.map { row in bands.map { column -> Double in
                let x = frequencies[row] / frequencies[column], a2 = pow(10, gains[column] / 20), u = 1 - x * x, r = x * x / (q * q)
                return r / 2 * (a2 / (u * u + a2 * r) + 1 / (a2 * (u * u + r / a2)))
            } }
            var error = bands.map { row in
                sliders[row] - bands.reduce(0) { $0 + level($1, gains[$1], frequencies[row]) }
            }
            guard error.allSatisfy(\.isFinite) else { break }
            if error.allSatisfy({ abs($0) < 1e-9 }) { return gains }
            eliminate(&jacobian, &error)
            for (index, band) in bands.enumerated() { gains[band] += error[index] }
        }
        // Not reached for sliders within ±12 dB; fall back to the sliders as gains.
        return sliders.indices.map { bands.contains($0) ? sliders[$0] : 0 }
    }

    /// Solves matrix × x = vector in place by Gaussian elimination with partial pivoting.
    static func eliminate(_ matrix: inout [[Double]], _ vector: inout [Double]) {
        let count = vector.count
        for column in 0..<count {
            let pivot = (column..<count).max { abs(matrix[$0][column]) < abs(matrix[$1][column]) }!
            matrix.swapAt(column, pivot)
            vector.swapAt(column, pivot)
            for row in (column + 1)..<count where matrix[column][column] != 0 {
                let factor = matrix[row][column] / matrix[column][column]
                for index in column..<count { matrix[row][index] -= factor * matrix[column][index] }
                vector[row] -= factor * vector[column]
            }
        }
        for column in stride(from: count - 1, through: 0, by: -1) {
            for index in (column + 1)..<count { vector[column] -= matrix[column][index] * vector[index] }
            vector[column] /= matrix[column][column]
        }
    }

    /// Response curves request the same profile's filters for every plotted frequency.
    private static let cache = SolutionCache()
}

private final class SolutionCache: @unchecked Sendable {
    private struct Entry { let sliders: [Double], rate: Double, gains: [Double] }
    private let lock = NSLock()
    private var entries: [Entry] = []

    func value(for sliders: [Double], rate: Double, solve: () -> [Double]) -> [Double] {
        lock.lock()
        if let index = entries.firstIndex(where: { $0.sliders == sliders && $0.rate == rate }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            lock.unlock()
            return entry.gains
        }
        lock.unlock()
        let gains = solve()
        lock.lock()
        entries.append(Entry(sliders: sliders, rate: rate, gains: gains))
        if entries.count > 8 { entries.removeFirst() }
        lock.unlock()
        return gains
    }
}
