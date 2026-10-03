import Foundation
import DSP

enum Headroom {
    /// Estimate steady-state EQ gain over the whole digital audio band. Exact filter
    /// centers and refined local peaks keep narrow boosts between grid points visible.
    /// This is not a bound on transients or intersample peaks.
    static func preamp(for profile: Profile, rate: Double) -> Double {
        let filters = profile.dspFilters(rate: rate)
        let nyquist = rate / 2
        var frequencies = (0...2048).map { pow(nyquist, Double($0) / 2048) }
        frequencies += [0, nyquist]
        frequencies += filters.filter { !$0.disabled && $0.frequency < nyquist }.map(\.frequency)
        frequencies = Array(Set(frequencies)).sorted()
        func response(_ frequency: Double) -> Double {
            eq_response_filters(frequency, rate, filters, UInt32(filters.count), 0)
        }
        let values = sampledResponse(frequencies, rate: rate, filters: filters, preamp: 0, channel: UInt32(EQChannelStereo))
        var maximum = max(0, values.max() ?? 0)
        for index in 1..<(frequencies.count - 1) where
            values[index] >= values[index - 1] && values[index] >= values[index + 1] &&
            (values[index] > values[index - 1] || values[index] > values[index + 1]) {
            // Refine the combined curve, whose maximum can fall between filter centers.
            var lower = frequencies[index - 1], upper = frequencies[index + 1]
            let ratio = (sqrt(5.0) - 1) / 2
            var left = upper - ratio * (upper - lower), right = lower + ratio * (upper - lower)
            var leftGain = response(left), rightGain = response(right)
            for _ in 0..<28 {
                if leftGain < rightGain {
                    lower = left; left = right; leftGain = rightGain
                    right = lower + ratio * (upper - lower); rightGain = response(right)
                } else {
                    upper = right; right = left; rightGain = leftGain
                    left = upper - ratio * (upper - lower); leftGain = response(left)
                }
            }
            maximum = max(maximum, leftGain, rightGain)
        }
        maximum = max(0, maximum + profile.stereoSettings.headroomGainDB)
        return min(profile.preampRange.upperBound, max(profile.preampRange.lowerBound, -ceil(maximum * 10) / 10))
    }
}
