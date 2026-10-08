import Foundation
import DSP

/// Playback gains that put Bypass and the A/B versions at the same estimated
/// loudness. They are never saved in a profile and do not change the EQ curve.
struct LevelMatch: Equatable {
    /// Added to the EQ path. Only the louder A/B version is lowered (≤ 0 dB).
    var eqOffsetDB = 0.0
    /// Applied to the unprocessed signal during Bypass.
    var bypassGainDB = 0.0
    /// False when a limit stopped a gain short of the matching level, so the
    /// versions still differ in estimated loudness.
    var eqOffsetExact = true, bypassGainExact = true

    static let none = LevelMatch()

    init(eqOffsetDB: Double = 0, bypassGainDB: Double = 0, eqOffsetExact: Bool = true, bypassGainExact: Bool = true) {
        self.eqOffsetDB = eqOffsetDB
        self.bypassGainDB = bypassGainDB
        self.eqOffsetExact = eqOffsetExact
        self.bypassGainExact = bypassGainExact
    }

    /// `other` is the A/B version being compared with `current`, if any.
    init(current: Profile, comparedWith other: Profile?) {
        let level = Self.loudnessChange(of: current)
        let wanted = other.map { min(0, Self.loudnessChange(of: $0) - level) } ?? 0
        // A/B lowers by at most 24 dB and never below the engine's -60 dB preamp
        // floor; the engine accepts Bypass gains from -24 to +12 dB.
        let offset = min(0, max(wanted, -24, -60 - current.preamp))
        let bypass = min(12, max(-24, level + offset))
        self.init(eqOffsetDB: offset, bypassGainDB: bypass, eqOffsetExact: offset == wanted, bypassGainExact: bypass == level + offset)
    }

    /// Estimated loudness change in dB for pink noise through the EQ, preamp, and
    /// channel trim/balance, with ITU-R BS.1770 K-weighting. Width, crossfeed,
    /// mono, swap, and delay depend on the program and are not modeled. Analysis uses
    /// 48 kHz, so the estimate does not change with the output's sample rate.
    static func loudnessChange(of profile: Profile) -> Double {
        let filters = profile.dspFilters(rate: rate)
        let left = sampledResponse(frequencies, rate: rate, filters: filters, preamp: profile.preamp, channel: UInt32(EQChannelLeft))
        let right = sampledResponse(frequencies, rate: rate, filters: filters, preamp: profile.preamp, channel: UInt32(EQChannelRight))
        // Matches the engine's per-channel trim and balance gains.
        let stereo = profile.stereoSettings
        let leftGain = pow(10, stereo.leftTrimDB / 20) * (1 - max(0, stereo.balance))
        let rightGain = pow(10, stereo.rightTrimDB / 20) * (1 + min(0, stereo.balance))
        var power = 0.0
        for index in frequencies.indices {
            let channels = pow(10, left[index] / 10) * leftGain * leftGain + pow(10, right[index] / 10) * rightGain * rightGain
            power += weights[index] * channels / 2
        }
        power /= weightTotal
        return power > 0 ? 10 * log10(power) : -120
    }

    private static let rate = 48000.0
    // Equal log spacing gives pink noise's equal power per octave: 1/12 octave, 20 Hz–20 kHz.
    private static let frequencies = (0...120).map { 20 * pow(1000, Double($0) / 120) }
    private static let weights: [Double] = {
        // K-weighting: about +4 dB above 2 kHz and a 38 Hz high-pass.
        let kWeighting = [
            EQFilter(frequency: 1681.974, gain: 3.999843, q: 0.7071752, type: UInt32(EQFilterHighShelf), disabled: false, channel: UInt32(EQChannelStereo)),
            EQFilter(frequency: 38.13547, gain: 0, q: 0.5003270, type: UInt32(EQFilterHighPass), disabled: false, channel: UInt32(EQChannelStereo))
        ]
        return sampledResponse(frequencies, rate: rate, filters: kWeighting, preamp: 0, channel: UInt32(EQChannelLeft)).map { pow(10, $0 / 10) }
    }()
    private static let weightTotal = weights.reduce(0, +)
}
