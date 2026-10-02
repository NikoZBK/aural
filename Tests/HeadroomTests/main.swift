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
