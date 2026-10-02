import AppKit

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

// Use real NSWindow identities and AppKit notifications, but deterministic display state.
// No windows are ordered onscreen, no activation policy is changed, and Model/AudioRoute
// are deliberately absent from this test executable. Native UI smoke tests cover ordering.
@MainActor final class TestWindow: NSWindow {
    var displayed = true
    var minimized = false
    override var isVisible: Bool { displayed }
    override var isMiniaturized: Bool { minimized }

    init() {
        super.init(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
    }
}

@MainActor final class PolicyRecorder {
    var changes: [NSApplication.ActivationPolicy] = []
}

@MainActor final class Fixture {
    let recorder = PolicyRecorder()
    let presence: WindowPresence
    private var windows: [TestWindow] = []

    init() {
        let recorder = recorder
        presence = WindowPresence { policy in
            recorder.changes.append(policy)
            return true
        }
    }

    func window(visible: Bool = true, minimized: Bool = false, registered: Bool = true) -> TestWindow {
        let window = TestWindow()
        window.displayed = visible
        window.minimized = minimized
        windows.append(window)
        if registered { presence.register(window) }
        return window
    }

    func post(_ notification: Notification.Name, for window: NSWindow) {
        NotificationCenter.default.post(name: notification, object: window)
    }

    func requireLast(_ policy: NSApplication.ActivationPolicy, _ message: String) {
        require(recorder.changes.last == policy, message)
    }
}

@MainActor func drainMainQueue() {
    var drained = false
    DispatchQueue.main.async { drained = true }
    let deadline = Date().addingTimeInterval(1)
    while !drained && Date() < deadline {
        RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
    }
    require(drained, "Timed out while draining deferred window-close handling")
}

@main struct WindowTests {
    @MainActor static func main() {
        let application = NSApplication.shared
        let originalPolicy = application.activationPolicy()

        do {
            let fixture = Fixture()
            let unrelated = fixture.window(registered: false)
            fixture.post(NSWindow.didBecomeKeyNotification, for: unrelated)
            fixture.post(NSWindow.willCloseNotification, for: unrelated)
            drainMainQueue()
            require(fixture.recorder.changes.isEmpty, "Unregistered menus, popovers, and sheets must not change Dock presence")

            let main = fixture.window()
            fixture.post(NSWindow.didBecomeKeyNotification, for: main)
            fixture.requireLast(.regular, "A registered window becoming key must restore Dock presence")
            fixture.post(NSWindow.willCloseNotification, for: main)
            // willClose can be delivered while the closing window is still visible.
            require(main.isVisible, "The regression fixture must preserve pre-close visibility")
            drainMainQueue()
            fixture.requireLast(.accessory, "The last registered window closing must hide the Dock even with an unrelated visible window")
        }

        do {
            let fixture = Fixture()
            let main = fixture.window()
            let library = fixture.window()
            fixture.post(NSWindow.willCloseNotification, for: main)
            drainMainQueue()
            fixture.requireLast(.regular, "Closing main must retain Dock presence while another scene remains open")
            fixture.post(NSWindow.willCloseNotification, for: library)
            drainMainQueue()
            fixture.requireLast(.accessory, "Closing the final auxiliary scene must hide the Dock")
        }

        do {
            let fixture = Fixture()
            let main = fixture.window()
            let library = fixture.window(visible: false, minimized: true)
            fixture.post(NSWindow.willCloseNotification, for: main)
            drainMainQueue()
            fixture.requireLast(.regular, "A minimized scene must keep Dock access for restoring it")
            fixture.post(NSWindow.willCloseNotification, for: library)
            drainMainQueue()
            fixture.requireLast(.accessory, "A closed minimized scene must no longer retain Dock presence")
        }

        do {
            let fixture = Fixture()
            let main = fixture.window()
            fixture.post(NSWindow.willCloseNotification, for: main)
            drainMainQueue()
            fixture.requireLast(.accessory, "Initial close must enter status-only mode")
            fixture.presence.showInDock()
            fixture.requireLast(.regular, "Explicit window presentation must restore Dock presence immediately")
            fixture.post(NSWindow.didBecomeKeyNotification, for: main)
            let library = fixture.window()
            fixture.post(NSWindow.willCloseNotification, for: library)
            drainMainQueue()
            fixture.requireLast(.regular, "A retained window reopened by SwiftUI must count as open again")
            fixture.post(NSWindow.willCloseNotification, for: main)
            drainMainQueue()
            fixture.requireLast(.accessory, "The same retained window must support a second close")
        }

        do {
            let fixture = Fixture()
            let main = fixture.window()
            fixture.post(NSWindow.willCloseNotification, for: main)
            fixture.presence.showInDock()
            fixture.post(NSWindow.didBecomeKeyNotification, for: main)
            drainMainQueue()
            require(fixture.recorder.changes.allSatisfy { $0 == .regular }, "Deferred close handling must not hide the Dock after the window already reopened")
            fixture.post(NSWindow.willCloseNotification, for: main)
            drainMainQueue()
            fixture.requireLast(.accessory, "A window reopened during pending close handling must still close normally afterward")
        }

        do {
            let fixture = Fixture()
            let main = fixture.window()
            let library = fixture.window()
            fixture.post(NSWindow.willCloseNotification, for: main)
            fixture.post(NSWindow.willCloseNotification, for: library)
            drainMainQueue()
            require(!fixture.recorder.changes.isEmpty && fixture.recorder.changes.allSatisfy { $0 == .accessory }, "Two pending closes must not leave a stale open-window count")
        }

        require(application.activationPolicy() == originalPolicy, "Injected policy changes must not affect the test runner's actual Dock presence")
        print("PASS window registration, last close, multiple scenes, minimized windows, retained-window reopening, and pending-close races")
    }
}
