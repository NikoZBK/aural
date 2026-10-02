import Foundation

func require(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
func rejects(_ label: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError("Unexpectedly accepted: \(label)") }
    catch { require(!error.localizedDescription.isEmpty, "Missing error: \(label)") }
}
func snapshot(_ preamp: Double, preset: String? = "Reference") -> ProfileSnapshot {
    ProfileSnapshot(profile: Profile(preamp: preamp), selectedPresetName: preset)
}

var history = ProfileWorkspace()
let initial = snapshot(0)
let first = snapshot(-1)
let final = snapshot(-8)
history.record(before: initial, after: initial, label: "No change")
require(!history.canUndo && !history.canRedo, "No-op must not create history")
history.beginGesture(label: "Preamp drag")
history.record(before: initial, after: first, label: "Adjust")
history.record(before: first, after: final, label: "Adjust")
history.endGesture()
require(history.undoLabel == "Preamp drag", "Continuous edit label lost")
require(try history.undo(current: final) == initial, "Drag must undo to value before gesture")
require(!history.canUndo && history.canRedo, "Drag created more than one undo step")
require(try history.redo(current: initial) == final, "Redo must restore final drag position")
require(try history.undo(current: final) == initial, "Second undo failed")
history.record(before: initial, after: first, label: "New branch")
require(!history.canRedo, "Editing after undo must invalidate redo")
rejects("empty redo") { _ = try history.redo(current: first) }
history.beginGesture(label: "Separate drag")
history.record(before: first, after: final, label: "Adjust")
history.endGesture()
require(try history.undo(current: final) == first, "Separate gestures were incorrectly merged")
require(try history.undo(current: first) == initial, "Earlier discrete history lost")
rejects("empty undo") { _ = try history.undo(current: initial) }

var bounded = ProfileWorkspace()
var current = initial
for index in 1...150 {
    var next = current
    next.profile.gains[0] = Double(index % 12)
    bounded.record(before: current, after: next, label: "Band \(index)")
    current = next
}
var undoCount = 0
while bounded.canUndo { current = try bounded.undo(current: current); undoCount += 1 }
require(undoCount == 100, "History must retain exactly the latest 100 real changes")
print("PASS profile history coalescing, no-ops, labels, bounded capacity, redo branching, and empty-history errors")

var interruptedGesture = ProfileWorkspace()
interruptedGesture.beginGesture(label: "Slider drag")
interruptedGesture.record(before: initial, after: first, label: "Preamp")
interruptedGesture.record(before: first, after: final, label: "Apply preset", coalescing: false)
require(interruptedGesture.undoLabel == "Apply preset", "Discrete action inherited the unfinished slider's label")
require(try interruptedGesture.undo(current: final) == first, "Preset application merged into the previous slider drag")
require(try interruptedGesture.undo(current: first) == initial, "Ending a gesture early lost its undo step")
interruptedGesture.beginGesture(label: "Another slider")
interruptedGesture.record(before: initial, after: first, label: "Preamp")
interruptedGesture.record(before: first, after: first, label: "No-op command", coalescing: false)
interruptedGesture.record(before: first, after: final, label: "Next edit")
require(try interruptedGesture.undo(current: final) == first, "Even an unchanged discrete command must finish the old gesture")
print("PASS discrete action and no-op boundaries during an unfinished slider gesture")

var comparison = ProfileWorkspace()
require(!comparison.comparisonAvailable, "Comparison must be explicitly captured")
rejects("uncaptured comparison") { _ = try comparison.selectComparison(.b, current: initial) }
rejects("uncaptured copy") { try comparison.copyComparisonToOther(initial) }
comparison.captureComparison(initial)
require(comparison.comparisonAvailable && comparison.comparisonSlot == .a, "Capture must initialize A and B")
require(comparison.otherComparison == initial, "Both comparison slots must start with the captured profile")
comparison.record(before: initial, after: first, label: "Edit A")
require(comparison.otherComparison == initial, "Editing A must not mutate B")
let selectedB = try comparison.selectComparison(.b, current: first)
comparison.record(before: first, after: selectedB, label: "Compare B", previousComparisonSlot: .a)
require(selectedB == initial && comparison.otherComparison == first, "Switch must retain the edited A snapshot")
comparison.record(before: selectedB, after: final, label: "Edit B")
let undoB = try comparison.undo(current: final)
require(undoB == initial && comparison.comparisonSlot == .b, "Undo B edit must stay in B")
let undoSwitch = try comparison.undo(current: undoB)
require(undoSwitch == first && comparison.comparisonSlot == .a, "Undo comparison switch must restore A and its identity")
require(comparison.otherComparison == initial, "Undo switch must not overwrite the other slot")
let redoSwitch = try comparison.redo(current: undoSwitch)
require(redoSwitch == initial && comparison.comparisonSlot == .b, "Redo comparison switch must restore B")
let redoB = try comparison.redo(current: redoSwitch)
require(redoB == final, "Redo B edit must restore the latest comparison curve")
try comparison.copyComparisonToOther(final)
require(comparison.otherComparison == final, "Copy to other slot failed")
comparison.renamePreset("Reference", to: "Renamed")
require(comparison.comparisonTitle(for: .a) == "Renamed" && comparison.comparisonTitle(for: .b) == "Renamed", "Renaming a preset must preserve both slot identities")
let recalled = try comparison.undo(current: ProfileSnapshot(profile: final.profile, selectedPresetName: "Renamed"))
require(recalled.selectedPresetName == "Renamed", "Rename must update historical identities")
comparison.renamePreset("Renamed", to: nil)
require(comparison.otherComparison?.selectedPresetName == nil, "Deleted preset must not leave a dangling comparison identity")
print("PASS independent A/B editing, capture/copy, comparison undo/redo, and preset identity maintenance")

var reference = Profile(gains: [1, -2, 3, -4, 5, -6, 7, -8, 9, -10], preamp: -12)
reference.stereo = StereoSettings(leftTrimDB: -3, balance: 0.25)
let graphic31 = try ProfileTools.graphicTemplate(bands: 31, preserving: reference)
require(graphic31.filters?.count == 31 && graphic31.preamp == 0, "31-band template is not flat")
require(graphic31.filters?.map(\.frequency) == ProfileTools.thirdOctaveFrequencies, "31-band centers changed")
require(graphic31.filters?.allSatisfy { $0.gain == 0 && $0.enabled && abs($0.q - 4.318473046963146) < 0.000001 } == true, "Third-octave bandwidth is incorrect")
require(graphic31.stereo == reference.stereo, "Template must preserve stereo settings")
let graphic10 = try ProfileTools.graphicTemplate(bands: 10, preserving: graphic31)
require(graphic10.filters == nil && graphic10.gains.allSatisfy { $0 == 0 } && graphic10.preamp == 0, "10-band template failed")
require(graphic10.stereo == reference.stereo, "10-band template lost stereo settings")
rejects("unsupported template") { _ = try ProfileTools.graphicTemplate(bands: 15, preserving: reference) }

let scaled = try ProfileTools.transformGains(reference, scale: -0.5, offset: 1)
require(scaled.gains == reference.gains.map { $0 * -0.5 + 1 }, "Gain scale/offset arithmetic is incorrect")
require(scaled.preamp == reference.preamp && scaled.stereo == reference.stereo, "Gain tools changed unrelated controls")
rejects("graphic gain overflow") { _ = try ProfileTools.transformGains(reference, scale: 4, offset: 0) }
rejects("non-finite scale") { _ = try ProfileTools.transformGains(reference, scale: .nan, offset: 0) }
rejects("non-finite offset") { _ = try ProfileTools.transformGains(reference, scale: 1, offset: .infinity) }
require(reference.gains[0] == 1 && reference.preamp == -12, "Rejected transformation mutated its input")
let parametric = try ProfileTools.parametric(reference)
require(parametric.filters?.map(\.gain) == reference.gains && parametric.filters?.map(\.frequency) == ProfileTools.graphicFrequencies, "Converting graphic EQ changed its transfer function")
require(parametric.filters?.allSatisfy { $0.q == 1.4 && $0.kind == .peak && $0.enabled } == true, "Converting graphic EQ changed bandwidth or filter state")
require(try ProfileTools.shiftFrequencies(reference, octaves: 0) == reference, "A zero shift must preserve graphic mode")
let shifted = try ProfileTools.shiftFrequencies(reference, octaves: -1)
require(shifted.filters?.map(\.frequency) == ProfileTools.graphicFrequencies.map { $0 / 2 }, "Octave shift is incorrect")
require(shifted.filters?.map(\.gain) == reference.gains && shifted.preamp == reference.preamp && shifted.stereo == reference.stereo, "Frequency shift changed unrelated controls")
rejects("frequency above range") { _ = try ProfileTools.shiftFrequencies(reference, octaves: 1) }
rejects("frequency below range") { _ = try ProfileTools.shiftFrequencies(reference, octaves: -10) }
rejects("non-finite shift") { _ = try ProfileTools.shiftFrequencies(reference, octaves: .nan) }
rejects("overflowing shift") { _ = try ProfileTools.shiftFrequencies(reference, octaves: 10000) }
print("PASS 10/31-band templates, exact graphic conversion, stereo preservation, gain transforms, frequency shifts, and atomic bounds rejection")

let pass = ImportedFilter(kind: .highPass, frequency: 30, gain: 0, q: 0.71, enabled: true)
let peak = ImportedFilter(kind: .peak, frequency: 1000, gain: -4, q: 2, enabled: false, channel: .left)
let mixed = Profile(preamp: -3, filters: [pass, peak])
let transformedMixed = try ProfileTools.transformGains(mixed, scale: 2, offset: 3)
require(transformedMixed.filters?[0] == pass && transformedMixed.filters?[1].gain == -5, "Gain transform must skip gainless types and retain disabled filters")
require(transformedMixed.filters?[1].enabled == false, "Transform must preserve disabled state")
require(transformedMixed.filters?[1].effectiveChannel == .left, "Gain transform must preserve channel assignment")
require(try ProfileTools.shiftFrequencies(mixed, octaves: 1).filters?[1].effectiveChannel == .left, "Frequency shift must preserve channel assignment")
var enabledPeak = peak; enabledPeak.enabled = true
let updated = try ProfileTools.updateFilter(mixed, at: 1, with: enabledPeak)
require(updated.filters == [pass, enabledPeak], "Inline filter update failed")
var invalid = peak; invalid.q = 0
rejects("invalid filter") { _ = try ProfileTools.updateFilter(mixed, at: 1, with: invalid) }
rejects("missing filter") { _ = try ProfileTools.updateFilter(mixed, at: 4, with: peak) }
let duplicated = try ProfileTools.duplicateFilter(mixed, at: 0)
require(duplicated.filters == [pass, pass, peak], "Duplicate must be inserted immediately after its source")
let deleted = try ProfileTools.deleteFilter(duplicated, at: 1)
require(deleted == mixed, "Delete removed the wrong filter")
rejects("delete final filter") { _ = try ProfileTools.deleteFilter(Profile(filters: [peak]), at: 0) }
rejects("negative filter index") { _ = try ProfileTools.deleteFilter(mixed, at: -1) }
let full = try ProfileTools.addFilter(graphic31)
require(full.filters?.count == 32, "Adding the final supported filter failed")
rejects("add past capacity") { _ = try ProfileTools.addFilter(full) }
rejects("duplicate past capacity") { _ = try ProfileTools.duplicateFilter(full, at: 0) }
print("PASS inline filter editing, gainless types, disabled-state preservation, insertion order, final-filter protection, and 32-filter capacity")
