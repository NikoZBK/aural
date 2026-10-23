import AppKit
import SwiftUI

@MainActor func checkLazyDraftEditor() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-lazy-draft-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let model = Model(settingsFile: directory.appendingPathComponent("settings.json"), readLoginStatus: { .notRegistered })
    var profile = Profile()
    profile.filters = (0..<Profile.maxFilters).map { ImportedFilter(kind: .peak, frequency: 30 + Double($0) * 200, gain: 0, q: 1.4, enabled: true) }
    require(model.replaceProfile(profile), "The lazy draft fixture must validate")
    let original = model.profile
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: FilterEditor(model: model))
    window.contentView = host
    func flush() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
    func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, $0) }
    }
    flush()
    let firstCount = descendants(NSTextField.self, host).filter(\.isEditable).count
    require(firstCount > 0 && firstCount < Profile.maxFilters,
            "Opening a maximum-size draft must construct visible fields instead of all 192 parameter editors: \(firstCount)")
    guard let scroll = descendants(NSScrollView.self, host).first(where: { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 100 }),
          let document = scroll.documentView else { fatalError("The draft must have a scrollable native viewport") }
    func scrollToEnd(_ end: Bool) {
        let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
        let y = (end == document.isFlipped) ? bottom : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        flush()
    }
    scrollToEnd(true)
    require(descendants(NSTextField.self, host).contains { Double($0.stringValue) == profile.filters?.last?.frequency },
            "The last filter must remain reachable in a lazy maximum-size draft")
    guard let gain = descendants(NSTextField.self, host).last(where: { $0.isEditable && $0.placeholderString == "Gain" }),
          window.makeFirstResponder(gain), let editor = gain.currentEditor() as? NSTextView else { fatalError("The last draft row must remain editable") }
    editor.insertText("-", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    flush()
    window.makeFirstResponder(nil)
    scrollToEnd(false)
    scrollToEnd(true)
    require(descendants(NSTextField.self, host).contains { $0.isEditable && $0.placeholderString == "Gain" && $0.stringValue == "-" },
            "Scrolling a lazy draft must retain incomplete typed numbers")
    require(model.profile == original && !model.running && !model.route.hasResources,
            "Opening, editing, and scrolling a draft must preserve the active EQ and audio state")
    print("PASS lazy maximum-size drafts, last-row access, incomplete input persistence, and audio neutrality")
}
