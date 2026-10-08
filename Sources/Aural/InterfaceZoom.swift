import SwiftUI

enum InterfaceZoomShortcut {
    case increase, decrease, reset

    init?(key: String, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        switch (key, flags) {
        // Accept both the shifted plus key and the unshifted equals key, as well
        // as keypad plus. Keyboard layouts report the shifted key differently.
        case ("+", .command), ("=", .command), ("+", [.command, .shift]), ("=", [.command, .shift]): self = .increase
        case ("-", .command): self = .decrease
        case ("0", .command): self = .reset
        default: return nil
        }
    }

    @MainActor func perform(on model: Model) {
        switch self {
        case .increase: model.zoomIn()
        case .decrease: model.zoomOut()
        case .reset: model.resetZoom()
        }
    }
}

/// Reserve the transformed size in layout instead of painting larger controls
/// over their neighbours. Flexible content receives the remaining logical space,
/// so the workspace's graph shrinks as text, controls, and their hit targets grow.
struct InterfaceZoomLayout: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(logicalProposal(proposal))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: logicalProposal(ProposedViewSize(bounds.size)))
    }

    private func logicalProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width.map { $0 / scale }, height: proposal.height.map { $0 / scale })
    }
}

private struct AuralZoom: ViewModifier {
    @ObservedObject var model: Model

    func body(content: Content) -> some View {
        content
        .font(.system(size: 13 * model.interfaceZoom.scale))
        .auralControlSize(.regular)
        .environment(\.auralInterfaceScale, model.interfaceZoom.scale)
        .background(WindowKeyboardShortcuts { event, _ in
            guard let key = event.charactersIgnoringModifiers,
                  let shortcut = InterfaceZoomShortcut(key: key, modifiers: event.modifierFlags) else { return false }
            // Zoom only changes presentation. Leave a numeric draft and its focus
            // intact, including partial or invalid numbers awaiting correction.
            shortcut.perform(on: model)
            return true
        })
    }
}

private struct AuralInterfaceScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var auralInterfaceScale: CGFloat {
        get { self[AuralInterfaceScaleKey.self] }
        set { self[AuralInterfaceScaleKey.self] = newValue }
    }
}

private struct AuralFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    @Environment(\.auralInterfaceScale) private var scale
    func body(content: Content) -> some View { content.font(.system(size: size * scale, weight: weight, design: design)) }
}

private struct AuralFrame: ViewModifier {
    var minWidth: CGFloat?, idealWidth: CGFloat?, maxWidth: CGFloat?
    var minHeight: CGFloat?, idealHeight: CGFloat?, maxHeight: CGFloat?
    let alignment: Alignment
    @Environment(\.auralInterfaceScale) private var scale
    func body(content: Content) -> some View {
        content.frame(minWidth: minWidth.map { $0 * scale }, idealWidth: idealWidth.map { $0 * scale }, maxWidth: maxWidth.map { $0 * scale },
                      minHeight: minHeight.map { $0 * scale }, idealHeight: idealHeight.map { $0 * scale }, maxHeight: maxHeight.map { $0 * scale },
                      alignment: alignment)
    }
}

private struct AuralPadding: ViewModifier {
    let edges: Edge.Set
    let length: CGFloat
    @Environment(\.auralInterfaceScale) private var scale
    func body(content: Content) -> some View { content.padding(edges, length * scale) }
}

private struct AuralControlSize: ViewModifier {
    let base: ControlSize
    @Environment(\.auralInterfaceScale) private var scale
    func body(content: Content) -> some View {
        content.controlSize(scale >= 1.2 ? .large : (scale < 1 ? .small : base))
    }
}

extension View {
    func auralZoom(_ model: Model) -> some View { modifier(AuralZoom(model: model)) }
    func auralFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(AuralFont(size: size, weight: weight, design: design))
    }
    func auralFrame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modifier(AuralFrame(minWidth: width, idealWidth: width, maxWidth: width, minHeight: height, idealHeight: height, maxHeight: height, alignment: alignment))
    }
    func auralFrame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
                    minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modifier(AuralFrame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth,
                            minHeight: minHeight, idealHeight: idealHeight, maxHeight: maxHeight, alignment: alignment))
    }
    /// Padding grows with interface zoom so margins keep their proportion to text and controls.
    func auralPadding(_ length: CGFloat) -> some View { modifier(AuralPadding(edges: .all, length: length)) }
    func auralPadding(_ edges: Edge.Set, _ length: CGFloat) -> some View { modifier(AuralPadding(edges: edges, length: length)) }
    func auralControlSize(_ base: ControlSize) -> some View { modifier(AuralControlSize(base: base)) }
}
