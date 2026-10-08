import AppKit
import SwiftUI

/// Shared timing, so every surface moves with the same character. Springs are
/// critically damped like system controls; Reduce Motion keeps state changes
/// legible with a short crossfade instead of movement.
enum AuralMotion {
    /// Panels, layout changes, and content that moves.
    static let standard = Animation.smooth(duration: 0.38)
    /// Small state changes: selection, labels, and badges.
    static let quick = Animation.snappy(duration: 0.24)
    /// Press feedback and focus rings.
    static let instant = Animation.easeOut(duration: 0.12)
    static let fade = Animation.easeInOut(duration: 0.18)
    /// A surface leaving its place before the layout around it moves.
    static let vacate = Animation.easeIn(duration: 0.1)
    static let vacateDuration = Duration.milliseconds(100)
    /// The same surface fading in at its new place while the layout settles.
    static let arrive = Animation.easeOut(duration: 0.22).delay(0.18)

    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : animation
    }

    /// For imperative changes outside a view, such as commands and menu items.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

@MainActor @discardableResult
func withAuralAnimation<Result>(_ animation: Animation = AuralMotion.standard, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(AuralMotion.resolved(animation, reduceMotion: AuralMotion.reduceMotion), body)
}

private struct AuralAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(AuralMotion.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension AnyTransition {
    /// Notices arrive with a short drop from their edge and fade away in place.
    static func auralReveal(_ edge: Edge = .top, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let offset: CGFloat = edge == .top ? -8 : (edge == .bottom ? 8 : 0)
        return .asymmetric(insertion: .offset(y: offset).combined(with: .opacity),
                           removal: .opacity.combined(with: .scale(scale: 0.98, anchor: edge == .top ? .top : .center)))
    }
    /// Small status items settle into place rather than sliding.
    static func auralPop(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.86))
    }
}

extension View {
    /// Animates changes to `value` with Aural's timing, or a crossfade under Reduce Motion.
    func auralAnimation<Value: Equatable>(_ animation: Animation = AuralMotion.standard, value: Value) -> some View {
        modifier(AuralAnimation(animation: animation, value: value))
    }

    /// Symbol swaps use the system replace effect, matching Control Center and Finder.
    func auralSymbolTransition() -> some View {
        contentTransition(.symbolEffect(.replace))
    }

    /// A surface that moves somewhere else in the layout, such as the inspector moving
    /// beside the graph, jumps to its new frame while `hidden` instead of sliding
    /// across other content. Skipping the frame animation also means its contents
    /// are measured once rather than on every frame of the move.
    func auralRelocation<Placement: Equatable>(_ placement: Placement, hidden: Bool) -> some View {
        transaction(value: placement) { $0.animation = nil }
            .opacity(hidden ? 0 : 1)
    }
}
