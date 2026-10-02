import AppKit
import OSLog
import SwiftUI

/// Tracks only our scene windows; status menus, popovers, and sheets do not own Dock presence.
@MainActor final class WindowPresence: NSObject {
    static let shared = WindowPresence()
    private let windows = NSHashTable<NSWindow>.weakObjects()
    private let closedWindows = NSHashTable<NSWindow>.weakObjects()
    private let setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Bool
    private let logger = Logger(subsystem: "local.aural.equalizer", category: "WindowPresence")

    init(setPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Bool = { NSApp.setActivationPolicy($0) }) {
        self.setPolicy = setPolicy
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    func register(_ window: NSWindow) { windows.add(window) }

    func showInDock() { apply(.regular) }

    private func apply(_ policy: NSApplication.ActivationPolicy) {
        if !setPolicy(policy) {
            logger.error("Could not change Aural's Dock visibility to activation policy \(policy.rawValue).")
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, windows.contains(window) else { return }
        // willClose arrives before isVisible changes. Keep the marker if SwiftUI retains the window.
        closedWindows.add(window)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let hasOpenWindow = self.windows.allObjects.contains {
                !self.closedWindows.contains($0) && ($0.isVisible || $0.isMiniaturized)
            }
            self.apply(hasOpenWindow ? .regular : .accessory)
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, windows.contains(window) else { return }
        closedWindows.remove(window)
        showInDock()
    }
}

/// Discover the SwiftUI-owned NSWindow without replacing its delegate or relying on view disappearance.
struct WindowRegistration: NSViewRepresentable {
    func makeNSView(context: Context) -> RegistrationView { RegistrationView() }
    func updateNSView(_ nsView: RegistrationView, context: Context) {}

    final class RegistrationView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { WindowPresence.shared.register(window) }
        }
    }
}

extension OpenWindowAction {
    @MainActor func showAuralWindow(_ id: String) {
        WindowPresence.shared.showInDock()
        self(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
