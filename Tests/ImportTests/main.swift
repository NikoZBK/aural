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
let disabledProfile = try AutoEQ.parse("Filter 1: OFF PK Fc 1000 Hz Gain 1 dB Q 1", name: "Disabled")
require(disabledProfile.filters?[0].enabled == false && disabledProfile.filters?[0].gain == 1, "Disabled profile lost saved gain")
rejects("Preamp: -5 dB")
rejects("# Empty")
rejects(fixed + "\nFilter 1: ON PK Fc 1e3 Hz Gain 1 dB Q 1", contains: "unique")
rejects((1...33).map { "Filter \($0): ON PK Fc 1000 Hz Gain 1 dB Q 1" }.joined(separator: "\n"), contains: "32")
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
while ordered.filters.count < 32 { try ordered.duplicateFilter(firstID) }
do { try ordered.duplicateFilter(firstID); fatalError("Exceeded filter limit") }
catch { require(ordered.filters.count == 32, "Rejected duplication changed filters") }
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
    rejects("Filter 1: ON \(kind.rawValue) Fc 1000 Hz")
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
