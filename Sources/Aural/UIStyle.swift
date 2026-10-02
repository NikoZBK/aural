import SwiftUI

enum AuralStyle {
    static let accent = Color(red: 0.36, green: 0.85, blue: 0.78)
    static let background = Color(red: 0.065, green: 0.075, blue: 0.089)
    static let surface = Color(red: 0.091, green: 0.105, blue: 0.122)
    static let elevated = Color(red: 0.135, green: 0.155, blue: 0.177)
    static let border = Color.white.opacity(0.085)
    static let secondary = Color(red: 0.66, green: 0.71, blue: 0.77)
    static let warning = Color(red: 1, green: 0.73, blue: 0.40)
    static let plotColors: [Color] = [accent, Color(red: 0.48, green: 0.68, blue: 1),
        Color(red: 0.77, green: 0.59, blue: 1), warning, Color(red: 0.98, green: 0.51, blue: 0.61),
        Color(red: 0.69, green: 0.82, blue: 0.46)]
}

extension View {
    func auralPanel(padding: CGFloat = 18) -> some View {
        self.padding(padding)
            .background(AuralStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AuralStyle.border))
    }
}

struct AuralSectionLabel: View {
    let title: String
    var systemImage: String? = nil
    var body: some View {
        HStack(spacing: 7) {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(title.uppercased()).tracking(0.8)
        }.font(.system(size: 10, weight: .semibold)).foregroundStyle(AuralStyle.secondary)
    }
}

struct AuralNotice: View {
    let message: String
    var isError = false
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(isError ? AuralStyle.warning : AuralStyle.accent)
                .accessibilityHidden(true)
            Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12)).padding(12)
            .background((isError ? AuralStyle.warning : AuralStyle.accent).opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AuralButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(prominent ? AuralStyle.background : Color.primary)
            .background(prominent ? AuralStyle.accent : AuralStyle.elevated, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(prominent ? .clear : AuralStyle.border))
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
    }
}

/// Edits are committed as complete numbers. Partial input never reaches the audio engine.
struct PrecisionField: View {
    let value: Double
    let range: ClosedRange<Double>
    let label: String
    var decimals = 2
    var revision = 0
    let commit: (Double) -> Void
    @State private var text = ""
    @State private var invalid = false
    @State private var draftRevision = 0
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text)
            .textFieldStyle(.plain).multilineTextAlignment(.trailing)
            .font(.system(size: 12, design: .monospaced)).monospacedDigit()
            .padding(.horizontal, 7).frame(height: 27)
            .background(AuralStyle.background, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(invalid ? AuralStyle.warning : (focused ? AuralStyle.accent : AuralStyle.border)))
            .focused($focused).onSubmit { submit() }
            .onChange(of: focused) { wasFocused, isFocused in if wasFocused && !isFocused { submit() } }
            .onChange(of: value) { _, _ in restore() }
            .onChange(of: revision) { _, _ in restore() }
            .onAppear { restore() }
            .accessibilityLabel(label)
            .accessibilityHint(invalid ? "Invalid number. Use \(range.lowerBound) to \(range.upperBound)." : "Press Return to apply. Escape cancels.")
            .help(invalid ? "Enter a number from \(range.lowerBound) to \(range.upperBound)." : label)
            .onExitCommand { restore(); focused = false }
    }
    private func restore() { text = String(format: "%.*f", decimals, value); invalid = false; draftRevision = revision }
    private func submit() {
        // Focus loss can precede onChange when a preset or A/B replaces this field.
        guard draftRevision == revision else { restore(); return }
        guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite, range.contains(number) else {
            invalid = true
            NSSound.beep()
            return
        }
        // Display rounding must never quantize an untouched imported value.
        if text != String(format: "%.*f", decimals, value) { commit(number) }
        invalid = false
    }
}
