import AppKit
import Combine
import SwiftUI

@MainActor func checkNativeControlIsolation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-control-isolation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let model = Model(settingsFile: directory.appendingPathComponent("settings.json"), readLoginStatus: { .notRegistered })
    model.setInterfaceMode(.professional)
    let icon = AppIconController(running: model.$running.eraseToAnyPublisher(), bypass: model.$bypass.eraseToAnyPublisher(),
                                 loadImage: { _ in NSImage(size: NSSize(width: 16, height: 16)) }, reportError: { fatalError($0) })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 690), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: MainView(model: model, icon: icon))
    window.contentView = host
    func flush() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
    func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, $0) }
    }
    func comparison() -> NSSegmentedControl {
        guard let control = descendants(NSSegmentedControl.self, host).first(where: {
            $0.segmentCount == 2 && $0.label(forSegment: 0) == "A" && $0.label(forSegment: 1) == "B"
        }) else { fatalError("Missing native A/B control") }
        return control
    }
    flush()
    guard let field = descendants(NSTextField.self, host).first(where: { $0.isEditable && $0.accessibilityLabel() == "Exact preamp in decibels" }),
          window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else { fatalError("Missing native preamp editor") }
    editor.insertText("-", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    flush()
    let before = model.profile
    let rejected = comparison()
    rejected.selectedSegment = 1
    rejected.sendAction(rejected.action, to: rejected.target)
    flush()
    require(model.comparisonSlot == .a && comparison().selectedSegment == 0 && model.profile == before && field.stringValue == "-",
            "An isolated toolbar must reset a rejected A/B click and preserve the invalid numeric draft")
    guard let activeEditor = field.currentEditor() as? NSTextView else { fatalError("A rejected action must retain native editing focus") }
    activeEditor.insertText("-3.123456789", replacementRange: NSRange(location: 0, length: activeEditor.string.utf16.count))
    flush()
    let accepted = comparison()
    accepted.selectedSegment = 1
    accepted.sendAction(accepted.action, to: accepted.target)
    flush()
    require(model.comparisonSlot == .b && comparison().selectedSegment == 1 && model.profile.preamp == -3.123456789 && !model.running,
            "Retained toolbar actions must submit exact pending input and refresh their actual selected state")
    print("PASS isolated native toolbar updates, rejected A/B reset, retained invalid drafts, exact submission, and audio neutrality")
}
