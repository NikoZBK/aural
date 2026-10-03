import AppKit

@MainActor func checkEQBars() throws {
    for range in [-12.0...12.0, -30.0...30.0] {
        require(EQBarScale.fraction(0, in: range) == 0.5, "Flat bands must sit on the center line")
        require(EQBarScale.gain(at: -1, in: range) == range.lowerBound && EQBarScale.gain(at: 2, in: range) == range.upperBound,
                "Dragging beyond the bar must stop at the accepted gain limits")
        for step in 0...100 {
            let fraction = Double(step) / 100
            let gain = EQBarScale.gain(at: fraction, in: range)
            require(abs(EQBarScale.fraction(gain, in: range) - fraction) < 1e-12, "Visual gain positions must round-trip without changing precision")
        }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-bars-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let model = Model(settingsFile: directory.appendingPathComponent("settings.json"), readLoginStatus: { .notRegistered })
    let original = model.profile
    var currentEQ = original
    currentEQ.gains = [-3, 2, 1, -4, 5, -2, 1, 3, -1, 2]
    let graphicBars = EQBarBand.bands(in: currentEQ)
    require(graphicBars.map(\.gain) == currentEQ.gains && graphicBars.map(\.frequency) == ProfileTools.graphicFrequencies,
            "The 10-band view must show the current EQ gains, not a newly flattened template")
    var importedEQ = try ProfileTools.parametric(currentEQ)
    importedEQ.filters = importedEQ.filters!.enumerated().map { index, filter in
        var next = filter; next.frequency += Double(index) + 0.123456789; return next
    }
    let importedBars = EQBarBand.bands(in: importedEQ)
    require(importedBars.map(\.frequency) == importedEQ.filters!.map(\.frequency) && importedBars.map(\.gain) == importedEQ.filters!.map(\.gain),
            "Imported EQ bars must use the active filters' actual frequencies and gains without replacing them")
    model.beginProfileGesture(label: "Band gain")
    for gain in [1.0, 2.0, 3.123456789] { model.setBandGain(at: 2, to: gain) }
    model.endProfileGesture()
    require(model.profile.gains[2] == 3.123456789 && model.error == nil, "Bars must preserve exact gains through the shared editing path")
    model.setInterfaceMode(.professional)
    require(model.profile.gains[2] == 3.123456789, "Simple and Professional must share the edited bars")
    model.undoProfile()
    require(model.profile == original && !model.canUndo, "An entire drag must be one undo step")

    model.useGraphicTemplate(bands: 31)
    var filter = model.profile.filters![4]
    filter.kind = .lowShelf; filter.channel = .right; filter.enabled = false; filter.q = 2.123456789
    model.updateFilter(at: 4, with: filter)
    model.beginProfileGesture(label: "Band gain")
    model.setBandGain(at: 4, to: -4.987654321)
    model.endProfileGesture()
    var expected = filter; expected.gain = -4.987654321
    require(model.profile.filters![4] == expected, "Bars must retain filter type, Q, frequency, target channel, and disabled state")
    model.undoProfile()
    require(model.profile.filters![4] == filter, "Imported filter bar edits must be undoable")
    filter.kind = .highPass; filter.gain = 0
    model.updateFilter(at: 4, with: filter)
    let unchanged = model.profile
    model.setBandGain(at: 4, to: 2)
    require(model.profile == unchanged && model.error != nil, "Pass/notch filters must reject meaningless gain edits explicitly")
    model.setPreamp(-8.75)
    var stereo = StereoSettings(); stereo.width = 1.4; stereo.leftDelayMS = 7.25; stereo.invertRight = true
    model.setStereoSettings(stereo)
    let beforeReset = model.profile
    model.resetEQ()
    var expectedReset = beforeReset
    expectedReset.preamp = 0
    expectedReset.filters = beforeReset.filters!.map { filter in
        var next = filter; if next.kind.usesGain { next.gain = 0 }; return next
    }
    require(model.profile == expectedReset && model.error == nil && model.undoLabel == "Undo Reset EQ",
            "Reset must zero gain and preamp, preserve filter metadata and stereo effects, and create one explicit undo step")
    model.undoProfile()
    require(model.profile == beforeReset, "One undo must restore the entire EQ before Reset")
    model.redoProfile()
    require(model.profile == expectedReset, "Reset EQ must support redo")
    require(!model.running && !model.route.hasResources, "Bar edits must retain the playback state")
    print("PASS visual gain bounds, active frequencies/gains, shared mode edits, precision, drag undo, imported filter preservation, gainless filter rejection, and EQ reset/undo/redo")
}
