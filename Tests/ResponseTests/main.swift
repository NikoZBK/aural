import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-8 }

let flat = ResponseAnalysis(profile: Profile(), rate: 48000, bypass: false)
require(flat.frequencies.first == 20 && near(flat.frequencies.last!, 20000), "Graph must cover the audible range")
require(flat.combined.allSatisfy { near($0, 0) } && near(flat.peak, 0), "Flat EQ must have unity response and zero peak gain")
require(flat.filters.count == 10, "Graphic mode must expose its actual ten DSP filters")
let flatScale = flat.scale(showFilters: false)
require(flatScale.lower == -12 && flatScale.upper == 12 && flatScale.ticks.contains(0), "Flat response must have readable bounds and a zero reference")

let narrowFilter = ImportedFilter(kind: .peak, frequency: 1733, gain: 20, q: 50, enabled: true)
let narrowProfile = Profile(preamp: -4, filters: [narrowFilter])
let narrow = ResponseAnalysis(profile: narrowProfile, rate: 48000, bypass: false)
let center = narrow.frequencies.firstIndex(of: 1733)!
require(near(narrow.combined[center], 16) && near(narrow.peak, 16), "Sampling must retain a narrow peak at its exact center")
require(near(narrow.filters[0].values[center], 20), "Individual filter curves must exclude preamp")
for index in stride(from: 0, to: narrow.frequencies.count, by: 23) {
    require(near(narrow.combined[index], narrowProfile.response(narrow.frequencies[index], rate: 48000)), "Sampled graph must use the audio engine's response")
}

var disabledProfile = narrowProfile
disabledProfile.filters?[0].enabled = false
let disabled = ResponseAnalysis(profile: disabledProfile, rate: 48000, bypass: false)
require(disabled.filters.isEmpty && disabled.combined.allSatisfy { near($0, -4) }, "Disabled filters must disappear without changing preamp")
let bypass = ResponseAnalysis(profile: narrowProfile, rate: 48000, bypass: true)
require(bypass.filters.isEmpty && bypass.combined.allSatisfy { $0 == 0 } && bypass.peak == 0, "Bypass must render unity without active filters")

let extreme = ResponseAnalysis(profile: Profile(preamp: -60, filters: [ImportedFilter(kind: .notch, frequency: 1000, gain: 0, q: 20, enabled: true)]), rate: 48000, bypass: false)
let extremeScale = extreme.scale(showFilters: false)
require(extreme.combined.allSatisfy(\.isFinite), "Exact notch centers must remain finite")
require(extremeScale.lower <= extreme.combined.min()! && extremeScale.upper >= extreme.combined.max()!, "Auto scale must include responses beyond the old +/-24 dB range")
require(extremeScale.ticks.contains(0) && extremeScale.ticks.count <= 9, "Large ranges must retain readable ticks and the unity reference")
require(near(extremeScale.fraction(extremeScale.lower), 1) && near(extremeScale.fraction(extremeScale.upper), 0), "Plot bounds must map to bottom and top exactly")

let shifted = Profile(preamp: -40, filters: [narrowFilter])
let shiftedPlot = ResponseAnalysis(profile: shifted, rate: 48000, bypass: false)
let shiftedCombinedScale = shiftedPlot.scale(showFilters: false)
let shiftedFilterScale = shiftedPlot.scale(showFilters: true)
require(shiftedFilterScale.upper > shiftedCombinedScale.upper && shiftedFilterScale.upper >= shiftedPlot.filters[0].values.max()!,
        "Enabling filter overlays must expand bounds to include filters before preamp")
let comparison = ResponseAnalysis(profile: Profile(), rate: 48000, bypass: true, comparisonProfile: narrowProfile)
require(comparison.comparison != nil && comparison.scale(showFilters: false).upper >= 16, "Captured comparison must retain its own EQ and preamp while current EQ is bypassed")
let referenceCenter = comparison.frequencies.firstIndex(of: 1733)!
require(near(comparison.comparison![referenceCenter], 16), "Reference filter centers must also be sampled exactly")
let lowRate = ResponseAnalysis(profile: Profile(), rate: 32000, bypass: false)
require(near(lowRate.maximumFrequency, 15680) && lowRate.filters.count == 9, "Graph must honor sample rate and disabled Nyquist bands")

let leftBoost = ImportedFilter(kind: .peak, frequency: 1000, gain: 12, q: 3, enabled: true, channel: .left)
let rightCut = ImportedFilter(kind: .peak, frequency: 1000, gain: -18, q: 3, enabled: true, channel: .right)
let splitProfile = Profile(preamp: -3, filters: [leftBoost, rightCut])
let split = ResponseAnalysis(profile: splitProfile, rate: 48000, bypass: false)
let splitCenter = split.frequencies.firstIndex(of: 1000)!
require(split.hasChannelFilters && near(split.left[splitCenter], 9) && near(split.right[splitCenter], -21), "Channel-specific filters must retain distinct left and right responses")
require(near(split.combined[splitCenter], 9) && near(split.peak, 9), "Peak envelope must cover the louder channel without summing channel-specific filters")
require(split.scale(showFilters: false).lower <= -21 && split.scale(showFilters: false, channel: .left).lower == -12, "Both-channel scale must include deep right cuts that are absent from the left channel")
require(split.visibleFilters(channel: .left).map(\.index) == [0] && split.visibleFilters(channel: .right).map(\.index) == [1], "Channel inspection must exclude filters belonging to the other channel")
require(near(split.filters[1].values[splitCenter], -18), "Individual right-channel cuts must not disappear behind the unaffected left channel")
for index in stride(from: 0, to: split.frequencies.count, by: 29) {
    let frequency = split.frequencies[index]
    require(near(split.left[index], splitProfile.response(frequency, rate: 48000, channel: .left)), "Left curve must match the exact engine channel response")
    require(near(split.right[index], splitProfile.response(frequency, rate: 48000, channel: .right)), "Right curve must match the exact engine channel response")
}
let splitReference = ResponseAnalysis(profile: Profile(), rate: 48000, bypass: false, comparisonProfile: splitProfile)
let splitReferenceCenter = splitReference.frequencies.firstIndex(of: 1000)!
require(splitReference.hasChannelFilters && near(splitReference.comparisonLeft![splitReferenceCenter], 9)
        && near(splitReference.comparisonRight![splitReferenceCenter], -21), "A captured reference must preserve its independent channel responses")
require(splitReference.scale(showFilters: false, channel: .right).lower <= -21, "Reference bounds must follow the inspected channel")
let splitBypass = ResponseAnalysis(profile: splitProfile, rate: 48000, bypass: true)
require(splitBypass.left.allSatisfy { $0 == 0 } && splitBypass.right.allSatisfy { $0 == 0 }, "Bypass must flatten both channels")
var effectsProfile = splitProfile
effectsProfile.stereo = StereoSettings(leftTrimDB: 12, rightTrimDB: -12, balance: 0.5, width: 2)
let effectsPlot = ResponseAnalysis(profile: effectsProfile, rate: 48000, bypass: false)
require(effectsPlot.left == split.left && effectsPlot.right == split.right, "EQ plot must not falsely include signal-dependent stereo effects")

print("PASS response sampling, exact high-Q centers, DSP parity, auto dB bounds, disabled filters, bypass, preamp, comparison, independent L/R curves, channel-aware overlays, and Nyquist handling")
