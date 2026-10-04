import AppKit
import SwiftUI

private struct GlassPresentationProbe: View {
    @Environment(\.auralUsesLiquidGlass) private var usesGlass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let observe: (Bool, Bool, Bool) -> Void
    var body: some View {
        Text("Glass presentation").onAppear { observe(usesGlass, reduceTransparency, contrast == .increased) }
    }
}

@MainActor func checkGlassPresentationPolicy() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    for style in AuralInterfaceStyle.allCases {
        for visible in [true, false] {
            var observed: Bool?
            var expected: Bool?
            let host = NSHostingView(rootView: GlassPresentationProbe { glass, transparency, contrast in
                observed = glass
                expected = style == .liquidGlass && AuralInterfaceStyle.liquidGlassSupported && !transparency && !contrast && visible
            }
                .auralGlassVisibility(visible)
                .auralAppearance(.dark, style: style))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            require(observed != nil && observed == expected, "Native view environments must apply the style, accessibility fallbacks, and hidden-editor glass suppression")
        }
    }
    for enabled in [false, true] {
        for visible in [false, true] {
            var observed: Bool?
            let host = NSHostingView(rootView: GlassPresentationProbe { glass, _, _ in observed = glass }
                .auralGlassVisibility(visible)
                .environment(\.auralUsesLiquidGlass, enabled))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            require(observed == (enabled && visible), "Hidden editors must suppress glass without enabling it in Standard or accessibility fallback presentations")
        }
    }
    print("PASS native Liquid Glass environment, accessibility fallbacks, and hidden-editor effect suppression")
}
