import SwiftUI

@MainActor func checkFilterReordering() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-filter-order-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let parent = directory.appendingPathComponent("settings")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let file = parent.appendingPathComponent("settings.json")
    var settings = Settings()
    settings.selectedUID = "fixture-output"
    settings.startEQAutomatically = false
    let original = Profile(preamp: -8.123456789, filters: [
        ImportedFilter(kind: .peak, frequency: 120.123456789, gain: -3, q: 1.23456789, enabled: true, channel: .left),
        ImportedFilter(kind: .lowShelf, frequency: 300, gain: 2, q: 0.7071, enabled: true, channel: .mid),
        ImportedFilter(kind: .notch, frequency: 5000, gain: 0, q: 4, enabled: false, channel: .side)
    ])
    settings.devices[settings.selectedUID] = original
    settings.presets["Order fixture"] = original
    settings.selectedPresets = [settings.selectedUID: "Order fixture"]
    try JSONEncoder().encode(settings).write(to: file)
    let model = Model(settingsFile: file, readLoginStatus: { .notRegistered })
    model.select(settings.selectedUID)
    model.captureComparison()
    var selected = 1
    var display = FilterDisplay.rows
    let submissions = PrecisionSubmissionCoordinator()
    let rack = FilterRack(model: model, submissions: submissions,
                          selectedBand: Binding(get: { selected }, set: { selected = $0 }),
                          display: Binding(get: { display }, set: { display = $0 }))
    let input = UUID()
    submissions.activate(input) { .rejected }
    rack.moveFilter(at: 0, by: 1)
    require(model.profile == original && selected == 1 && !model.canUndo,
            "An invalid pending number must block reordering and selection changes")
    var submitted = false
    submissions.activate(input) {
        if submitted { return .unchanged }
        submitted = true
        var filter = model.profile.filters![0]
        filter.frequency = 141.23456789
        model.updateFilter(at: 0, with: filter)
        return .submitted
    }
    model.running = true // Control-state check only; no physical route is opened.
    model.setSolo(1)
    rack.moveFilter(at: 0, by: 1)
    submissions.deactivate(input)
    var beforeMove = original
    beforeMove.filters?[0].frequency = 141.23456789
    let expected = try ProfileTools.moveFilter(beforeMove, at: 0, by: 1)
    require(model.profile == expected && model.error == nil && selected == 0 && display == .rows,
            "Submit exact input before moving; follow the displaced selected band without switching views")
    require(model.soloBand == nil && model.route.solo == nil && model.running,
            "Reordering must end solo atomically and preserve running state")
    require(model.otherComparisonProfile == original && model.selectedPresetName == "Order fixture",
            "Reordering must preserve the other comparison and preset identity")
    require(model.undoLabel == "Undo Move filter", "Move must be a separate undo step")
    let restored = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
    require(restored.devices[settings.selectedUID] == expected && restored.presets["Order fixture"] == original,
            "Save the active chain order without overwriting its library preset")

    model.setSolo(0)
    model.undoProfile()
    require(model.profile == beforeMove && model.soloBand == nil && model.running,
            "Undo must restore order and end a newly selected solo")
    model.setSolo(1)
    model.redoProfile()
    require(model.profile == expected && model.soloBand == nil, "Redo must restore order without soloing a different band")
    model.undoProfile()
    model.undoProfile()
    require(model.profile == original && !model.canUndo, "The pending numeric edit must remain a separate undo step")

    selected = 0
    model.running = false
    rack.moveFilter(at: 0, by: 1)
    require(selected == 1 && !model.running && !model.route.hasResources,
            "The moved selection must follow its filter without starting stopped playback")
    let accepted = model.profile
    rack.moveFilter(at: 0, by: -1)
    require(model.profile == accepted && selected == 1 && model.error != nil,
            "An invalid move must report an error without changing the profile or selection")

    // A save failure leaves the accepted live edit visible and undoable.
    try FileManager.default.removeItem(at: parent)
    try Data("block settings writes".utf8).write(to: parent)
    rack.moveFilter(at: 1, by: -1)
    require(model.profile == original && selected == 0 && model.canUndo
            && model.error?.contains("Could not save settings:") == true,
            "The inspector must follow an accepted move even if saving fails; keep the save error visible")
    print("PASS main-rack reordering, pending input, selection, undo/redo, solo safety, A/B, playback, exact persistence, and save failures")
}
