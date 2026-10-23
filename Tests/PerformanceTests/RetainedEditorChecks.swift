import AppKit
import SwiftUI

@MainActor private final class RetainedRackState: ObservableObject {
    @Published var display = FilterDisplay.faders
    @Published var selected = 0
    @Published var active = true
}

private struct RetainedRackProbe: View {
    let model: Model
    let submissions: PrecisionSubmissionCoordinator
    @ObservedObject var state: RetainedRackState
    var body: some View {
        FilterRack(model: model, submissions: submissions, selectedBand: $state.selected, display: $state.display, active: state.active)
            .disabled(!state.active)
    }
}

@MainActor func checkRetainedEditorUpdates() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-retained-updates-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let model = Model(settingsFile: directory.appendingPathComponent("settings.json"), readLoginStatus: { .notRegistered })
    model.editGraphicAsFilters()
    let submissions = PrecisionSubmissionCoordinator()
    let state = RetainedRackState()
    let host = NSHostingView(rootView: RetainedRackProbe(model: model, submissions: submissions, state: state))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    func flush() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
    func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, $0) }
    }
    func fields() -> [NSTextField] { descendants(NSTextField.self, host).filter(\.isEditable) }
    func activeField(_ label: String) -> NSTextField {
        guard let field = fields().first(where: { $0.isEnabled && $0.accessibilityLabel() == label }) else { fatalError("Missing active field: \(label)") }
        return field
    }
    func select(_ title: String) {
        guard let control = descendants(NSSegmentedControl.self, host).first(where: { candidate in
            (0..<candidate.segmentCount).contains { candidate.label(forSegment: $0) == title }
        }), let index = (0..<control.segmentCount).first(where: { control.label(forSegment: $0) == title }) else {
            fatalError("Missing filter-view control")
        }
        control.selectedSegment = index
        control.sendAction(control.action, to: control.target)
        flush()
    }
    flush()
    let faderFields = fields().filter(\.isEnabled)
    require(faderFields.count == 30, "The active bank must create all exact editors")
    select("All rows")
    let frozen = faderFields.map { ($0, $0.stringValue) }
    var filter = model.profile.filters![0]
    filter.gain = 3.123456789; filter.frequency = 123.123456789; filter.q = 2.123456789
    model.updateFilter(at: 0, with: filter)
    flush()
    require(activeField("Filter 1 gain in decibels").stringValue == "3.12" &&
            frozen.allSatisfy { !$0.0.isEnabled && $0.0.stringValue == $0.1 },
            "Only the active editor must refresh while dormant native fields retain their values")
    let retainedIDs = Set(fields().map(ObjectIdentifier.init))
    require(faderFields.allSatisfy { retainedIDs.contains(ObjectIdentifier($0)) }, "Freezing a bank must retain its native editors")
    select("Faders")
    require(activeField("Filter 1 gain in decibels").stringValue == "3.12" &&
            activeField("Filter 1 frequency in hertz").stringValue == "123" &&
            activeField("Filter 1 Q").stringValue == "2.123" && faderFields.allSatisfy(\.isEnabled),
            "Reactivating the same fader fields must present the latest gain, frequency, and Q")
    model.setBandGain(at: 0, to: -4.987654321)
    flush()
    require(activeField("Filter 1 gain in decibels").stringValue == "-4.99", "Visible faders must continue to refresh on every accepted document edit")

    select("Selected")
    let gain = activeField("Filter 1 gain in decibels")
    require(window.makeFirstResponder(gain), "The reactivated inspector must accept focus")
    guard let editor = gain.currentEditor() as? NSTextView else { fatalError("Missing retained native text editor") }
    editor.insertText("-", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    flush()
    window.makeFirstResponder(nil)
    flush()
    require(gain.stringValue == "-" && model.profile.filters?[0].gain == -4.987654321,
            "An invalid user draft must remain visible after focus loss without becoming a model edit")
    require(window.makeFirstResponder(gain), "An invalid retained draft must allow correction")
    flush()
    select("Faders")
    require(state.display == .selected && gain.stringValue == "-", "Invalid drafts must still block switching retained editors")
    guard let editor = gain.currentEditor() as? NSTextView else { fatalError("Rejected switching must retain editing focus") }
    editor.insertText("-2.123456789", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    flush()
    select("Faders")
    require(state.display == .faders && model.profile.filters?[0].gain == -2.123456789 &&
            activeField("Filter 1 gain in decibels").stringValue == "-2.12", "Switching must submit exact input and refresh the destination")

    filter = model.profile.filters![0]
    filter.kind = .highPass; filter.gain = 0; filter.frequency = 321.123456789; filter.channel = .left
    model.updateFilter(at: 0, with: filter)
    flush()
    select("All rows")
    require(activeField("Filter 1 frequency in hertz").stringValue == "321" &&
            !fields().contains(where: { $0.isEnabled && $0.accessibilityLabel() == "Filter 1 gain in decibels" }),
            "Reactivation must also apply filter structure changes, including gainless types")
    state.active = false
    flush()
    let inactive = fields().map { ($0, $0.stringValue) }
    FilterParameterEditing.update(model: model, index: 0) { $0.frequency = 543.123456789 }
    flush()
    require(inactive.allSatisfy { !$0.0.isEnabled && $0.0.stringValue == $0.1 }, "A collapsed rack must not refresh any dormant numeric editor")
    state.active = true
    flush()
    require(activeField("Filter 1 frequency in hertz").stringValue == "543" && !model.running && !model.route.hasResources,
            "Reopening the rack must show current values without starting audio")
    print("PASS dormant editor isolation, native identity, live reactivation, exact input, rejected switches, structural edits, and stopped routing")
}
