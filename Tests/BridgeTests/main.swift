import Foundation
import DSP

func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
for kind in ImportedFilter.Kind.allCases {
    let gain = kind.usesGain ? 6.0 : 0.0
    let filter = ImportedFilter(kind: kind, frequency: 1000, gain: gain, q: 0.7071067811865476, enabled: true)
    var profile = Profile(preamp: -3, filters: [filter])
    _ = try profile.validated()
    let enabled = profile.dspFilters(rate: 48000)
    require(enabled.count == 1 && !enabled[0].disabled, "Enabled state lost at DSP bridge")
    require(enabled[0].gain == gain, "Gain changed at DSP bridge")
    let response = profile.response(1000, rate: 48000)
    switch kind {
    case .peak: require(abs(response - 3) < 0.001, "Peak bridge mismatch")
    case .lowShelf, .highShelf: require(abs(response) < 0.001, "Shelf bridge mismatch")
    case .lowPass, .highPass: require(abs(response + 6.01029995664) < 0.001, "Pass bridge mismatch")
    case .bandPass, .allPass: require(abs(response + 3) < 0.001, "Unity-peak bridge mismatch")
    case .notch: require(response < -100 && response.isFinite, "Notch bridge mismatch")
    }
    profile.filters?[0].enabled = false
    let disabled = profile.dspFilters(rate: 48000)
    require(disabled[0].disabled && disabled[0].gain == gain, "Disabled gain was discarded")
    require(abs(profile.response(1000, rate: 48000) + 3) < 1e-9, "Disabled filter affects response")
    guard let engine = eq_create(48000, 0) else { fatalError("Engine allocation failed") }
    require(eq_update_filters(engine, disabled, UInt32(disabled.count), profile.preamp, false), "Bridge output rejected by engine")
    eq_destroy(engine)
}
let fixed = Profile.builtInPresets["Warm"]!
let at32k = fixed.dspFilters(rate: 32000)
require(at32k.last?.disabled == true && at32k.dropLast().allSatisfy { !$0.disabled }, "Legacy Nyquist band behavior changed")
let at48k = fixed.dspFilters(rate: 48000)
require(at48k.allSatisfy { !$0.disabled }, "Valid legacy band disabled")
print("PASS Swift/C filter mapping, disabled-state preservation, finite notch graph and legacy Nyquist handling")
