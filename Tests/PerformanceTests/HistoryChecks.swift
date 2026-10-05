import AppKit

@MainActor private final class HistoryTextView: NSTextView {
    let history = UndoManager()
    override var undoManager: UndoManager? { history }

    func edit(_ value: String) {
        let previous = string
        history.registerUndo(withTarget: self) { $0.edit(previous) }
        string = value
    }
}

@MainActor func checkHistoryShortcuts() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-history-keys-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let model = Model(settingsFile: directory.appendingPathComponent("settings.json"), readLoginStatus: { .notRegistered })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close(); model.stop() }
    let original = model.profile
    model.setPreamp(-4)
    let edited = model.profile

    func press(_ key: String, _ flags: NSEvent.ModifierFlags = .command) {
        guard let shortcut = HistoryShortcut(key: key, modifiers: flags) else { fatalError("Missing history shortcut") }
        shortcut.perform(in: window, canUndo: model.canUndo, canRedo: model.canRedo,
                         undo: model.undoProfile, redo: model.redoProfile)
    }
    press("z")
    require(model.profile == original && model.canRedo, "Command-Z must undo the current EQ")
    press("y")
    require(model.profile == edited && model.canUndo, "Command-Y must redo the current EQ")
    press("z")
    press("Z", [.command, .shift])
    require(model.profile == edited, "Shift-Command-Z must also redo EQ changes")
    press("Z", [.command, .capsLock])
    require(model.profile == original, "Caps Lock must not disable Command-Z")
    press("y")

    for flags: NSEvent.ModifierFlags in [[], .control, [.command, .option], [.command, .control]] {
        require(HistoryShortcut(key: "z", modifiers: flags) == nil, "Other modifier combinations must retain their existing behavior")
    }
    require(HistoryShortcut(key: "y", modifiers: [.command, .shift]) == nil &&
            HistoryShortcut(key: "a", modifiers: .command) == nil, "Other commands must pass through")

    let editor = HistoryTextView(frame: window.contentView!.bounds)
    editor.isEditable = true
    editor.history.groupsByEvent = false
    editor.string = "1.00"
    window.contentView = editor
    require(window.makeFirstResponder(editor), "The fixture must focus the native text editor")
    editor.history.beginUndoGrouping()
    editor.edit("1.")
    editor.history.endUndoGrouping()
    press("z")
    require(editor.string == "1.00" && model.profile == edited, "Undo while typing must restore text without touching EQ")
    press("y")
    require(editor.string == "1." && model.profile == edited, "Command-Y while typing must redo text without submitting a partial number")
    press("z")
    press("Z", [.command, .shift])
    require(editor.string == "1." && model.profile == edited, "Native Mac redo must share the text history")
    editor.history.removeAllActions()
    press("z")
    require(model.profile == original, "An untouched field left focused after a button action must not block EQ undo")
    press("y")
    require(model.profile == edited, "An untouched field must not block EQ redo")

    let submissions = PrecisionSubmissionCoordinator()
    var rejected = false
    submissions.activate(UUID()) { rejected = true; return .rejected }
    HistoryShortcut.undo.perform(in: window, canUndo: model.canUndo, canRedo: model.canRedo,
                                 undo: { if submissions.submitActive() != .rejected { model.undoProfile() } },
                                 redo: model.redoProfile)
    require(rejected && model.profile == edited, "History fallback must respect rejected numeric submissions")

    editor.isEditable = false
    press("z")
    require(model.profile == original, "Read-only text selection must not capture EQ history keys")
    require(!model.running && !model.bypass && !model.route.hasResources && model.error == nil,
            "Keyboard history must preserve stopped processing and bypass state")
    print("PASS standard EQ undo/redo keys, redo alias, modifiers, native text history, untouched-field fallback, rejected input, and audio neutrality")
}
