import AppKit
import SwiftUI

@MainActor func checkHorizontalFilterBank() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-filter-bank-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let model = Model(settingsFile: directory.appendingPathComponent("settings.json"), readLoginStatus: { .notRegistered })
    model.editGraphicAsFilters()
    let original = model.profile
    let submissions = PrecisionSubmissionCoordinator()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: EQBars(model: model, submissions: submissions, compact: true, showParameters: true)
        .environment(\.auralInterfaceScale, 1))
    window.contentView = host
    func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    for scale: CGFloat in [0.8, 1, 1.4] {
        host.rootView = EQBars(model: model, submissions: submissions, compact: true, showParameters: true)
            .environment(\.auralInterfaceScale, scale)
        // Include the narrow side inspector, not just the full-width bank. Its
        // columns must scroll at their normal size instead of squeezing fields.
        for width: CGFloat in [346, 600, 1000] {
            window.setContentSize(NSSize(width: width, height: 360 * scale))
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            let editors: [NSTextField] = fields(in: host).filter(\.isEditable)
            require(editors.count == 30, "The ten-filter bank must expose exactly one frequency, gain, and Q editor per band")
            for field in editors {
                // A 66-point field includes seven points of padding per side.
                require(field.bounds.width >= 52 * scale - 1 && field.bounds.height >= 12 * scale - 1 &&
                        abs((field.font?.pointSize ?? 0) - 12 * scale) < 0.1,
                        "Narrow banks must retain readable textboxes and fonts at \(width) points and \(scale) zoom: \(field.frame)")
            }
            let unsorted: [CGRect] = editors.map { field in field.convert(field.bounds, to: host) }
            let frames: [CGRect] = unsorted.sorted { first, second in
                if abs(first.minX - second.minX) > 1 { return first.minX < second.minX }
                return first.minY < second.minY
            }
            for index in 0..<10 {
                let column: [CGRect] = Array(frames[(index * 3)..<(index * 3 + 3)])
                for frame in column {
                    require(abs(frame.midX - column[0].midX) < 1 && frame.minY > 80 * scale && frame.maxY <= host.bounds.height + 1,
                            "Each filter's textboxes must align below its own fader: \(scale), \(column)")
                }
                require(column[1].minY >= column[0].maxY && column[2].minY >= column[1].maxY,
                        "Frequency, gain, and Q fields must stack without overlapping")
                if index > 0 {
                    require(column[0].minX > frames[(index - 1) * 3].maxX,
                            "Filters must run horizontally in distinct columns, including when the bank scrolls")
                }
            }
        }
    }
    let gainEditors: [NSTextField] = fields(in: host).filter(\.isEditable).sorted { first, second in
        let firstFrame = first.convert(first.bounds, to: host)
        let secondFrame = second.convert(second.bounds, to: host)
        if abs(firstFrame.minX - secondFrame.minX) > 1 { return firstFrame.minX < secondFrame.minX }
        return firstFrame.minY < secondFrame.minY
    }
    let gainField = gainEditors[1]
    require(window.makeFirstResponder(gainField), "A filter-bank gain field must accept native focus")
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    guard let editor = gainField.currentEditor() as? NSTextView else { fatalError("A filter-bank gain must have a native text editor") }
    editor.insertText("1.23456789", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    require(submissions.submitActive() == .submitted, "The active bank field must submit before a discrete action")
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    window.makeFirstResponder(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    require(model.profile.filters?[0].gain == 1.23456789, "Leaving a committed bank field must not replace its exact gain with rounded display text")
    model.undoProfile()
    require(model.profile == original, "One undo must restore the EQ after a numeric bank edit and focus loss")
    // An unchanged strip must be editable immediately after another band changes,
    // even though its expensive native presentation was retained unchanged.
    model.setBandGain(at: 5, to: -3)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    require(window.makeFirstResponder(gainField), "An unchanged strip must still accept focus")
    guard let retainedEditor = gainField.currentEditor() as? NSTextView else { fatalError("Missing retained strip editor") }
    retainedEditor.insertText("2.123456789", replacementRange: NSRange(location: 0, length: retainedEditor.string.utf16.count))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    require(submissions.submitActive() == .submitted && model.profile.filters?[0].gain == 2.123456789,
            "The first edit in an unchanged strip must capture the live revision and retain exact precision")
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    require(window.makeFirstResponder(gainField), "The retained field must accept a second edit")
    guard let staleEditor = gainField.currentEditor() as? NSTextView else { fatalError("Missing stale-draft editor") }
    staleEditor.insertText("-4.5", replacementRange: NSRange(location: 0, length: staleEditor.string.utf16.count))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    model.setBandGain(at: 5, to: -4)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    require(submissions.submitActive() == .rejected && model.profile.filters?[0].gain == 2.123456789,
            "Retained strip isolation must never allow an older draft to overwrite a newer EQ")
    window.makeFirstResponder(nil)
    FilterParameterEditing.update(model: model, index: 2) { $0.frequency = 137.123456789 }
    FilterParameterEditing.update(model: model, index: 2) { $0.q = 2.123456789 }
    require(model.profile.filters?[2].frequency == 137.123456789 && model.profile.filters?[2].q == 2.123456789 &&
            model.profile.filters?[2].gain == original.filters?[2].gain && !model.running,
            "Bank parameter edits must retain exact values and the other parameters without starting audio")
    print("PASS horizontal filter columns, textboxes beneath each fader, fractional zoom, scrolling layout, and exact parameter edits")
}
