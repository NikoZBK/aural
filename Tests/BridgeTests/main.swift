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
    case .lowShelf, .highShelf, .firstOrderLowShelf, .firstOrderHighShelf: require(abs(response) < 0.001, "Shelf bridge mismatch")
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
require(Profile.maxFilters + Loudness.filterCount <= Int(EQMaxFilters), "The engine must hold a full profile and loudness compensation")
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
                                     invertLeft: true, invertRight: false, mono: true, swapChannels: true)
_ = try stereoProfile.validated()
require(!stereoProfile.hasSameEQ(as: legacy), "Stereo edits must mark a preset as modified")
let encoded = try JSONEncoder().encode(stereoProfile)
require(try JSONDecoder().decode(Profile.self, from: encoded) == stereoProfile, "Stereo profile round-trip lost settings")
var bridgedStereo = stereoProfile.dspStereo
require(bridgedStereo.leftTrimDB == -3 && bridgedStereo.rightTrimDB == 2 && bridgedStereo.balance == -0.3 &&
        bridgedStereo.width == 1.5 && bridgedStereo.crossfeed == 0.4 && bridgedStereo.leftDelayMS == 0.25 &&
        bridgedStereo.rightDelayMS == 30 && bridgedStereo.invertLeft && !bridgedStereo.invertRight && bridgedStereo.mono &&
        bridgedStereo.swapChannels,
        "Swift/C stereo bridge changed a setting")
guard let stereoEngine = eq_create(48000, 0) else { fatalError("Engine allocation failed") }
let stereoFilters = stereoProfile.dspFilters(rate: 48000)
require(eq_update_filters_stereo(stereoEngine, stereoFilters, UInt32(stereoFilters.count), stereoProfile.preamp, false, &bridgedStereo),
        "Engine rejected bridged stereo settings")
eq_destroy(stereoEngine)
// Stereo settings saved before the swap existed still decode, without a swap.
let savedStereo = try JSONDecoder().decode(StereoSettings.self, from: Data(#"{"leftTrimDB":-3,"rightTrimDB":0,"balance":0,"width":1,"crossfeed":0,"leftDelayMS":0,"rightDelayMS":0,"invertLeft":false,"invertRight":false,"mono":false}"#.utf8))
require(savedStereo == StereoSettings(leftTrimDB: -3), "Stereo settings without a swap did not decode")
require(StereoSettings(swapChannels: true).resettingListeningControls().swapChannels, "Resetting listening controls must keep the channel swap")
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
let midSideProfile = Profile(preamp: -3, filters: [ImportedFilter(kind: .peak, frequency: 1000, gain: 6, q: 1, enabled: true, channel: .mid),
                                                   ImportedFilter(kind: .peak, frequency: 12000, gain: -9, q: 2, enabled: true, channel: .side)])
let midSideFilters = midSideProfile.dspFilters(rate: 48000)
require(midSideFilters[0].channel == UInt32(EQChannelMid) && midSideFilters[1].channel == UInt32(EQChannelSide), "Mid/Side targets lost in bridge")
require(abs(midSideProfile.response(1000, rate: 48000, channel: .mid) - 3) < 0.01 && abs(midSideProfile.response(12000, rate: 48000, channel: .side) + 12) < 0.01,
        "Mid and Side responses must follow their own filters")
// Full-scale left and right can add the boosted mid in one output.
require(abs(midSideProfile.response(1000, rate: 48000) - 3) < 0.01 && midSideProfile.response(1000, rate: 48000, channel: .left) < 1,
        "Default response must cover the mid/side bound of either output")
let midSideData = try JSONEncoder().encode(midSideProfile)
let decodedMidSide = try JSONDecoder().decode(Profile.self, from: midSideData)
require(String(decoding: midSideData, as: UTF8.self).contains("\"channel\":\"M\"") && decodedMidSide == midSideProfile,
        "Mid/Side targets lost in profile persistence")
print("PASS channel-target bridge, per-channel graph, conservative headroom, legacy targets, Mid/Side targets and channel persistence")

for rate in [32000.0, 44100, 48000, 88200, 96000, 176400, 192000] {
    for sliders in [[6.0, 6, 6, 6, 6, 6, 6, 6, 6, 6], [12, -12, 12, -12, 12, -12, 12, -12, 12, -12],
                    [-12, -12, -12, -12, -12, 12, 12, 12, 12, 12], [0, 0, 0, 0, 0, 0, 0, 0, -12, 12]] {
        let profile = Profile(gains: sliders)
        let filters = profile.dspFilters(rate: rate)
        for (band, frequency) in GraphicEQ.frequencies.enumerated() where frequency < rate * 0.49 {
            require(abs(profile.response(frequency, rate: rate) - sliders[band]) < 1e-6, "Engine misses graphic slider at \(frequency) Hz, \(rate) Hz")
        }
        require(filters.map(\.disabled) == GraphicEQ.frequencies.map { $0 >= rate * 0.49 }, "Graphic band disabled at the wrong rate")
    }
}
print("PASS the engine's response at each graphic band centre equals its slider at seven sample rates")

// ISO 226:2003 itself: 40 phon is 99.85 dB at 20 Hz, and each contour meets its level at 1 kHz.
require(abs(Loudness.pressure(at: 0, phon: 40) - 99.85) < 0.01, "ISO 226 contour differs from the standard")
for phon in stride(from: 20.0, through: 90, by: 10) {
    require(abs(Loudness.pressure(at: Loudness.frequencies.firstIndex(of: 1000)!, phon: phon) - phon) < 0.02, "ISO 226 contour misses 1 kHz")
}
require(Loudness.listeningLevel(volume: -20, referenceVolume: -6, referenceLevel: 80) == 66, "Volume reduction must lower the listening level")
require(Loudness.listeningLevel(volume: 0, referenceVolume: -6, referenceLevel: 80) == 80, "Louder than the reference must play as set")
require(Loudness.listeningLevel(volume: -.infinity, referenceVolume: -6, referenceLevel: 80) == 40 &&
        Loudness.listeningLevel(volume: .nan, referenceVolume: -6, referenceLevel: 80) == 80, "Listening level must stay in range")
require(Loudness.listeningLevel(volume: -12.34, referenceVolume: 0, referenceLevel: 75) == 62.7, "Listening level must use 0.1 phon steps")
require(Loudness.filters(level: 80, reference: 80).isEmpty && Loudness.filters(level: 85, reference: 80).isEmpty, "The reference level must play as set")
require(Loudness.curve(level: 80, reference: 80).allSatisfy { abs($0) < 1e-12 }, "The reference contour must be flat")
var worstLoudness = 0.0
for reference in Loudness.referenceLevels {
    for level in stride(from: reference - Loudness.maximumDepth, to: reference, by: 5) {
        let filters = Loudness.filters(level: level, reference: reference)
        let curve = Loudness.curve(level: level, reference: reference)
        require(filters.count == Loudness.filterCount && filters.allSatisfy { abs($0.gain) <= 30 && $0.frequency < 32000 * 0.49 },
                "Loudness filters must suit every rate the engine accepts")
        require(curve[0] > 0 && curve[0] == curve.max(), "Quieter listening must raise the bass most")
        for rate in [44100.0, 48000, 96000] {
            for step in 0...55 {
                let frequency = 20 * pow(2, Double(step) / 6)
                let error = abs(eq_response_filters(frequency, rate, filters, UInt32(filters.count), 0) - Loudness.compensation(at: frequency, curve: curve))
                worstLoudness = max(worstLoudness, error)
            }
            require(abs(eq_response_filters(1000, rate, filters, UInt32(filters.count), 0)) < 0.3, "Loudness must keep 1 kHz at the volume set")
            require(eq_response_filters(10, rate, filters, UInt32(filters.count), 0) <= curve[0], "Loudness must not boost subsonic content")
        }
    }
}
require(worstLoudness < 1.5, "Loudness filters miss ISO 226 by \(worstLoudness) dB")
let fullProfile = Profile(filters: Array(repeating: ImportedFilter(kind: .peak, frequency: 1000, gain: 1, q: 1, enabled: true), count: Profile.maxFilters))
let withLoudness = fullProfile.dspFilters(rate: 48000) + Loudness.filters(level: 40, reference: 80)
guard let loudEngine = eq_create(48000, 0) else { fatalError("Engine allocation failed") }
require(eq_update_filters(loudEngine, withLoudness, UInt32(withLoudness.count), -12, false), "The engine must hold a full profile with loudness")
eq_destroy(loudEngine)
let oldSettings = try JSONDecoder().decode(Settings.self, from: Data(#"{"devices":{},"presets":{},"selectedUID":""}"#.utf8))
require(oldSettings.loudness == LoudnessSettings(), "Earlier settings must leave loudness off")
var loudSettings = Settings()
loudSettings.loudness = LoudnessSettings()
loudSettings.loudness.enabled = true
loudSettings.loudness.referenceLevel = 85
loudSettings.loudness.referenceVolumes = ["speakers": -12.5]
let savedLoudness = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(loudSettings))
require(savedLoudness.loudness == loudSettings.loudness, "Loudness settings lost in persistence")
let invalidLoudness = try JSONDecoder().decode(LoudnessSettings.self, from: Data(#"{"enabled":true,"referenceLevel":200}"#.utf8))
require(invalidLoudness.enabled && invalidLoudness.referenceLevel == 80 && invalidLoudness.referenceVolumes.isEmpty, "Invalid loudness reference must fall back")
print(String(format: "PASS ISO 226:2003 contours, listening level, loudness filters within %.2f dB at three rates, capacity and persistence", worstLoudness))
