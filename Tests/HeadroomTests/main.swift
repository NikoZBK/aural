import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

for rate in [32000.0, 44100, 48000, 96000, 192000] {
    let center = 20 * pow(1000, 600.5 / 1000)
    let narrow = Profile(filters: [ImportedFilter(kind: .peak, frequency: center, gain: 30, q: 50, enabled: true)])
    let preamp = Headroom.preamp(for: narrow, rate: rate)
    require(preamp <= -30 && narrow.response(center, rate: rate, preamp: preamp) <= 0.00001,
            "Auto preamp must account for narrow boosts between grid points at \(rate) Hz")

    for frequency in [12.0, min(22000, rate * 0.48)] {
        let outsidePlot = Profile(filters: [ImportedFilter(kind: .peak, frequency: frequency, gain: 30, q: 50, enabled: true)])
        let preamp = Headroom.preamp(for: outsidePlot, rate: rate)
        require(outsidePlot.response(frequency, rate: rate, preamp: preamp) <= 0.00001,
                "Auto preamp must include enabled filters outside the displayed 20–20k range")
    }
}

let overlap = Profile(filters: [
    ImportedFilter(kind: .peak, frequency: 1260, gain: 20, q: 8, enabled: true, channel: .left),
    ImportedFilter(kind: .peak, frequency: 1300, gain: 20, q: 8, enabled: true, channel: .left),
    ImportedFilter(kind: .peak, frequency: 1600, gain: 30, q: 50, enabled: false, channel: .right)
])
let overlapPreamp = Headroom.preamp(for: overlap, rate: 48000)
for frequency in stride(from: 1200.0, through: 1350, by: 0.1) {
    require(overlap.response(frequency, rate: 48000, preamp: overlapPreamp) <= 0.00001,
            "Auto preamp must cover combined peaks between filter centers")
}
var stereo = overlap
stereo.stereo = StereoSettings(leftTrimDB: 6, width: 2)
let stereoPreamp = Headroom.preamp(for: stereo, rate: 48000)
require(stereoPreamp <= overlapPreamp - 12, "Auto preamp must reserve channel trim and stereo width gain")
require(Headroom.preamp(for: Profile(), rate: 48000) == 0, "Flat EQ must not be attenuated")
let cuts = Profile(preamp: -8, filters: [ImportedFilter(kind: .peak, frequency: 1000, gain: -12, q: 2, enabled: true)])
require(Headroom.preamp(for: cuts, rate: 48000) == 0, "Auto preamp must not boost cut-only EQ")
let extreme = Profile(filters: Array(repeating: ImportedFilter(kind: .peak, frequency: 1000, gain: 30, q: 1, enabled: true), count: 32))
require(Headroom.preamp(for: extreme, rate: 48000) == -60, "Auto preamp must respect profile limits")
print("PASS Auto preamp narrow peaks, full frequency band, overlapping filters, channel/stereo gain, disabled filters, and bounds")

func near(_ value: Double, _ expected: Double, _ tolerance: Double = 0.01) -> Bool { abs(value - expected) <= tolerance }
let flat = Profile()
require(near(LevelMatch.loudnessChange(of: flat), 0) && LevelMatch(current: flat, comparedWith: nil) == .none,
        "Flat EQ must not change Bypass level")
let quieter = Profile(preamp: -6)
require(near(LevelMatch.loudnessChange(of: quieter), -6), "Preamp changes loudness one-to-one")
let solo = LevelMatch(current: quieter, comparedWith: nil)
require(solo.eqOffsetDB == 0 && near(solo.bypassGainDB, -6), "Bypass must play at the EQ's estimated loudness")
let quieterA = LevelMatch(current: quieter, comparedWith: flat)
let louderB = LevelMatch(current: flat, comparedWith: quieter)
require(quieterA.eqOffsetDB == 0 && near(quieterA.bypassGainDB, -6), "The quieter A/B version plays unchanged")
require(near(louderB.eqOffsetDB, -6) && near(louderB.bypassGainDB, -6), "The louder A/B version plays at the quieter one's level")
let bass = Profile(filters: [ImportedFilter(kind: .lowShelf, frequency: 100, gain: 6, q: 0.7, enabled: true)])
let treble = Profile(filters: [ImportedFilter(kind: .highShelf, frequency: 3000, gain: 6, q: 0.7, enabled: true)])
let bassLevel = LevelMatch.loudnessChange(of: bass), trebleLevel = LevelMatch.loudnessChange(of: treble)
require(bassLevel > 0.3 && trebleLevel > bassLevel + 1, "K-weighting must count treble boosts as louder than equal bass boosts")
let trim = Profile(stereo: StereoSettings(leftTrimDB: -6))
require(near(LevelMatch.loudnessChange(of: trim), 10 * log10((pow(10, -0.6) + 1) / 2)), "Channel trim must count per channel")
let balance = Profile(stereo: StereoSettings(balance: 1))
require(near(LevelMatch.loudnessChange(of: balance), 10 * log10(0.5)), "Balance must count the silenced channel")
let leftOnly = Profile(filters: [ImportedFilter(kind: .peak, frequency: 1000, gain: 6, q: 0.5, enabled: true, channel: .left)])
let leftLevel = LevelMatch.loudnessChange(of: leftOnly)
require(leftLevel > 0.3 && leftLevel < LevelMatch.loudnessChange(of: Profile(filters: [ImportedFilter(kind: .peak, frequency: 1000, gain: 6, q: 0.5, enabled: true)])),
        "Single-channel filters must affect only that channel's share")
let disabled = Profile(filters: [ImportedFilter(kind: .peak, frequency: 1000, gain: 12, q: 0.5, enabled: false)])
require(near(LevelMatch.loudnessChange(of: disabled), 0), "Disabled filters must not change the estimate")
require(LevelMatch(current: Profile(preamp: -60, filters: []), comparedWith: nil).bypassGainDB == -24, "Bypass gain must respect the engine's lower limit")
require(LevelMatch(current: extreme, comparedWith: nil).bypassGainDB == 12, "Bypass gain must respect the engine's upper limit")
require(LevelMatch(current: flat, comparedWith: Profile(preamp: -60, filters: [])).eqOffsetDB == -24, "A/B matching must respect its limit")
print("PASS level matching: flat EQ, preamp, A/B offsets, K-weighted bass and treble, trim, balance, channel filters, disabled filters, and limits")
