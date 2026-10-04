import AppKit

@MainActor func checkCurveEditing() throws {
    let size = CGSize(width: 662, height: 281)
    let scale = ResponseScale(minimum: -10, maximum: 10)
    let graphic = EQBarBand(index: 2, frequency: 125, gain: 1.123456789, filter: nil)
    let fixed = CurveDrag(band: graphic, scale: scale, size: size, maximumFrequency: 20000)
    require(fixed.values(translation: .zero).gain == graphic.gain, "A click must retain full gain precision")
    require(fixed.values(translation: CGSize(width: 200, height: -1000)).frequency == 125,
            "Graphic curve drags must not move fixed frequencies or convert the EQ")
    require(fixed.values(translation: CGSize(width: 0, height: -1000)).gain == 12,
            "Graphic drags must respect the gain limit")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-curve-checks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let model = Model(settingsFile: directory.appendingPathComponent("settings.json"), readLoginStatus: { .notRegistered })
    model.editGraphicAsFilters()
    var filter = model.profile.filters![2]
    filter.frequency = 125.123456789
    filter.q = 2.123456789
    filter.gain = -2.123456789
    filter.channel = .right
    filter.enabled = false
    model.updateFilter(at: 2, with: filter)
    let before = model.profile
    let drag = CurveDrag(band: EQBarBand(index: 2, frequency: filter.frequency, gain: filter.gain, filter: filter),
                         scale: scale, size: size, maximumFrequency: 15680)
    let unchanged = drag.values(translation: .zero)
    require(unchanged.frequency == filter.frequency && unchanged.gain == filter.gain, "Clicking imported points must preserve exact values")
    let horizontal = drag.values(translation: CGSize(width: 200, height: 0))
    require(horizontal.frequency > filter.frequency && horizontal.gain == filter.gain, "Horizontal drags must only change frequency")
    let vertical = drag.values(translation: CGSize(width: 0, height: -24))
    require(vertical.frequency == filter.frequency && vertical.gain > filter.gain, "Vertical drags must only change gain")
    let maximum = drag.values(translation: CGSize(width: 10000, height: -10000))
    let minimum = drag.values(translation: CGSize(width: -10000, height: 10000))
    require(maximum.frequency == 15680 && maximum.gain == 30 && minimum.frequency == 20 && minimum.gain == -30,
            "Dragging beyond the graph must respect the plotted frequency range and gain bounds")
    model.beginProfileGesture(label: "Curve adjustment")
    for distance in [10.0, 20, 30] {
        let values = drag.values(translation: CGSize(width: distance, height: -distance))
        var edited = model.profile.filters![2]
        edited.frequency = values.frequency; edited.gain = values.gain
        model.updateFilter(at: 2, with: edited)
    }
    model.endProfileGesture()
    let edited = model.profile
    require(edited.filters![2].q == filter.q && edited.filters![2].channel == .right && !edited.filters![2].enabled,
            "Dragging must preserve Q, channel, type and disabled state")
    require(model.undoLabel == "Undo Curve adjustment" && !model.running && !model.bypass,
            "Curve edits must be grouped and preserve playback")
    model.undoProfile()
    require(model.profile == before, "One undo must restore both frequency and gain for the whole drag")
    model.redoProfile()
    require(model.profile == edited, "Redo must restore the final dragged position")
    filter.kind = .highPass; filter.gain = 0
    let gainless = CurveDrag(band: EQBarBand(index: 2, frequency: filter.frequency, gain: 0, filter: filter),
                             scale: scale, size: size, maximumFrequency: 20000)
    let moved = gainless.values(translation: CGSize(width: 100, height: -100))
    require(moved.frequency > filter.frequency && moved.gain == 0, "Gainless filters may move in frequency without inventing gain")
    print("PASS curve drag coordinates, precision, fixed/gainless bands, bounds, metadata, undo/redo, and playback preservation")
}
