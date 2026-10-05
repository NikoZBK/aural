import AppKit
import OSLog
import SwiftUI

enum HistoryShortcut {
    case undo, redo

    init?(key: String, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        switch (key.lowercased(), flags) {
        case ("z", .command): self = .undo
        case ("z", [.command, .shift]), ("y", .command): self = .redo
        default: return nil
        }
    }

    @MainActor func perform(in window: NSWindow, canUndo: Bool, canRedo: Bool,
                            undo: () -> Void, redo: () -> Void) {
        // Native typing history takes precedence. A button can leave an untouched
        // field focused; if typing has no history, use the editor's validated action.
        let editor = window.firstResponder as? NSTextView
        let manager = editor?.isEditable == true ? editor?.undoManager : nil
        switch self {
        case .undo:
            if let manager, manager.canUndo { manager.undo() }
            else if canUndo { undo() }
            else { NSSound.beep() }
        case .redo:
            if let manager, manager.canRedo { manager.redo() }
            else if canRedo { redo() }
            else { NSSound.beep() }
        }
    }
}

/// Handle standard history keys before SwiftUI's menu and sheet shortcuts compete.
/// Each editor owns only its key window; other windows retain native text commands.
struct HistoryKeyboardShortcuts: View {
    let canUndo: Bool
    let canRedo: Bool
    let undo: () -> Void
    let redo: () -> Void

    var body: some View {
        WindowKeyboardShortcuts { event, window in
            guard let key = event.charactersIgnoringModifiers,
                  let shortcut = HistoryShortcut(key: key, modifiers: event.modifierFlags) else { return false }
            shortcut.perform(in: window, canUndo: canUndo, canRedo: canRedo, undo: undo, redo: redo)
            return true
        }
    }
}

/// Shared key-window scoping keeps shortcuts out of other apps and parent windows
/// while a sheet owns the keyboard. Returning false preserves normal key handling.
struct WindowKeyboardShortcuts: NSViewRepresentable {
    let handle: (NSEvent, NSWindow) -> Bool

    func makeNSView(context: Context) -> ShortcutView { ShortcutView(actions: self) }
    func updateNSView(_ nsView: ShortcutView, context: Context) { nsView.actions = self }
    static func dismantleNSView(_ nsView: ShortcutView, coordinator: ()) { nsView.removeMonitor() }

    final class ShortcutView: NSView {
        var actions: WindowKeyboardShortcuts
        private var monitor: Any?
        private let logger = Logger(subsystem: "local.aural.equalizer", category: "KeyboardShortcuts")

        init(actions: WindowKeyboardShortcuts) {
            self.actions = actions
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("History shortcuts must be created programmatically") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window === NSApp.keyWindow,
                      event.window === window, window.attachedSheet == nil else { return event }
                return self.actions.handle(event, window) ? nil : event
            }
            if monitor == nil { logger.error("Could not register window keyboard shortcuts.") }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}
