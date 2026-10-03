import SwiftUI

/// Prepare both modes once at startup, retaining native controls between swaps.
struct InterfacePanelHost<Simple: View, Professional: View>: NSViewRepresentable {
    let mode: InterfaceMode
    let simple: Simple
    let professional: Professional
    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> InterfacePanelContainer { InterfacePanelContainer() }

    func updateNSView(_ view: InterfacePanelContainer, context: Context) {
        view.show(mode, simple: AnyView(simple.environment(\.self, environment)),
                  professional: AnyView(professional.environment(\.self, environment)),
                  palette: InterfaceLoadingPalette(environment))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InterfacePanelContainer, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

}

final class InterfacePanelContainer: NSView {
    private var panels: [InterfaceMode: NSHostingView<AnyView>] = [:]
    private var contents: [InterfaceMode: AnyView] = [:]
    private var requestedMode = InterfaceMode.easy
    private(set) var displayedMode: InterfaceMode?
    private var preparation: DispatchWorkItem?
    private let loading = InterfaceLoadingView()
    private(set) var isLoading = true

    func show(_ mode: InterfaceMode, simple: AnyView, professional: AnyView,
              palette: InterfaceLoadingPalette = InterfaceLoadingPalette(EnvironmentValues())) {
        requestedMode = mode
        contents = [.easy: simple, .professional: professional]
        if isLoading {
            loading.configure(mode: mode, palette: palette)
            if loading.superview == nil { loading.frame = bounds; addSubview(loading) }
            if preparation == nil { schedulePreparation() }
        } else { present(mode) }
    }

    private func schedulePreparation() {
        let item = DispatchWorkItem { [weak self] in self?.prepareNextPanel() }
        preparation = item
        // Let the first window and its cheap native skeleton reach the compositor.
        // AppKit controls stay on the main thread; analysis uses its worker.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(34), execute: item)
    }

    private func prepareNextPanel() {
        guard let mode = InterfaceMode.allCases.first(where: { panels[$0] == nil }) else {
            preconditionFailure("Both panels were already prepared.")
        }
        guard let content = contents[mode] else { preconditionFailure("Missing startup panel content.") }
        let panel = NSHostingView(rootView: content)
        panel.sizingOptions = []
        panel.autoresizingMask = [.width, .height]
        panel.frame = bounds
        panel.isHidden = true
        addSubview(panel, positioned: .below, relativeTo: loading)
        panel.layoutSubtreeIfNeeded()
        panel.removeFromSuperview()
        panels[mode] = panel
        if panels.count < InterfaceMode.allCases.count { schedulePreparation() }
        else {
            preparation = nil
            isLoading = false
            present(requestedMode)
        }
    }

    private func present(_ mode: InterfaceMode) {
        guard let panel = panels[mode], let content = contents[mode] else {
            preconditionFailure("A mode can only be shown after startup preparation.")
        }
        panel.rootView = content
        if displayedMode != mode {
            window?.makeFirstResponder(nil)
            for previous in subviews { previous.removeFromSuperview() }
            panel.frame = bounds
            panel.isHidden = false
            addSubview(panel)
            displayedMode = mode
        }
    }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }

    deinit { preparation?.cancel() }
}
