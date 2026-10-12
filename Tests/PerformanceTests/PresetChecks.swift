import Foundation

@MainActor func checkPresetDeletion() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-preset-checks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let parent = directory.appendingPathComponent("settings", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let file = parent.appendingPathComponent("settings.json")
    let original = try AutoEQ.parse("Preamp: -6.123456789 dB\nFilter 1: ON PK Fc 1234.56789 Hz Gain -2.3456789 dB Q 0.7123456789\n", name: "Saved correction")
    var settings = Settings()
    settings.devices["fixture-output"] = original
    settings.presets = ["Saved correction": original, "Other correction": Profile()]
    settings.selectedPresets = ["fixture-output": "Saved correction", "other-output": "Saved correction"]
    settings.favoritePresets = ["Saved correction"]
    try JSONEncoder().encode(settings).write(to: file)
    let model = Model(settingsFile: file, readLoginStatus: { .notRegistered })
    model.select("fixture-output")
    model.captureComparison()
    model.setPreamp(-7.123456789)
    model.running = true; model.bypass = true // Exercise control state without opening audio.
    let profile = model.profile, undo = model.undoLabel, comparison = model.comparisonLabel
    let comparisonSlot = model.comparisonSlot
    let before = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
    model.deletePreset("Saved correction")
    require(model.presetProfile(named: "Saved correction") == nil && !model.favoritePresets.contains("Saved correction")
            && model.selectedPresetName == nil && model.deletedPreset?.profile == original,
            "Deleting must remove the preset, favorite and selection while retaining its exact undo copy")
    require(model.profile == profile && model.running && model.bypass && !model.route.hasResources
            && model.undoLabel == undo && model.comparisonAvailable && model.comparisonSlot == comparisonSlot
            && model.otherComparisonProfile == original,
            "Deleting a modified active preset must preserve EQ, processing, history and comparison")
    require(model.importNotice?.contains("Deleted preset “Saved correction”") == true && model.error == nil,
            "Successful deletion must identify the preset and explain how to undo")
    let deleted = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
    require(deleted.presets["Saved correction"] == nil && deleted.selectedPresets?.values.contains("Saved correction") == false
            && deleted.devices == before.devices,
            "Persist deletion and clear all output references without modifying saved output EQ")
    model.restoreDeletedPreset()
    require(model.presetProfile(named: "Saved correction") == original && model.favoritePresets.contains("Saved correction")
            && model.deletedPreset == nil && model.selectedPresetName == nil && model.profile == profile
            && model.running && model.bypass && model.error == nil,
            "Undo delete must restore exact data and favorites without applying the preset")
    require(model.importNotice == "Restored preset “Saved correction”.", "Restoration must identify the restored preset")
    model.undoProfile()
    require(model.profile == original && model.selectedPresetName == nil,
            "EQ history must remain usable without reviving a deleted preset selection")

    model.deletePreset("Saved correction")
    model.setPreamp(-8.123456789)
    model.presetName = "Saved correction"
    model.savePreset()
    let replacementProfile = model.profile
    let replacement = model.presetProfile(named: "Saved correction")
    model.restoreDeletedPreset()
    require(model.presetProfile(named: "Saved correction") == replacement
            && model.presetProfile(named: "Saved correction (2)") == original
            && model.favoritePresets.contains("Saved correction (2)")
            && model.importNotice == "Restored preset “Saved correction (2)”.",
            "Undo delete must preserve a reused name and report the unique restored name")

    model.deletePreset("Saved correction (2)")
    model.importNotice = nil
    let library = model.customPresets, favorites = model.favoritePresets, selection = model.selectedPresetName
    // Replace only the fixture's parent with a file to make atomic settings writes fail.
    let persisted = try Data(contentsOf: file)
    try FileManager.default.removeItem(at: parent)
    try Data("blocked fixture directory".utf8).write(to: parent)
    model.deletePreset("Other correction")
    require(model.customPresets == library && model.favoritePresets == favorites && model.selectedPresetName == selection
            && model.deletedPreset?.name == "Saved correction (2)" && model.importNotice == nil && model.error != nil,
            "Failed deletion must preserve the library, previous undo and selection without reporting success")
    model.restoreDeletedPreset()
    require(model.customPresets == library && model.deletedPreset?.name == "Saved correction (2)"
            && model.importNotice == nil && model.error != nil && model.profile == replacementProfile && model.running && model.bypass,
            "Failed restoration must retain undo and current sound without reporting success")
    try FileManager.default.removeItem(at: parent)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try persisted.write(to: file)
    model.restoreDeletedPreset()
    require(model.deletedPreset == nil && model.error == nil, "Restoration must be retryable after a failed save")
    let restored = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
    require(restored.presets["Saved correction (2)"] == original && restored.favoritePresets?.contains("Saved correction (2)") == true,
            "A successful retry must persist restored precision and favorite state")
    model.importNotice = nil
    model.deletePreset("Flat")
    require(model.factory["Flat"] != nil && model.error != nil && model.deletedPreset == nil && model.importNotice == nil,
            "Built-in presets must remain protected and rejection must not look successful")
    require(comparison.contains("Saved correction"), "The fixture must exercise a named A/B snapshot")
    model.running = false
    print("PASS preset deletion, current EQ/history/A-B preservation, exact undo, favorites, name collisions, failed saves and retry")
}
