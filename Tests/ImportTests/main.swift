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
rejects("Filter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1 Q 2")
let disabledProfile = try AutoEQ.parse("Filter 1: OFF PK Fc 1000 Hz Gain 1 dB Q 1", name: "Disabled")
require(disabledProfile.filters?[0].enabled == false && disabledProfile.filters?[0].gain == 1, "Disabled profile lost saved gain")
rejects("Preamp: -5 dB")
rejects("# Empty")
rejects(fixed + "\nFilter 1: ON PK Fc 1e3 Hz Gain 1 dB Q 1", contains: "unique")
rejects((1...Profile.maxFilters + 1).map { "Filter \($0): ON PK Fc 1000 Hz Gain 1 dB Q 1" }.joined(separator: "\n"), contains: "\(Profile.maxFilters)")
rejects(String(repeating: "#", count: 65537), contains: "64 KB")
rejects("Preamp: -61 dB\n" + fixed)
print("PASS AutoEQ parser, exact values, OFF filters, BOM/CRLF, case, FixedBand, persistence, legacy profiles, and malformed-input rejection cases")

// Synthetic precision case; no downloaded headphone profiles are bundled.
let precise = try AutoEQ.parse("Preamp: -3.125 dB\nFilter 1: ON PK Fc 987.65 Hz Gain -2.345 dB Q 1.234", name: "Synthetic precision")
require(precise.preamp == -3.125 && precise.filters?.first?.frequency == 987.65, "Import values were rounded")
let preciseRestored = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(precise))
require(preciseRestored == precise, "Precision was lost when saving")
print("PASS synthetic precision preservation")

let oldSettings = try JSONDecoder().decode(Settings.self, from: Data(#"{"devices":{},"presets":{},"selectedUID":"headphones"}"#.utf8))
require(oldSettings.startEQAutomatically == nil, "Legacy settings must not silently enable auto-start")
require(!oldSettings.followSystemOutput && !oldSettings.matchLevels && !Settings().followSystemOutput && !Settings().matchLevels,
        "Output following and level matching must stay off unless chosen")
var enabledSettings = oldSettings
enabledSettings.startEQAutomatically = true
enabledSettings.followSystemOutput = true
enabledSettings.matchLevels = true
let restoredSettings = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(enabledSettings))
require(restoredSettings.startEQAutomatically == true && restoredSettings.selectedUID == "headphones", "Startup preference did not persist")
require(restoredSettings.followSystemOutput && restoredSettings.matchLevels, "Following and level matching must persist")
require(Settings().interfaceMode == .easy, "New installs should start in Simple mode")
require(oldSettings.interfaceMode == .professional, "Existing installs should retain the full controls")
for mode in InterfaceMode.allCases {
    var preferences = enabledSettings
    preferences.interfaceMode = mode
    preferences.devices["headphones"] = precise
    preferences.presets["Saved EQ"] = precise
    preferences.favoritePresets = ["Saved EQ"]
    preferences.selectedPresets = ["headphones": "Saved EQ"]
    let roundTrip = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(preferences))
    require(roundTrip.interfaceMode == mode, "Interface mode did not persist")
    require(roundTrip.devices == preferences.devices && roundTrip.presets == preferences.presets &&
            roundTrip.selectedPresets == preferences.selectedPresets && roundTrip.favoritePresets == preferences.favoritePresets &&
            roundTrip.startEQAutomatically == true && roundTrip.selectedUID == "headphones",
            "Interface preference persistence changed EQ or preset settings")
}
do {
    _ = try JSONDecoder().decode(Settings.self, from: Data(#"{"devices":{},"presets":{},"selectedUID":"","interfaceMode":"invalid"}"#.utf8))
    fatalError("An invalid interface mode should report corrupt settings")
} catch { require(error is DecodingError, "Unexpected interface mode decoding error") }
print("PASS Simple defaults, Professional legacy migration, interface mode persistence and invalid-value rejection")
let now = Date(timeIntervalSince1970: 1000)
let startup = StartupPlan(outputUID: "headphones", deadline: now.addingTimeInterval(60))
require(startup.decision(availableUIDs: ["speakers"], now: now) == .wait, "Must not substitute speakers for headphones")
require(startup.decision(availableUIDs: ["headphones"], now: now) == .start, "Saved output should start")
require(startup.decision(availableUIDs: [], now: now.addingTimeInterval(60)) == .unavailable, "Missing output must time out")
require(StartupPlan(outputUID: "", deadline: now).decision(availableUIDs: ["speakers"], now: now) == .missingOutput, "Empty target should not start")
let launch = StartupPlan.launch(outputUID: "headphones", now: now)
require(!launch.resumes && launch.decision(availableUIDs: [], now: now.addingTimeInterval(60)) == .unavailable, "Launch keeps its 60-second limit")
require(launch.retry(now: now) == nil, "A launch start must report failures instead of retrying")
let resume = StartupPlan.resume(outputUID: "headphones", outputName: "Headphones", after: 2, now: now)
require(resume.resumes && resume.outputName == "Headphones", "Resume must remember its output")
require(resume.decision(availableUIDs: [], now: now.addingTimeInterval(86400)) == .wait, "Resume must wait for its output without a deadline")
require(resume.decision(availableUIDs: ["speakers"], now: now.addingTimeInterval(86400)) == .wait, "Resume must not substitute another output")
require(resume.decision(availableUIDs: ["headphones"], now: now.addingTimeInterval(1.9)) == .wait, "Resume must let the output settle first")
require(resume.decision(availableUIDs: ["headphones"], now: now.addingTimeInterval(2)) == .start, "Resume should start once the output settles")
var retried = resume
for attempt in 1...3 {
    guard let next = retried.retry(now: now) else { fatalError("Resume should retry a failed start") }
    retried = next
    require(retried.attempts == attempt && retried.notBefore == now.addingTimeInterval(2) && retried.resumes,
            "Each resume retry waits two seconds and keeps waiting without a deadline")
}
require(retried.retry(now: now) == nil, "Resume retries must stop after three attempts")
var follower = SystemOutputFollower(current: "speakers")
require(follower.change(to: "speakers") == nil, "An unchanged macOS output is not a switch")
require(follower.change(to: nil) == nil && follower.lastUID == "speakers", "An unreadable macOS output must not count as a switch")
require(follower.change(to: "headphones") == "headphones" && follower.change(to: "headphones") == nil, "Each macOS switch is followed once")
var newFollower = SystemOutputFollower()
require(newFollower.change(to: "speakers") == "speakers", "A new follower adopts the current macOS output")
var recovery = RouteRecovery()
require(recovery.allowRestart(now: now), "The first route change restarts EQ")
require(!recovery.allowRestart(now: now.addingTimeInterval(29)), "Repeated route failures must stop instead of looping")
require(recovery.allowRestart(now: now.addingTimeInterval(30)), "A later route change restarts EQ again")
print("PASS startup settings migration/persistence and saved-output selection, arrival, timeout, resume waits, retries, output following, and restart limits")

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
    require(converted.filters?.map(\.gain) == GraphicEQ.bandGains(for: builtIn.gains) && converted.preamp == builtIn.preamp, "Graphic conversion changed gain")
}
var empty = ParametricDraft(Profile()); empty.filters = []
do { _ = try empty.profile(); fatalError("Empty filter draft accepted") } catch {}
var disabled = ParametricDraft(Profile())
for i in disabled.filters.indices { disabled.filters[i].enabled = false }
let disabledDraftProfile = try disabled.profile()
require(disabledDraftProfile.filters?.allSatisfy({ !$0.enabled }) == true, "All-disabled draft changed filter state")
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

// Clipboard export must preserve numeric precision and disabled filters.
for original in [profile, precise] {
    let text = try AutoEQ.export(original)
    let restored = try AutoEQ.parse(text, name: original.sourceName ?? "Clipboard EQ")
    require(restored == original, "Clipboard round trip changed parametric settings")
}
for original in Profile.builtInPresets.values {
    let restored = try AutoEQ.parse(AutoEQ.export(original), name: "Clipboard EQ")
    let expected = try ParametricDraft(original).profile()
    require(restored.filters == expected.filters && restored.preamp == original.preamp,
            "Clipboard export changed the fixed-band response")
}
do {
    _ = try AutoEQ.export(Profile(gains: [0]))
    fatalError("Copied an invalid profile")
} catch { require(error is AudioFailure, "Unexpected export error") }
rejects("")
print("PASS clipboard precision, disabled filters, all built-in presets, invalid export and empty paste")

// Library operations preserve existing profiles and reject conflicting names.
var library = Settings(presets: ["Headphones": precise, "Headphones copy": profile])
try library.duplicatePreset("Headphones")
require(library.presets["Headphones copy (2)"] == precise, "Duplicate lost precision or overwrote a preset")
try library.duplicatePreset("Flat")
require(library.presets["Flat copy"] == Profile(), "Built-in duplication failed")
try library.renamePreset("Headphones", to: "  Desk  ")
require(library.presets["Desk"] == precise && library.presets["Headphones"] == nil, "Rename failed")
for name in ["", "Flat", "Headphones copy"] {
    let before = library.presets
    do { try library.renamePreset("Desk", to: name); fatalError("Accepted conflicting rename") }
    catch { require(library.presets == before, "Rejected rename mutated library") }
}
let archiveData = try JSONEncoder().encode(PresetBackup(presets: library.presets))
let archive = try PresetBackup.decode(archiveData)
require(archive.presets == library.presets, "Backup changed profile precision")
var restoredLibrary = Settings(presets: ["Desk": profile])
restoredLibrary.mergePresets(archive)
require(restoredLibrary.presets["Desk"] == profile && restoredLibrary.presets["Desk (2)"] == precise,
        "Restore overwrote an existing preset")
for invalid in [PresetBackup(version: 2, presets: [:]),
                PresetBackup(presets: [" ": profile]),
                PresetBackup(presets: ["Broken": Profile(gains: [0])])] {
    let data = try JSONEncoder().encode(invalid)
    do { _ = try PresetBackup.decode(data); fatalError("Accepted invalid backup") }
    catch { require(error is AudioFailure, "Unexpected backup error") }
}
do { _ = try PresetBackup.decode(Data(repeating: 0, count: 4 * 1024 * 1024 + 1)); fatalError("Accepted oversized backup") }
catch { require(error is AudioFailure, "Unexpected size error") }
let legacyLibrary = try JSONDecoder().decode(Settings.self, from: Data(#"{"devices":{},"presets":{},"selectedUID":""}"#.utf8))
require(legacyLibrary.presets.isEmpty, "Legacy settings no longer decode")
print("PASS preset duplication, rename conflicts, backup precision/version/size validation, merge and legacy settings")

var ordered = ParametricDraft(profile)
let firstID = ordered.filters[0].id
let originalFilter = ordered.filters[0]
try ordered.duplicateFilter(firstID)
require(ordered.filters[1].id != firstID && ordered.filters[1].frequency == originalFilter.frequency,
        "Duplicate failed to assign independent identity or changed values")
try ordered.moveFilter(firstID, by: 1)
require(ordered.filters[1].id == firstID, "Move down failed")
try ordered.moveFilter(firstID, by: -1)
require(ordered.filters[0].id == firstID, "Move up failed")
do { try ordered.moveFilter(firstID, by: -1); fatalError("Moved past first row") }
catch { require(ordered.filters[0].id == firstID, "Rejected move changed order") }
while ordered.filters.count < Profile.maxFilters { try ordered.duplicateFilter(firstID) }
do { try ordered.duplicateFilter(firstID); fatalError("Exceeded filter limit") }
catch { require(ordered.filters.count == Profile.maxFilters, "Rejected duplication changed filters") }
print("PASS filter duplicate identities, ordering, edge moves and capacity")

try library.toggleFavorite("Desk")
try library.renamePreset("Desk", to: "Office")
require(library.favoritePresets == ["Office"], "Favorite did not follow rename")
try library.toggleFavorite("Flat")
let favoriteBackup = try PresetBackup.decode(JSONEncoder().encode(
    PresetBackup(presets: library.presets, favorites: library.favoritePresets)))
var favoriteRestore = Settings(presets: ["Office": profile])
favoriteRestore.mergePresets(favoriteBackup)
require(favoriteRestore.favoritePresets == ["Office (2)", "Flat"], "Restore lost favorite mapping")
try favoriteRestore.toggleFavorite("Flat")
require(favoriteRestore.favoritePresets == ["Office (2)"], "Unfavorite failed")
do {
    _ = try PresetBackup.decode(JSONEncoder().encode(PresetBackup(presets: [:], favorites: ["Missing"])))
    fatalError("Accepted missing favorite")
} catch { require(error is AudioFailure, "Unexpected favorite error") }
require(legacyLibrary.favoritePresets == nil, "Legacy favorites migration failed")
print("PASS favorite rename, restore collision mapping, toggle and legacy decoding")

var edits = EditHistory<Int>()
edits.record(1); edits.record(2)
let undoValue = try edits.undo(3)
require(undoValue == 2 && edits.canRedo, "Undo did not restore previous edit")
let redoValue = try edits.redo(undoValue)
require(redoValue == 3, "Redo did not restore next edit")
_ = try edits.undo(redoValue)
edits.record(4)
require(!edits.canRedo, "New edit retained stale redo history")
var bounded = EditHistory<Int>()
for value in 0..<120 { bounded.record(value) }
for value in (20..<120).reversed() {
    let restored = try bounded.undo(value + 1)
    require(restored == value, "History order changed")
}
require(!bounded.canUndo, "History exceeded its bound")
print("PASS editor undo/redo, branching and bounded history")

for kind in ImportedFilter.Kind.allCases where !kind.usesGain {
    let text = "Preamp: -2.5 dB\nFilter 1: ON \(kind.rawValue) Fc 1234.5 Hz Q 0.707\nFilter 2: OFF \(kind.rawValue) Fc 10000 Hz Q 2"
    let parsed = try AutoEQ.parse(text, name: "Engine filters")
    require(parsed.filters?[0].kind == kind && parsed.filters?[0].gain == 0, "New filter parsed incorrectly")
    let exported = try AutoEQ.export(parsed)
    require(!exported.contains("Gain"), "Non-gain filter exported a gain")
    let restored = try AutoEQ.parse(exported, name: "Engine filters")
    require(restored == parsed, "New filter round trip lost parameters")
    let persisted = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(parsed))
    require(persisted == parsed, "New filter persistence lost parameters")
    rejects("Filter 1: ON \(kind.rawValue) Fc 1000 Hz Gain 3 dB Q 1")
    rejects("Filter 1: ON \(kind.rawValue) Fc 1000 Hz Q 0")
    if kind == .allPass {
        rejects("Filter 1: ON AP Fc 1000 Hz", contains: "Q")
    } else {
        // Equalizer APO's defaults when Q is omitted.
        let defaulted = try AutoEQ.parse("Filter 1: ON \(kind.rawValue) Fc 1000 Hz", name: "Default Q")
        require(defaulted.filters?[0].q == (kind == .notch ? 30 : 0.5.squareRoot()), "Omitted Q must use Equalizer APO's default")
    }
    var draft = FilterDraft()
    draft.kind = kind; draft.gain = "6.5"
    let result = try draft.filter(row: 1)
    require(result.gain == 0, "Changing filter kind retained an inapplicable gain")
}
let offText = try AutoEQ.export(disabledProfile)
let offRestored = try AutoEQ.parse(offText, name: "Disabled")
require(offRestored == disabledProfile, "All-disabled profile cannot round trip")
print("PASS new filter syntax, OFF state, irrelevant gain rejection, persistence and editor conversion")

// Preset identity belongs to an output and remains distinct from the editable EQ.
do {
    var renamedSource = precise
    renamedSource.sourceName = "Different import label"
    require(renamedSource.hasSameEQ(as: precise), "Source metadata must not mark EQ as modified")
    var modifiedPreamp = precise
    modifiedPreamp.preamp -= 1
    require(!modifiedPreamp.hasSameEQ(as: precise), "Preamp edits must mark EQ as modified")
    var modifiedFilter = precise
    modifiedFilter.filters?[0].q += 1
    require(!modifiedFilter.hasSameEQ(as: precise), "Filter edits must mark EQ as modified")
    var modifiedGain = Profile()
    modifiedGain.gains[0] = 1
    require(!modifiedGain.hasSameEQ(as: Profile()), "Graphic gain edits must mark EQ as modified")

    var imported = precise
    imported.sourceName = "Headphone correction"
    var adjustedImport = imported
    adjustedImport.preamp -= 1
    var unnamed = profile
    unnamed.sourceName = nil
    var migration = Settings(
        devices: ["headphones": adjustedImport, "speakers": Profile.builtInPresets["Warm"]!,
                  "ambiguous": unnamed, "renamed-source": renamedSource],
        presets: ["Headphone correction": imported, "Duplicate A": unnamed, "Duplicate B": unnamed],
        selectedUID: "headphones")
    require(migration.selectedPresets == nil, "Legacy selection field must start absent")
    migration.migratePresetSelections()
    require(migration.selectedPresetName(forOutput: "headphones") == "Headphone correction",
            "Legacy import origin must survive preamp adjustment")
    require(migration.selectedPresetName(forOutput: "speakers") == "Warm",
            "Migration must include outputs other than the current output")
    require(migration.selectedPresetName(forOutput: "ambiguous") == nil,
            "Identical unnamed copies must not arbitrarily select a preset")
    require(migration.selectedPresetName(forOutput: "renamed-source") == "Headphone correction",
            "Unique EQ match must ignore obsolete source metadata")
    let migratedProfiles = migration.devices
    try migration.setSelectedPreset("Duplicate B", forOutput: "ambiguous")
    let selectionRoundTrip = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(migration))
    require(selectionRoundTrip.selectedPresets == migration.selectedPresets &&
            selectionRoundTrip.devices == migratedProfiles, "Preset selections did not round-trip independently of EQ")
    try migration.setSelectedPreset(nil, forOutput: "speakers")
    migration.migratePresetSelections()
    require(migration.selectedPresetName(forOutput: "speakers") == nil,
            "Migration must not overwrite an explicit cleared selection")

    var missingSelection = Settings(selectedPresets: ["headphones": "Missing"])
    require(missingSelection.selectedPresetName(forOutput: "headphones") == nil,
            "Missing presets must not display as selected")
    for (name, uid) in [("Flat", ""), ("Flat", " \n"), ("Missing", "headphones"), (" ", "headphones")] {
        let before = missingSelection.selectedPresets
        do { try missingSelection.setSelectedPreset(name, forOutput: uid); fatalError("Accepted invalid selection") }
        catch {
            require(error is AudioFailure && missingSelection.selectedPresets == before,
                    "Rejected selection changed settings or reported an unexpected error")
        }
    }
    try missingSelection.setSelectedPreset(nil, forOutput: "headphones")
    require(missingSelection.selectedPresets == [:], "Clearing a selection must remove its stored reference")

    var originPreference = Settings(
        devices: ["headphones": imported],
        presets: ["Headphone correction": imported, "Identical copy": imported])
    originPreference.migratePresetSelections()
    require(originPreference.selectedPresetName(forOutput: "headphones") == "Headphone correction",
            "A matching import origin must take precedence over ambiguous identical copies")
    let factoryPriority = Settings(presets: ["Flat": precise])
    require(factoryPriority.preset(named: "Flat") == Profile(), "Preset lookup must retain factory-name precedence")

    var referenced = Settings(
        devices: ["headphones": imported, "speakers": imported],
        presets: ["Correction": imported, "Other": precise],
        favoritePresets: ["Correction", "Other"],
        selectedPresets: ["headphones": "Correction", "speakers": "Correction", "desktop": "Other"])
    try referenced.renamePreset("Correction", to: "Renamed correction")
    require(referenced.selectedPresets == ["headphones": "Renamed correction", "speakers": "Renamed correction", "desktop": "Other"],
            "Rename must update references for every output")
    try referenced.deletePreset("Renamed correction")
    require(referenced.presets["Renamed correction"] == nil && referenced.favoritePresets == ["Other"] &&
            referenced.selectedPresets == ["desktop": "Other"] && referenced.devices["headphones"] == imported,
            "Delete must remove identity references and favorites without changing an output's EQ")
    let beforeDelete = referenced.presets
    do { try referenced.deletePreset("Flat"); fatalError("Deleted a factory preset") }
    catch { require(error is AudioFailure && referenced.presets == beforeDelete, "Rejected delete changed presets") }
}
print("PASS preset identity, legacy migration, modified EQ, duplicate ambiguity, selection persistence, validation and rename/delete references")

// Channel directives must survive text and draft round-trips, never be silently folded to stereo.
do {
    let stereoText = """
    Preamp: -6 dB
    Channel: L
    Filter 1: ON PK Fc 400 Hz Gain 3 dB Q 1
    Channel: R
    Filter 2: OFF NO Fc 3000 Hz Q 4
    Channel: ALL
    Filter 3: ON HSC Fc 9000 Hz Gain -2 dB Q 0.7
    """
    let original = try AutoEQ.parse(stereoText, name: "Channel fixture")
    require(original.filters?.map(\.effectiveChannel) == [.left, .right, .stereo], "Channel directives did not target filters")
    let exported = try AutoEQ.export(original)
    let restored = try AutoEQ.parse(exported, name: "Roundtrip")
    require(restored.hasSameEQ(as: original), "Channel-targeted EQ export changed response settings")
    let draftProfile = try ParametricDraft(original).profile()
    require(draftProfile.filters == original.filters, "Draft editing dropped filter channels")
    var channelDraft = ParametricDraft(original)
    let rightID = channelDraft.filters[1].id
    try channelDraft.duplicateFilter(rightID)
    require(channelDraft.filters[2].channel == .right && channelDraft.filters[2].id != rightID,
            "Duplicating a filter must preserve its channel with a new identity")
    channelDraft.filters[2].frequency = "2500"
    let editedRight = try channelDraft.filters[2].filter(row: 3)
    require(editedRight.effectiveChannel == .right && editedRight.frequency == 2500 && !editedRight.enabled,
            "Editing a duplicated filter must preserve its channel and disabled state")
    for text in ["Channel: C\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1", "Channel: L\nPreamp: -4 dB\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1"] {
        do { _ = try AutoEQ.parse(text, name: "Invalid"); fatalError("Accepted unsupported channel semantics") }
        catch { require(error is AudioFailure, "Unexpected channel parse failure") }
    }
    var effects = original
    effects.stereo = StereoSettings(leftTrimDB: -3)
    do { _ = try AutoEQ.export(effects); fatalError("Export silently discarded stereo effects") }
    catch { require(error.localizedDescription.contains("stereo effects"), "Export must explain unsupported effects") }
    // 6 dB/octave shelves have no Equalizer APO equivalent: export refuses them, text never
    // creates them, and presets keep them.
    let gentle = try Profile(preamp: -2, filters: [
        ImportedFilter(kind: .peak, frequency: 100, gain: 2, q: 1, enabled: true),
        ImportedFilter(kind: .firstOrderHighShelf, frequency: 3000, gain: -4, q: 0.7071, enabled: true)]).validated()
    do { _ = try AutoEQ.export(gentle); fatalError("Export wrote a 6 dB/octave shelf as text") }
    catch { require(error.localizedDescription.contains("filter 2"), "Export must name the 6 dB/octave shelf") }
    for code in ["LS1", "HS1"] {
        do { _ = try AutoEQ.parse("Filter 1: ON \(code) Fc 1000 Hz Gain 3 dB Q 0.7", name: "Invalid"); fatalError("Parsed \(code) as text") }
        catch { require(error is AudioFailure, "Unexpected \(code) parse failure") }
    }
    let savedGentle = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(gentle))
    require(savedGentle == gentle, "Preset lost a 6 dB/octave shelf")
    var hiddenQ = FilterDraft(ImportedFilter(kind: .firstOrderLowShelf, frequency: 200, gain: 3, q: 2, enabled: true))
    let keptQ = try hiddenQ.filter(row: 1)
    require(keptQ.q == 2, "Hidden Q was not kept for switching back")
    hiddenQ.q = "x"
    let invalidQ = try hiddenQ.filter(row: 1)
    require(invalidQ == ImportedFilter(kind: .firstOrderLowShelf, frequency: 200, gain: 3, q: 0.7071, enabled: true),
            "A hidden Q blocked a 6 dB/octave shelf")
    hiddenQ.kind = .lowShelf
    do { _ = try hiddenQ.filter(row: 1); fatalError("A visible invalid Q was accepted") } catch {}
    // Mid/Side filters travel as Equalizer APO's Copy routing: mid in the left slot and side
    // in the right, decoded before the next left/right filter and at the end.
    let midSide = try Profile(preamp: -3, filters: [
        ImportedFilter(kind: .peak, frequency: 100, gain: 2, q: 1, enabled: true, channel: .mid),
        ImportedFilter(kind: .peak, frequency: 3000, gain: -4, q: 2, enabled: true),
        ImportedFilter(kind: .highShelf, frequency: 8000, gain: 3, q: 0.7, enabled: false, channel: .side),
        ImportedFilter(kind: .peak, frequency: 500, gain: 1, q: 1, enabled: true, channel: .right),
        ImportedFilter(kind: .lowShelf, frequency: 80, gain: -2, q: 0.7, enabled: true, channel: .side)]).validated()
    let midSideText = try AutoEQ.export(midSide)
    let routing = midSideText.split(separator: "\n").filter { !$0.hasPrefix("Filter") && !$0.hasPrefix("Preamp") }.map(String.init)
    require(routing == [AutoEQ.midSideEncode, "Channel: L", "Channel: ALL", "Channel: R", AutoEQ.midSideDecode,
                        AutoEQ.midSideEncode, AutoEQ.midSideDecode], "Mid/Side export must route through Copy: \(routing)")
    require(AutoEQ.midSideEncode == "Copy: L=0.5*L+0.5*R R=0.5*L+-0.5*R" && AutoEQ.midSideDecode == "Copy: L=L+R R=L+-1*R",
            "Mid/Side Copy commands must keep Equalizer APO's syntax")
    let restoredMidSide = try AutoEQ.parse(midSideText, name: "Mid/Side")
    require(restoredMidSide.filters == midSide.filters && restoredMidSide.preamp == midSide.preamp, "Mid/Side text round trip changed filters")
    let draftMidSide = try ParametricDraft(midSide).profile()
    require(draftMidSide.filters == midSide.filters, "Draft editing dropped Mid/Side channels")
    let savedMidSide = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(midSide))
    require(savedMidSide == midSide, "Preset lost Mid/Side channels")
    // Any scale that the decoding Copy undoes, assignments in either order, and dB factors.
    let scaled = try AutoEQ.parse("""
    Channel: R
    Copy: R=L+-1*R L=L+R
    Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1
    Channel: ALL
    Filter 2: ON PK Fc 2000 Hz Gain 1 dB Q 1
    Copy: l=-6.0206dB*L+-6.0206dB*R r=0.5*l+-0.5*r
    Filter 3: ON PK Fc 3000 Hz Gain 1 dB Q 1
    Channel: L
    Filter 4: ON PK Fc 4000 Hz Gain 1 dB Q 1
    """, name: "Scaled")
    require(scaled.filters?.map(\.effectiveChannel) == [.side, .stereo, .stereo, .left], "Mid/Side Copy routing did not target filters")
    for (text, message) in [
        ("Copy: L=0.5*L+0.5*R R=0.5*L+-0.5*R\nChannel: L\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1", "Line 1: This mid/side Copy is never converted back"),
        ("Copy: L=0.5*L+0.5*R R=0.5*L+-0.5*R\nCopy: L=0.5*L+0.5*R R=0.5*L+-0.5*R", "Line 2: This Copy does not convert the mid/side Copy on line 1"),
        ("Copy: L=R R=L", "Line 1: Only Copy commands"),
        ("Copy: L=0.5*L+0.5*R", "Line 1: Only Copy commands"),
        ("Copy: L=0.5*L+0.5*R R=0.5*L-0.5*R", "Line 1: Only Copy commands"),
        ("Copy: M=0.5*L+0.5*R S=0.5*L+-0.5*R", "Line 1: Only Copy commands"),
        ("Channel: M\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1", "Line 1: Supported channel targets")] {
        do { _ = try AutoEQ.parse(text, name: "Invalid"); fatalError("Accepted unsupported routing: \(text)") }
        catch { require(error.localizedDescription.hasPrefix(message), "Unexpected routing failure: \(error.localizedDescription)") }
    }
    var settings = Settings(presets: ["Stereo fixture": effects])
    let data = try JSONEncoder().encode(PresetBackup(presets: settings.presets, favorites: []))
    settings.presets = [:]
    settings.mergePresets(try PresetBackup.decode(data))
    require(settings.presets["Stereo fixture"] == effects, "Native preset backup lost stereo settings")
}
print("PASS channel and Mid/Side text import/export, draft preservation, unsupported semantics and complete stereo backup")

// Diagnostics must identify physical lines in Windows exports as well as LF files.
for newline in ["\n", "\r\n", "\r"] {
    let invalidFile = ["Preamp: -3 dB", "Filter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1", "Include: other.txt"]
        .joined(separator: newline)
    rejects(invalidFile, contains: "Line 3:")
    rejects("\u{FEFF}" + invalidFile, contains: "Line 3:")
}
print("PASS LF, CRLF, and CR import diagnostic line numbers, with and without BOM")

do {
    // Older or externally authored settings may contain a custom factory-name
    // collision. Duplicate must copy the same preset that the UI displays/applies.
    var collision = Settings(presets: ["Flat": precise])
    let displayed = collision.preset(named: "Flat")
    try collision.duplicatePreset("Flat")
    require(collision.presets["Flat copy"] == displayed,
            "Duplicate copied hidden custom values instead of the displayed factory preset")
    collision.favoritePresets = ["Flat"]
    try collision.setSelectedPreset("Flat", forOutput: "output")
    let beforePresets = collision.presets
    do { try collision.renamePreset("Flat", to: "Renamed"); fatalError("Renamed a factory name through a hidden custom collision") }
    catch { require(error is AudioFailure, "Unexpected factory rename error") }
    do { try collision.deletePreset("Flat"); fatalError("Deleted a factory name through a hidden custom collision") }
    catch { require(error is AudioFailure, "Unexpected factory delete error") }
    require(collision.presets == beforePresets && collision.favoritePresets == ["Flat"] &&
            collision.selectedPresetName(forOutput: "output") == "Flat",
            "Rejected factory edits must preserve saved presets, favorites, and output selection")
    let archive = try PresetBackup.decode(JSONEncoder().encode(
        PresetBackup(presets: ["Flat": precise], favorites: ["Flat", "Warm"])))
    var restored = Settings()
    restored.mergePresets(archive)
    require(restored.presets["Flat (2)"] == precise, "Restore lost a custom preset with a reserved name")
    require(restored.favoritePresets == ["Flat (2)", "Warm"],
            "Restore must map a custom favorite once, without favoriting an unrelated factory preset")
    var alreadyFavorited = Settings(favoritePresets: ["Flat"])
    alreadyFavorited.mergePresets(archive)
    require(alreadyFavorited.favoritePresets == ["Flat", "Flat (2)", "Warm"],
            "Restoring a name collision must preserve existing factory favorites")
}
print("PASS factory-name collisions in duplication and restored favorites")

do {
    var offline = Settings(presets: ["Offline EQ": precise])
    require(offline.selectedPresetName(forOutput: "", fallback: "Offline EQ") == "Offline EQ",
            "Offline editing must retain a valid current preset without an output record")
    try offline.toggleFavorite("Offline EQ")
    try offline.duplicatePreset("Offline EQ")
    require(offline.selectedPresetName(forOutput: "", fallback: "Offline EQ") == "Offline EQ",
            "Favorite or duplicate must not clear the offline selection")
    require(offline.selectedPresetName(forOutput: "other-output", fallback: "Offline EQ") == nil,
            "Offline selection must not leak into an unrelated output")
    try offline.renamePreset("Offline EQ", to: "Renamed offline EQ")
    require(offline.selectedPresetName(forOutput: "", fallback: "Renamed offline EQ") == "Renamed offline EQ",
            "Offline selection must follow the explicit renamed identity")
    try offline.deletePreset("Renamed offline EQ")
    require(offline.selectedPresetName(forOutput: "", fallback: "Renamed offline EQ") == nil,
            "Deleting an offline preset must invalidate its identity")
}
print("PASS offline preset selection through library edits without cross-output identity leakage")

do {
    let graphic = Profile.builtInPresets["Warm"]!
    let converted = try ParametricDraft(graphic).profile()
    let roundTrip = try AutoEQ.parse(AutoEQ.export(converted), name: "Converted graphic EQ")
    require(converted.gains != roundTrip.gains && converted.filters == roundTrip.filters,
            "Regression fixture must retain different inactive graphic values with the same active filters")
    require(converted.hasSameEQ(as: roundTrip) && roundTrip.hasSameEQ(as: converted),
            "Inactive graphic gains must not mark identical parametric EQ as modified")
    var edited = roundTrip
    edited.filters?[0].gain += 1
    require(!converted.hasSameEQ(as: edited), "Changes to an active parametric filter must still count")
    var changedGraphic = graphic
    changedGraphic.gains[0] += 1
    require(!graphic.hasSameEQ(as: changedGraphic), "Active graphic gains must still count")
    require(!graphic.hasSameEQ(as: converted) && !converted.hasSameEQ(as: graphic),
            "Switching EQ representations must remain a document change")
}
print("PASS parametric EQ identity ignores inactive graphic gains while retaining active changes")

do {
    func sum(_ gains: [Double], at frequency: Double) -> Double {
        gains.indices.reduce(0) { $0 + GraphicEQ.level(band: $1, gain: gains[$1], at: frequency) }
    }
    let audible = stride(from: log(20.0), through: log(20000.0), by: 0.002).map { exp($0) }
    for sliders in [[6.0, 6, 6, 6, 6, 6, 6, 6, 6, 6], [12, -12, 12, -12, 12, -12, 12, -12, 12, -12],
                    [-12, -12, -12, -12, -12, 12, 12, 12, 12, 12], [0, 0, 0, 0, 0, 12, 0, 0, 0, 0]] {
        let gains = GraphicEQ.bandGains(for: sliders)
        require(gains.allSatisfy { abs($0) <= 30 }, "Solved band gains must stay within the parametric range")
        for (band, frequency) in GraphicEQ.frequencies.enumerated() {
            require(abs(sum(gains, at: frequency) - sliders[band]) < 1e-6, "Graphic slider does not set its centre level: \(sliders)")
        }
    }

    // Aural 1.3 stored raw Q 1.4 band gains. Migration keeps their sound.
    let legacyPresets: [String: ([Double], Double)] = [
        "Flat": ([0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 0),
        "Warm": ([2, 3, 2, 1, 0, 0, -1, -1, 0, 0], -5), "Voice": ([-4, -3, -2, 0, 1, 2, 3, 2, 0, -1], -5),
        "Detail": ([0, 0, -1, -1, 0, 1, 2, 3, 2, 1], -5), "Bass Boost": ([5, 5, 4, 2, 0, 0, 0, 0, 0, 0], -8),
        "Treble Boost": ([0, 0, 0, 0, 0, 1, 2, 3, 4, 4], -7), "Classical": ([1, 1, 0, 0, -1, -1, 0, 1, 2, 2], -4),
        "Electronic": ([4, 4, 2, 0, -1, 0, 1, 2, 3, 2], -7), "Rock": ([3, 2, 1, -1, -2, 0, 2, 3, 2, 1], -6),
        "Vocal": ([-2, -2, -1, 0, 1, 2, 2, 1, 0, -1], -4)
    ]
    require(Set(legacyPresets.keys) == Set(Profile.builtInPresets.keys), "Every built-in preset needs its Aural 1.3 gains")
    for (name, (gains, preamp)) in legacyPresets {
        let saved = Data(#"{"gains":\#(gains),"preamp":\#(preamp)}"#.utf8)
        let migrated = try JSONDecoder().decode(Profile.self, from: saved)
        require(migrated == Profile.builtInPresets[name], "Built-in preset does not match its migrated Aural 1.3 gains: \(name)")
        let now = GraphicEQ.bandGains(for: migrated.gains)
        require(audible.allSatisfy { abs(sum(now, at: $0) - sum(gains, at: $0)) <= 0.05 }, "Migration changed the sound of \(name)")
    }

    let saved = try JSONEncoder().encode(Profile.builtInPresets["Bass Boost"]!)
    require(String(decoding: saved, as: UTF8.self).contains(#""graphicVersion":2"#), "Profiles must record that sliders set centre levels")
    let reloaded = try JSONDecoder().decode(Profile.self, from: saved)
    require(reloaded == Profile.builtInPresets["Bass Boost"], "A saved profile must not migrate again")

    let loud = try JSONDecoder().decode(Profile.self, from: Data(#"{"gains":[12,12,12,12,12,12,12,12,12,12],"preamp":-24}"#.utf8))
    _ = try loud.validated()
    require(loud.filters?.map(\.gain) == loud.gains && loud.gains.allSatisfy { $0 == 12 } &&
            loud.filters?.allSatisfy({ $0.kind == .peak && $0.q == GraphicEQ.q && $0.enabled }) == true &&
            loud.filters?.map(\.frequency) == GraphicEQ.frequencies && loud.preamp == -24,
            "A legacy profile beyond the slider range must keep its sound as parametric filters")
    let legacyParametric = try JSONDecoder().decode(Profile.self, from: Data(#"{"gains":[5,5,4,2,0,0,0,0,0,0],"preamp":-3,"filters":[{"kind":"PK","frequency":1000,"gain":6,"q":1,"enabled":true}]}"#.utf8))
    require(legacyParametric.gains == [5, 5, 4, 2, 0, 0, 0, 0, 0, 0], "Inactive graphic gains of a parametric profile must not migrate")
}
print("PASS graphic sliders set centre levels, and Aural 1.3 profiles and presets migrate with their sound")

// Tilt persists only when set, and text export refuses it rather than dropping it.
var tilted = Profile.builtInPresets.values.first!
let untiltedJSON = String(decoding: try JSONEncoder().encode(tilted), as: UTF8.self)
require(!untiltedJSON.contains("tilt"), "An untilted profile must keep the earlier format")
tilted.tilt = -2.5
let tiltedRoundTrip = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(tilted))
require(tiltedRoundTrip.tilt == -2.5 && tiltedRoundTrip == tilted && !tiltedRoundTrip.hasSameEQ(as: Profile.builtInPresets.values.first!),
        "Tilt lost in persistence or ignored by EQ comparison")
let untilted = try JSONDecoder().decode(Profile.self, from: Data(#"{"gains":[0,0,0,0,0,0,0,0,0,0],"preamp":0}"#.utf8))
require(untilted.tilt == 0, "Earlier profiles must play without tilt")
for invalid in [6.5, -7, .nan, .infinity] {
    var bad = Profile(); bad.tilt = invalid
    do { _ = try bad.validated(); fatalError("Accepted tilt \(invalid)") } catch { require(error is AudioFailure, "Unexpected tilt error") }
}
do {
    _ = try AutoEQ.export(tilted)
    fatalError("Exported tilt as Equalizer APO text")
} catch { require(error.localizedDescription.contains("tilt"), error.localizedDescription) }
print("PASS tilt persistence, earlier profiles, validation, and export refusal")

// Equalizer APO's own configuration demo, a Room EQ Wizard filter file. Each filter must match
// Equalizer APO's design (BiQuad.cpp) at a sample rate high enough that it equals the analog prototype.
do {
    let demo = """
    Filter Settings file

    Room EQ V5,01
    Dated: 16.05.2013 21:56:38

    Notes:This file demonstrates all filter types the Generic equalizer supports

    Equaliser: Generic
    No measurement
    Filter  1: ON  PK       Fc    50,0 Hz  Gain -10,0 dB  Q  2,50
    Filter  2: ON  Modal    Fc     100H z  Gain   3,0 dB  Q  5,41  T60 target   100 ms
    Filter  3: ON  LP       Fc   8.000 Hz
    Filter  4: ON  HP       Fc    30,0 Hz
    Filter  5: ON  LPQ      Fc  10.000 Hz  Q  0,400
    Filter  6: ON  HPQ      Fc    20,0 Hz  Q  0,500
    Filter  7: ON  LS       Fc     300 Hz  Gain   5,0 dB
    Filter  8: ON  HS       Fc   1.000 Hz  Gain  -3,0 dB
    Filter  9: ON  LS 12dB  Fc   2.000 Hz  Gain  -5,0 dB
    Filter 10: ON  HS 12dB  Fc     500 Hz  Gain   5,0 dB
    Filter 11: ON  LS 6dB   Fc    50,0 Hz  Gain   7,2 dB
    Filter 12: ON  HS 6dB   Fc  12.000 Hz  Gain  10,0 dB
    Filter 13: ON  NO       Fc     800 Hz
    Filter 14: ON  AP       Fc     900 Hz  Q  0,707
    Filter 15: ON  None
    Filter 16: OFF None
    Filter: ON PEQ Fc 2000 Hz Gain 4 dB BW Oct 0.5
    Filter: ON BP Fc 1000 Hz BW Oct 2
    Filter: ON HSC 6 dB Fc 100 Hz Gain -6.0 dB
    Filter: ON LSC Fc 300 Hz Gain 5.0 dB Q 0.6473
    Filter: ON LS Fc 3000 Hz Gain -4 dB Q 0.9
    Filter: ON HS Fc 400 Hz Gain 6 dB Q 0.5
    Filter: ON PK Q 2 Gain 1,5 dB Fc 1\u{00A0}000 Hz
    """
    // Type, gain, Fc, Q, BW or slope, whether that is BW or slope, and whether Fc is the corner.
    let reference: [(String, Double, Double, Double, Bool, Bool)] = [
        ("PK", -10, 50, 2.5, false, false), ("PK", 3, 100, 5.41, false, false),
        ("LP", 0, 8000, 0.5.squareRoot(), false, false), ("HP", 0, 30, 0.5.squareRoot(), false, false),
        ("LP", 0, 10000, 0.4, false, false), ("HP", 0, 20, 0.5, false, false),
        ("LS", 5, 300, 0.9, true, false), ("HS", -3, 1000, 0.9, true, false),
        ("LS", -5, 2000, 1, true, true), ("HS", 5, 500, 1, true, true),
        ("LS", 7.2, 50, 0.5, true, true), ("HS", 10, 12000, 0.5, true, true),
        ("NO", 0, 800, 30, false, false), ("AP", 0, 900, 0.707, false, false),
        ("PK", 4, 2000, 0.5, true, false), ("BP", 0, 1000, 2, true, false),
        ("HS", -6, 100, 0.5, true, false), ("LS", 5, 300, 0.6473, false, false),
        ("LS", -4, 3000, 0.9, false, true), ("HS", 6, 400, 0.5, false, true),
        ("PK", 1.5, 1000, 2, false, false)]
    let imported = try AutoEQ.parse(demo, name: "Equalizer APO demo")
    require(imported.filters?.count == reference.count, "The demo must import every filter but None")
    let rate = 2_000_000.0
    func magnitude(_ b: [Double], _ a: [Double], at theta: Double) -> Double {
        func value(_ c: [Double]) -> Double {
            hypot(c[0] + c[1] * cos(theta) + c[2] * cos(2 * theta), c[1] * sin(theta) + c[2] * sin(2 * theta))
        }
        return value(b) / value(a)
    }
    for (index, (filter, apo)) in zip(imported.filters!, reference).enumerated() {
        let (type, gain, fc, width, isBandwidthOrSlope, corner) = apo
        let shelf = type == "LS" || type == "HS"
        let a = pow(10, gain / (type == "PK" || shelf ? 40 : 20))
        var frequency = fc
        if corner {
            let s = isBandwidthOrSlope ? width : 1 / ((1 / (width * width) - 2) / (a + 1 / a) + 1)
            frequency = type == "LS" ? fc * pow(10, abs(gain) / 80 / s) : fc / pow(10, abs(gain) / 80 / s)
        }
        let omega = 2 * Double.pi * frequency / rate, sn = sin(omega), cs = cos(omega)
        let alpha = !isBandwidthOrSlope ? sn / (2 * width)
            : shelf ? sn / 2 * ((a + 1 / a) * (1 / width - 1) + 2).squareRoot() : sn * sinh(log(2) / 2 * width * omega / sn)
        let beta = 2 * a.squareRoot() * alpha
        let b: [Double], d: [Double]
        switch type {
        case "LP": (b, d) = ([(1 - cs) / 2, 1 - cs, (1 - cs) / 2], [1 + alpha, -2 * cs, 1 - alpha])
        case "HP": (b, d) = ([(1 + cs) / 2, -(1 + cs), (1 + cs) / 2], [1 + alpha, -2 * cs, 1 - alpha])
        case "BP": (b, d) = ([alpha, 0, -alpha], [1 + alpha, -2 * cs, 1 - alpha])
        case "NO": (b, d) = ([1, -2 * cs, 1], [1 + alpha, -2 * cs, 1 - alpha])
        case "AP": (b, d) = ([1 - alpha, -2 * cs, 1 + alpha], [1 + alpha, -2 * cs, 1 - alpha])
        case "PK": (b, d) = ([1 + alpha * a, -2 * cs, 1 - alpha * a], [1 + alpha / a, -2 * cs, 1 - alpha / a])
        case "LS": (b, d) = ([a * ((a + 1) - (a - 1) * cs + beta), 2 * a * ((a - 1) - (a + 1) * cs), a * ((a + 1) - (a - 1) * cs - beta)],
                             [(a + 1) + (a - 1) * cs + beta, -2 * ((a - 1) + (a + 1) * cs), (a + 1) + (a - 1) * cs - beta])
        default: (b, d) = ([a * ((a + 1) + (a - 1) * cs + beta), -2 * a * ((a - 1) + (a + 1) * cs), a * ((a + 1) + (a - 1) * cs - beta)],
                           [(a + 1) - (a - 1) * cs + beta, 2 * ((a - 1) - (a + 1) * cs), (a + 1) - (a - 1) * cs - beta])
        }
        // Aural's analog prototype, as numerator and denominator coefficients of s², s and 1.
        let A = pow(10, filter.gain / 40), q = filter.q, root = A.squareRoot()
        let n: [Double], m: [Double]
        switch filter.kind {
        case .peak: (n, m) = ([1, A / q, 1], [1, 1 / (A * q), 1])
        case .lowShelf: (n, m) = ([A, A * root / q, A * A], [A, root / q, 1])
        case .highShelf: (n, m) = ([A * A, A * root / q, A], [1, root / q, A])
        case .lowPass: (n, m) = ([0, 0, 1], [1, 1 / q, 1])
        case .highPass: (n, m) = ([1, 0, 0], [1, 1 / q, 1])
        case .bandPass: (n, m) = ([0, 1 / q, 0], [1, 1 / q, 1])
        case .notch: (n, m) = ([1, 0, 1], [1, 1 / q, 1])
        case .allPass: (n, m) = ([1, -1 / q, 1], [1, 1 / q, 1])
        default: fatalError("Unexpected filter kind \(filter.kind)")
        }
        for step in 0...60 {
            let f = 20 * pow(1000, Double(step) / 60), w = f / filter.frequency
            func value(_ c: [Double]) -> Double { hypot(c[2] - c[0] * w * w, c[1] * w) }
            let expected = magnitude(b, d, at: 2 * Double.pi * f / rate), actual = value(n) / value(m)
            require(abs(actual - expected) <= 1e-3 * max(1, expected),
                    "Filter \(index + 1) differs from Equalizer APO at \(f) Hz: \(actual) vs \(expected)")
        }
    }
    let demoKinds: [ImportedFilter.Kind] = [.peak, .peak, .lowPass, .highPass, .lowPass, .highPass, .lowShelf, .highShelf, .lowShelf, .highShelf,
                                            .lowShelf, .highShelf, .notch, .allPass, .peak, .bandPass, .highShelf, .lowShelf, .lowShelf, .highShelf, .peak]
    require(imported.filters?.map(\.kind) == demoKinds, "Equalizer APO aliases imported as the wrong kinds")
    require(imported.filters?[2].frequency == 8000 && imported.filters?[0].frequency == 50, "Thousands separators or decimal commas misread")
    require(imported.stereo == nil, "A file without delays must not set stereo effects")
}
print("PASS Equalizer APO demo file, Room EQ Wizard header, aliases, defaults, BW, slopes and corner frequencies")

// Equalizer APO syntax that Aural cannot reproduce is refused rather than approximated.
do {
    let commas = try AutoEQ.parse("Preamp: -6,5 dB\nFilter1: OFF PK Fc 1234,5 Hz Gain 1 dB Q 1", name: "Commas")
    require(commas.preamp == -6.5 && commas.filters?[0].frequency == 1234.5 && commas.filters?[0].enabled == false, "Comma decimals misread")
    for (text, message) in [
        ("Filter: ON PK Fc 1000 Hz Gain 1 dB", "need a Q"),
        ("Filter: ON PK Fc 1000 Hz Q 1", "need a gain"),
        ("Filter: ON PK Gain 1 dB Q 1", "need a frequency"),
        ("Filter: ON PK Fc 1000 Hz Gain 1 dB Q 1 BW Oct 1", "only one"),
        ("Filter: ON LSC Fc 1000 Hz Gain 1 dB BW Oct 1", "not BW"),
        ("Filter: ON LSC 12dB Fc 1000 Hz Gain 1 dB Q 1", "only one"),
        ("Filter: ON PK 12dB Fc 1000 Hz Gain 1 dB Q 1", "Only shelves"),
        ("Filter: ON PK Fc 1000 Hz Gain 1 dB BW Oct 0", "greater than 0"),
        ("Filter: ON LSC 0 dB Fc 1000 Hz Gain 1 dB", "greater than 0"),
        ("Filter: ON LSC 48 dB Fc 100 Hz Gain 20 dB", "too steep"),
        ("Filter: ON PK Fc 1000 Hz Gain 1 dB Q 1 T60 target 100 ms", "Malformed"),
        ("Filter: ON IIR Order 1 Coefficients 1 0 1 0", "IIR"),
        ("Filter: ON LS1 Fc 1000 Hz Gain 1 dB", "Unsupported filter type LS1"),
        ("Filter: ON PK Fc 31.125 Hz Gain 1 dB Q 1", "22000"),
        ("Filter 1 ON PK Fc 1000 Hz Gain 1 dB Q 1", "colon"),
        ("Filter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1\nDelay: 10 samples", "samples"),
        ("Filter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1\nDelay: -1 ms", "0 ms or longer"),
        ("Filter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1\nDelay: 20 ms\nChannel: L\nDelay: 11 ms", "30 ms"),
        ("Filter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1\n\(AutoEQ.midSideEncode)\nChannel: L\nDelay: 1 ms\n\(AutoEQ.midSideDecode)", "mid or side"),
        ("Channel: L\nDelay: 1 ms\n\(AutoEQ.midSideEncode)\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1\n\(AutoEQ.midSideDecode)", "Line 3: Aural delays the channels")] {
        rejects(text, contains: message)
    }
    // Delays add up per channel; a delay shared by both channels may come before mid/side filters.
    let delayed = try AutoEQ.parse("""
    Delay: 1,5 ms
    \(AutoEQ.midSideEncode)
    Channel: L
    Filter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1
    Channel: ALL
    Delay: 0.5 ms
    \(AutoEQ.midSideDecode)
    Channel: R
    Delay: 2ms
    """, name: "Delays")
    require(delayed.stereo?.leftDelayMS == 2 && delayed.stereo?.rightDelayMS == 4 && delayed.filters?[0].channel == .mid,
            "Delays were not added per channel")
    var exportedDelays = delayed
    exportedDelays.filters![0].frequency = 31.125
    let delayText = try AutoEQ.export(exportedDelays)
    require(delayText.contains("Fc 31.1250 Hz") && delayText.hasSuffix("\(AutoEQ.midSideDecode)\nDelay: 2.0 ms\nChannel: R\nDelay: 4.0 ms\n"), delayText)
    let restoredDelays = try AutoEQ.parse(delayText, name: "Delays")
    require(restoredDelays.hasSameEQ(as: exportedDelays) && restoredDelays.stereo == exportedDelays.stereo, "Delays or a 3-decimal Fc changed in a round trip")
    var trimmed = exportedDelays
    trimmed.stereo?.leftTrimDB = -1
    do { _ = try AutoEQ.export(trimmed); fatalError("Exported a trim as text") }
    catch { require(error.localizedDescription.contains("stereo effects"), error.localizedDescription) }
}
print("PASS Equalizer APO comma decimals, delays, Fc padding, and refusal of unsupported or ambiguous syntax")
