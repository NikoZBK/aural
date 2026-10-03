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
    guard let container = descendants(InterfacePanelContainer.self, in: host).first else { fatalError("Missing mode container") }
    let deadline = Date().addingTimeInterval(10)
    while container.isLoading {
        require(Date() < deadline, "Pane controls did not finish preparing")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        flush()
    }
    func show(_ mode: InterfaceMode) {
        model.setInterfaceMode(mode)
        let deadline = Date().addingTimeInterval(5)
        // SwiftUI may apply an observed model change on the next run-loop turn.
        // Inspect the native panes only after their requested mode is attached.
        while container.displayedMode != mode {
            require(Date() < deadline, "The requested pane mode was not displayed")
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            flush()
        }
        flush()
    }
    func split() -> NSSplitView {
        let candidates = descendants(NSSplitView.self, in: host)
        guard let view = candidates.first(where: { $0.isVertical && $0.arrangedSubviews.count == (model.interfaceMode == .easy ? 2 : 3) }) else {
            fatalError("Missing native pane dividers: \(candidates.map { "\(type(of: $0)) vertical=\($0.isVertical) arranged=\($0.arrangedSubviews.count)" })")
        }
        return view
    }
    func resize(_ view: NSSplitView, widths: [CGFloat]) {
        require(view.isVertical && view.arrangedSubviews.count == widths.count + 1, "Expected horizontal panes with native dividers: vertical=\(view.isVertical), subviews=\(view.subviews.count), arranged=\(view.arrangedSubviews.count), type=\(type(of: view))")
        for (index, width) in widths.enumerated() { view.setPosition(width, ofDividerAt: index) }
        flush()
        for (index, width) in widths.enumerated() {
            require(abs(view.arrangedSubviews[index].frame.maxX - width) < 2, "Dragging a divider must change pane width")
        }
    }
    let simple = split()
    resize(simple, widths: [420])
    show(.professional)
    let professional = split()
    resize(professional, widths: [280, 1160])
    show(.easy)
    require(split() === simple && abs(simple.arrangedSubviews[0].frame.width - 420) < 2, "Simple must retain its custom pane widths across mode switches")
    show(.professional)
    require(split() === professional && abs(professional.arrangedSubviews[0].frame.width - 280) < 2, "Professional must retain its custom pane widths across mode switches")
    window.setContentSize(NSSize(width: 1060, height: 700)); flush()
    for (pane, minimum) in zip(professional.arrangedSubviews, [184.0, 580.0, 218.0]) {
        require(pane.frame.width >= minimum - 2 && professional.bounds.contains(pane.frame), "Shrinking the window must keep all panes usable and inside the viewport")
    }
    show(.easy)
    window.setContentSize(NSSize(width: 900, height: 640)); flush()
    for (pane, minimum) in zip(simple.arrangedSubviews, [260.0, 400.0]) {
        require(pane.frame.width >= minimum - 2 && simple.bounds.contains(pane.frame), "Simple must adapt to its minimum window size")
    }
    require(model.profile == originalProfile && !model.running, "Resizing and mode changes must preserve the current sound and playback")
    print("PASS native draggable panes, independent retained widths, responsive minimum sizes, and audio-neutral resizing")
}
