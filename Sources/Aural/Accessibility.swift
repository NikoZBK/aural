import SwiftUI

/// Describe actual audio settings rather than a slider's normalized percentage.
enum AuralAccessibility {
    static func balance(_ value: Double) -> String {
        value == 0 ? "Centered" : String(format: "%.0f percent %@", abs(value) * 100, value < 0 ? "left" : "right")
    }
    static func percentage(_ value: Double) -> String { String(format: "%.0f percent", value * 100) }
    static func decibels(_ value: Double) -> String { String(format: "%.2f decibels", value) }
    static func samplePeak(_ value: Double) -> String {
        value > -90 ? String(format: "%.1f decibels relative to full scale", value) : "Silent"
    }
}

private struct AuralAnnouncement: ViewModifier {
    let message: String?
    // Only the current window announces shared model changes. Background windows
    // still expose the notice, without repeating speech from the focused window.
    @Environment(\.controlActiveState) private var activeState
    func body(content: Content) -> some View {
        content.onChange(of: message) { _, message in
            if activeState == .key, let message, !message.isEmpty {
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }
}

extension View {
    func auralAnnouncement(_ message: String?) -> some View { modifier(AuralAnnouncement(message: message)) }
}
