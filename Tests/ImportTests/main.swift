import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func rejects(_ text: String, contains: String? = nil) {
    do { _ = try AutoEQ.parse(text, name: "Invalid"); fatalError("Unexpectedly accepted: \(text)") }
    catch { if let contains { require(error.localizedDescription.contains(contains), error.localizedDescription) } }
}
let sample = """
# AutoEQ-style parametric export
Preamp: -6.7 dB
Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.71
Filter 2: ON PK Fc 1234 Hz Gain -4.2 dB Q 3.21
Filter 3: ON HSC Fc 10000 Hz Gain 2.5 dB Q 0.70
Filter 4: OFF PK Fc 20000 Hz Gain -2.0 dB Q 2.00
"""
let profile = try AutoEQ.parse(sample, name: "Test headphone")
require(profile.preamp == -6.7, "Preamp changed")
require(profile.filters?.count == 4, "Filter count changed")
require(profile.filters?[0].kind == .lowShelf, "Low shelf lost")
require(profile.filters?[1].frequency == 1234 && profile.filters?[1].q == 3.21, "Fc or Q changed")
require(profile.filters?[2].kind == .highShelf && profile.filters?[3].enabled == false, "Shelf/OFF lost")
let normalized = try AutoEQ.parse("\u{FEFF}" + sample.replacingOccurrences(of: "\n", with: "\r\n"), name: "Test headphone")
require(normalized == profile, "BOM/CRLF affected parse")
let lower = try AutoEQ.parse("preamp: +1e0 db\nfilter 1: on pk fc 1e3 hz gain -2.5 db q .71 # comment", name: "Case")
require(lower.preamp == 1 && lower.filters?[0].frequency == 1000, "Case/scientific notation failed")
let fixed = (1...10).map { "Filter \($0): ON PK Fc \($0 * 100) Hz Gain 0.0 dB Q 1.41" }.joined(separator: "\n")
let fixedProfile = try AutoEQ.parse(fixed, name: "Fixed")
require(fixedProfile.filters?.count == 10, "FixedBand failed")
let encoded = try JSONEncoder().encode(profile)
let decoded = try JSONDecoder().decode(Profile.self, from: encoded)
require(decoded == profile, "Import persistence changed values")
let legacy = try JSONDecoder().decode(Profile.self, from: Data(#"{"gains":[0,0,0,0,0,0,0,0,0,0],"preamp":-5}"#.utf8))
_ = try legacy.validated()
require(legacy.filters == nil && legacy.preamp == -5, "Legacy migration failed")
rejects("GraphicEQ: 20 -1; 1000 0", contains: "ParametricEQ.txt")
rejects(sample + "\nInclude: other.txt", contains: "Line 7")
rejects(sample + "\nPreamp: -2 dB", contains: "Preamp")
rejects("Filter 1: ON PK Fc 1000 Hz Gain 1 dB Q 0", contains: "Q")
rejects("Filter 1: ON PK Fc 1000 Hz Gain 1 dB Q NaN")
rejects("Filter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1 trailing")
rejects("Filter 1: ON LS Fc 1000 Hz Gain 1 dB Q 1")
rejects("Filter 1: OFF PK Fc 1000 Hz Gain 1 dB Q 1")
rejects("Preamp: -5 dB")
rejects("# Empty")
rejects(fixed + "\nFilter 1: ON PK Fc 1e3 Hz Gain 1 dB Q 1", contains: "unique")
rejects((1...33).map { "Filter \($0): ON PK Fc 1000 Hz Gain 1 dB Q 1" }.joined(separator: "\n"), contains: "32")
rejects(String(repeating: "#", count: 65537), contains: "64 KB")
rejects("Preamp: -61 dB\n" + fixed)
print("PASS AutoEQ parser, exact values, OFF filters, BOM/CRLF, case, FixedBand, persistence, legacy profiles, and 14 rejection cases")

// Synthetic precision case; no downloaded headphone profiles are bundled.
let precise = try AutoEQ.parse("Preamp: -3.125 dB\nFilter 1: ON PK Fc 987.65 Hz Gain -2.345 dB Q 1.234", name: "Synthetic precision")
require(precise.preamp == -3.125 && precise.filters?.first?.frequency == 987.65, "Import values were rounded")
let preciseRestored = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(precise))
require(preciseRestored == precise, "Precision was lost when saving")
print("PASS synthetic precision preservation")

let oldSettings = try JSONDecoder().decode(Settings.self, from: Data(#"{"devices":{},"presets":{},"selectedUID":"headphones"}"#.utf8))
require(oldSettings.startEQAutomatically == nil, "Legacy settings must not silently enable auto-start")
var enabledSettings = oldSettings
enabledSettings.startEQAutomatically = true
let restoredSettings = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(enabledSettings))
require(restoredSettings.startEQAutomatically == true && restoredSettings.selectedUID == "headphones", "Startup preference did not persist")
let now = Date(timeIntervalSince1970: 1000)
let startup = StartupPlan(outputUID: "headphones", deadline: now.addingTimeInterval(60))
require(startup.decision(availableUIDs: ["speakers"], now: now) == .wait, "Must not substitute speakers for headphones")
require(startup.decision(availableUIDs: ["headphones"], now: now) == .start, "Saved output should start")
require(startup.decision(availableUIDs: [], now: now.addingTimeInterval(60)) == .unavailable, "Missing output must time out")
require(StartupPlan(outputUID: "", deadline: now).decision(availableUIDs: ["speakers"], now: now) == .missingOutput, "Empty target should not start")
print("PASS startup settings migration/persistence and saved-output selection, arrival, and timeout")

for (name, preset) in Profile.builtInPresets {
    _ = try preset.validated()
    let restored = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(preset))
    require(restored == preset, "Built-in preset did not round-trip: \(name)")
    require(preset.filters == nil, "Built-in preset must use graphic sliders: \(name)")
    require(preset.preamp <= -(preset.gains.max() ?? 0), "Missing boost headroom: \(name)")
}
print("PASS built-in preset validation, persistence, and boost headroom")

var draft = ParametricDraft(profile)
let untouched = try draft.profile()
require(untouched.filters == profile.filters && untouched.preamp == profile.preamp, "Editor lost imported precision")
draft.filters[0].frequency = "123.456789"
draft.filters[0].kind = .highShelf
draft.filters[0].enabled = false
draft.preamp = "-3.125"
let edited = try draft.profile()
require(edited.filters?[0].frequency == 123.456789 && edited.filters?[0].kind == .highShelf && edited.filters?[0].enabled == false && edited.preamp == -3.125, "Editor dropped edits")
for invalid in ["", "abc", "nan", "inf", "9", "22001"] {
    draft.filters[0].frequency = invalid
    do { _ = try draft.profile(); fatalError("Editor accepted invalid frequency") } catch {}
}
for builtIn in Profile.builtInPresets.values {
    let converted = try ParametricDraft(builtIn).profile()
    require(converted.filters?.map(\.gain) == builtIn.gains && converted.preamp == builtIn.preamp, "Graphic conversion changed gain")
}
var empty = ParametricDraft(Profile()); empty.filters = []
do { _ = try empty.profile(); fatalError("Empty filter draft accepted") } catch {}
var disabled = ParametricDraft(Profile())
for i in disabled.filters.indices { disabled.filters[i].enabled = false }
do { _ = try disabled.profile(); fatalError("All-disabled draft accepted") } catch {}
print("PASS parametric editor precision, edits, graphic conversion, and validation")

let laterVersion = try AppVersion("v0.10.0"), earlierVersion = try AppVersion("0.9.9")
require(laterVersion > earlierVersion, "Versions compared lexically")
let shortVersion = try AppVersion("1.0"), fullVersion = try AppVersion("1.0.0")
require(shortVersion == fullVersion, "Version padding failed")
for invalid in ["", "v", "1.beta", "1.0.0-beta", "1..0", "1.2.3.4", "999999999999999999999"] {
    do { _ = try AppVersion(invalid); fatalError("Invalid version accepted") } catch {}
}
let releaseJSON = #"{"tag_name":"v0.6.0","body":"Test notes","draft":false,"prerelease":false,"assets":[{"name":"Aural-0.6.0-universal.dmg","browser_download_url":"https://github.com/NikoZBK/aural/releases/download/v0.6.0/Aural-0.6.0-universal.dmg"}]}"#
let release = try JSONDecoder().decode(ReleaseInfo.self, from: Data(releaseJSON.utf8))
require(release.downloadURL?.pathExtension == "dmg", "Missing release download")
for replacement in ["https://evil.example/NikoZBK", "http://github.com/NikoZBK", "https://github.com/another"] {
    let altered = releaseJSON.replacingOccurrences(of: "https://github.com/NikoZBK", with: replacement)
    let rejected = try JSONDecoder().decode(ReleaseInfo.self, from: Data(altered.utf8))
    require(rejected.downloadURL == nil, "Untrusted download URL accepted")
}
print("PASS release version comparison and download URL validation")
