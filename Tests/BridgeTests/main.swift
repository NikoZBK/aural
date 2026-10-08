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
require(Profile.maxFilters == Int(EQMaxFilters), "Swift and engine filter limits differ")
let fixed = Profile.builtInPresets["Warm"]!
let at32k = fixed.dspFilters(rate: 32000)
require(at32k.last?.disabled == true && at32k.dropLast().allSatisfy { !$0.disabled }, "Legacy Nyquist band behavior changed")
let at48k = fixed.dspFilters(rate: 48000)
require(at48k.allSatisfy { !$0.disabled }, "Valid legacy band disabled")
print("PASS Swift/C filter mapping, disabled-state preservation, finite notch graph and legacy Nyquist handling")

let legacy = try JSONDecoder().decode(Profile.self, from: Data("{\"gains\":[0,0,0,0,0,0,0,0,0,0],\"preamp\":0}".utf8))
require(legacy.stereo == nil && legacy.stereoSettings.isNeutral, "Legacy profile did not retain neutral stereo")
var stereoProfile = legacy
stereoProfile.stereo = StereoSettings()
require(stereoProfile.hasSameEQ(as: legacy), "Explicit neutral stereo changes preset identity")
stereoProfile.stereo = StereoSettings(leftTrimDB: -3, rightTrimDB: 2, balance: -0.3, width: 1.5,
                                     crossfeed: 0.4, leftDelayMS: 0.25, rightDelayMS: 30,
                                     invertLeft: true, invertRight: false, mono: true)
_ = try stereoProfile.validated()
require(!stereoProfile.hasSameEQ(as: legacy), "Stereo edits must mark a preset as modified")
let encoded = try JSONEncoder().encode(stereoProfile)
require(try JSONDecoder().decode(Profile.self, from: encoded) == stereoProfile, "Stereo profile round-trip lost settings")
var bridgedStereo = stereoProfile.dspStereo
require(bridgedStereo.leftTrimDB == -3 && bridgedStereo.rightTrimDB == 2 && bridgedStereo.balance == -0.3 &&
        bridgedStereo.width == 1.5 && bridgedStereo.crossfeed == 0.4 && bridgedStereo.leftDelayMS == 0.25 &&
        bridgedStereo.rightDelayMS == 30 && bridgedStereo.invertLeft && !bridgedStereo.invertRight && bridgedStereo.mono,
        "Swift/C stereo bridge changed a setting")
guard let stereoEngine = eq_create(48000, 0) else { fatalError("Engine allocation failed") }
let stereoFilters = stereoProfile.dspFilters(rate: 48000)
require(eq_update_filters_stereo(stereoEngine, stereoFilters, UInt32(stereoFilters.count), stereoProfile.preamp, false, &bridgedStereo),
        "Engine rejected bridged stereo settings")
eq_destroy(stereoEngine)
require(abs(StereoSettings(width: 2).headroomGainDB - 6.020599913)<1e-6, "Width headroom bound is incorrect")
require(abs(StereoSettings(leftTrimDB: 6, width: 2).headroomGainDB - 12.020599913)<1e-6, "Trim/width headroom is not combined")
require(StereoSettings(width: 2, mono: true).headroomGainDB == 0, "Mono ignores width for headroom")
for invalid in [StereoSettings(leftTrimDB: .nan), StereoSettings(rightTrimDB: 12.1), StereoSettings(balance: -1.1),
                StereoSettings(width: 2.1), StereoSettings(crossfeed: -.infinity), StereoSettings(leftDelayMS: -1), StereoSettings(rightDelayMS: 31)] {
    var profile = legacy; profile.stereo = invalid
    do { _ = try profile.validated(); fatalError("Invalid stereo settings accepted") }
    catch is AudioFailure { }
}
print("PASS legacy profile decoding, stereo preset identity and persistence, Swift/C stereo mapping, headroom and bounds")

var leftFilter = ImportedFilter(kind: .peak, frequency: 1000, gain: 6, q: 1, enabled: true, channel: .left)
let rightFilter = ImportedFilter(kind: .peak, frequency: 1000, gain: -9, q: 1, enabled: true, channel: .right)
let channelProfile = Profile(preamp: -3, filters: [leftFilter, rightFilter])
let channelFilters = channelProfile.dspFilters(rate: 48000)
require(channelFilters[0].channel == UInt32(EQChannelLeft) && channelFilters[1].channel == UInt32(EQChannelRight), "Channel targets lost in bridge")
require(abs(channelProfile.response(1000, rate: 48000, channel: .left) - 3)<1e-8, "Left response is not channel-specific")
require(abs(channelProfile.response(1000, rate: 48000, channel: .right) + 12)<1e-8, "Right response is not channel-specific")
require(abs(channelProfile.response(1000, rate: 48000) - 3)<1e-8, "Default response must cover louder channel")
leftFilter.channel = nil
var explicitStereo = leftFilter; explicitStereo.channel = .stereo
require(leftFilter == explicitStereo, "Legacy and explicit stereo targets must have the same EQ identity")
let oldFilter = try JSONDecoder().decode(ImportedFilter.self, from: Data("{\"kind\":\"PK\",\"frequency\":1000,\"gain\":6,\"q\":1,\"enabled\":true}".utf8))
require(oldFilter.effectiveChannel == .stereo, "Legacy filter did not decode as stereo")
let channelData = try JSONEncoder().encode(channelProfile)
require(try JSONDecoder().decode(Profile.self, from: channelData) == channelProfile, "Channel targets lost in profile persistence")
print("PASS channel-target bridge, per-channel graph, conservative headroom, legacy targets and channel persistence")
