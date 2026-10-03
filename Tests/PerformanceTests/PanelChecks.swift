import AppKit
import SwiftUI

private struct PanelProbe: NSViewRepresentable {
    let label: String
    let created: () -> Void
    func makeNSView(context: Context) -> NSTextField { created(); return NSTextField(labelWithString: label) }
    func updateNSView(_ view: NSTextField, context: Context) { view.stringValue = label }
}

@MainActor func checkPanelHosting() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let container = InterfacePanelContainer()
    window.contentView = container
    var simpleCreations = 0, professionalCreations = 0
    func show(_ mode: InterfaceMode) {
        container.show(mode, simple: AnyView(PanelProbe(label: "Simple", created: { simpleCreations += 1 })),
                       professional: AnyView(PanelProbe(label: "Professional", created: { professionalCreations += 1 })))
    }
    show(.easy)
    require(container.isLoading && container.subviews.count == 1 && container.subviews[0] is InterfaceLoadingView,
            "Startup must attach the inexpensive loading blocks before creating any controls")
    require(simpleCreations == 0 && professionalCreations == 0, "Panel creation must defer until the loading frame can draw")
    show(.professional)
    show(.easy)
    let deadline = Date().addingTimeInterval(5)
    while container.isLoading {
        require(Date() < deadline, "Startup panel preparation did not finish")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    require(simpleCreations == 1 && professionalCreations == 1,
            "Both modes' native controls must exist before the first mode switch")
    require(container.displayedMode == .easy, "The latest mode request during startup must win")
    container.layoutSubtreeIfNeeded()
    let simple = container.subviews[0]
    let field = NSTextField(string: "pending input")
    simple.addSubview(field)
    require(window.makeFirstResponder(field), "The fixture field must accept focus")
    show(.professional)
    container.layoutSubtreeIfNeeded()
    let professional = container.subviews[0]
    require(simple.superview == nil && professional.superview === container,
            "The inactive panel must be removed from the window and accessibility hierarchy")
    require(window.firstResponder !== field && field.currentEditor() == nil, "A hidden panel must not retain keyboard input")
    for _ in 0..<20 {
        show(.easy)
        require(container.subviews.count == 1 && container.subviews[0] === simple && professional.superview == nil,
                "Simple must reuse its panel and leave only one panel attached")
        show(.professional)
        require(container.subviews.count == 1 && container.subviews[0] === professional && simple.superview == nil,
                "Professional must reuse its panel and leave only one panel attached")
    }
    require(simpleCreations == 1 && professionalCreations == 1, "Repeated switches must never reconstruct the native controls")
    container.setFrameSize(NSSize(width: 1060, height: 610))
    container.layoutSubtreeIfNeeded()
    require(professional.frame == container.bounds, "A retained panel must track window resizing")
    print("PASS immediate startup placeholders, two-panel preload, latest request, retained native controls, exclusive attachment, focus release, and resizing")
}
