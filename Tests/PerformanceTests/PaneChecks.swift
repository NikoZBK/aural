import AppKit
import SwiftUI
import Combine

@MainActor func checkResizablePanes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-pane-checks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    var settings = Settings()
    settings.interfaceMode = .easy
    settings.startEQAutomatically = false
    let file = directory.appendingPathComponent("settings.json")
    try JSONEncoder().encode(settings).write(to: file)
    let model = Model(settingsFile: file, readLoginStatus: { .notRegistered })
    let originalProfile = model.profile
    let icon = AppIconController(running: model.$running.eraseToAnyPublisher(), bypass: model.$bypass.eraseToAnyPublisher(),
                                 loadImage: { _ in NSImage(size: NSSize(width: 16, height: 16)) }, reportError: { fatalError($0) })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: MainView(model: model, icon: icon))
    window.contentView = host
    func flush() { host.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
    func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
    flush()
    func show(_ mode: InterfaceMode) {
        model.setInterfaceMode(mode)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        flush()
    }
    for size in [NSSize(width: 900, height: 620), NSSize(width: 1500, height: 900)] {
        window.setContentSize(size)
        for mode in [InterfaceMode.professional, .easy, .professional] {
            show(mode)
            require(descendants(NSSplitView.self, in: host).isEmpty, "Preset selection must not reserve a sidebar or divider")
            require(host.frame.size == size, "The workspace must fit the supported window sizes")
        }
    }
    require(!descendants(NSTextField.self, in: host).filter { $0.isEditable }.isEmpty, "The native workspace must expose editable numeric fields")
    require(model.profile == originalProfile && !model.running, "Resizing and disclosure changes must preserve the current sound and playback")
    window.close()
    print("PASS workspace sizes, native numeric editors, no preset sidebar, and audio-neutral disclosure")
}
