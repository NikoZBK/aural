import SwiftUI

extension AuralTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum AuralStyle {
    // Native dynamic colors resolve in each presentation, including Canvas and AppKit panels.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    static let accent = Color(nsColor: .controlAccentColor)
    static func accentForeground(in environment: EnvironmentValues) -> Color {
        let resolved = accent.resolve(in: environment)
        func linear(_ component: Float) -> Double {
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(resolved.red) + 0.7152 * linear(resolved.green) + 0.0722 * linear(resolved.blue)
        return luminance > 0.179 ? .black : .white
    }
    static let background = adaptive(light: NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1),
                                     dark: NSColor(srgbRed: 0.065, green: 0.075, blue: 0.089, alpha: 1))
    static let surface = adaptive(light: .white,
                                  dark: NSColor(srgbRed: 0.091, green: 0.105, blue: 0.122, alpha: 1))
    static let elevated = adaptive(light: NSColor(srgbRed: 0.88, green: 0.90, blue: 0.92, alpha: 1),
                                   dark: NSColor(srgbRed: 0.135, green: 0.155, blue: 0.177, alpha: 1))
    static let border = adaptive(light: .black.withAlphaComponent(0.14), dark: .white.withAlphaComponent(0.085))
    static let secondary = adaptive(light: NSColor(srgbRed: 0.36, green: 0.40, blue: 0.46, alpha: 1),
                                    dark: NSColor(srgbRed: 0.66, green: 0.71, blue: 0.77, alpha: 1))
    static let warning = adaptive(light: NSColor(srgbRed: 0.60, green: 0.29, blue: 0.025, alpha: 1),
                                  dark: NSColor(srgbRed: 1, green: 0.73, blue: 0.40, alpha: 1))
    static let plotBackground = adaptive(light: .white.withAlphaComponent(0.60), dark: .black.withAlphaComponent(0.16))
    static let grid = adaptive(light: .black, dark: .white)
    static let plotColors: [Color] = [accent,
        adaptive(light: NSColor(srgbRed: 0.23, green: 0.43, blue: 0.80, alpha: 1),
                 dark: NSColor(srgbRed: 0.48, green: 0.68, blue: 1, alpha: 1)),
        adaptive(light: NSColor(srgbRed: 0.55, green: 0.30, blue: 0.75, alpha: 1),
                 dark: NSColor(srgbRed: 0.77, green: 0.59, blue: 1, alpha: 1)), warning,
        adaptive(light: NSColor(srgbRed: 0.73, green: 0.26, blue: 0.38, alpha: 1),
                 dark: NSColor(srgbRed: 0.98, green: 0.51, blue: 0.61, alpha: 1)),
        adaptive(light: NSColor(srgbRed: 0.35, green: 0.46, blue: 0.10, alpha: 1),
                 dark: NSColor(srgbRed: 0.69, green: 0.82, blue: 0.46, alpha: 1))]
}

private struct AuralMenuStyle: MenuStyle {
    @Environment(\.colorScheme) private var colorScheme
    func makeBody(configuration: Configuration) -> some View {
        // AppKit-backed menu buttons retain resolved label colors across scheme changes.
        // Recreate only the button, leaving numeric fields and editor state intact.
        Menu(configuration).menuStyle(.automatic).id(colorScheme)
    }
}

private struct AuralAppearance: ViewModifier {
    let theme: AuralTheme
    func body(content: Content) -> some View {
        content.background(AuralStyle.background).menuStyle(AuralMenuStyle())
            .preferredColorScheme(theme.colorScheme).tint(AuralStyle.accent)
    }
}

extension View {
    func auralAppearance(_ theme: AuralTheme) -> some View { modifier(AuralAppearance(theme: theme)) }
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
    @Environment(\.self) private var environment
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(prominent ? AuralStyle.accentForeground(in: environment) : Color.primary)
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
    let currentRevision: () -> Int
    weak var submissions: PrecisionSubmissionCoordinator? = nil
    let commit: (Double) -> Void
    @State private var draft = PrecisionInput()
    @State private var invalid = false
    @State private var fieldID = UUID()
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: Binding(get: { draft.text }, set: { draft.edit($0); invalid = false }))
            .textFieldStyle(.plain).multilineTextAlignment(.trailing)
            .font(.system(size: 12, design: .monospaced)).monospacedDigit()
            .padding(.horizontal, 7).frame(height: 27)
            .background(AuralStyle.background, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(invalid ? AuralStyle.warning : (focused ? AuralStyle.accent : AuralStyle.border)))
            .focused($focused).onSubmit { _ = submit() }
            .onChange(of: focused) { wasFocused, isFocused in
                if isFocused { registerSubmission() }
                else if wasFocused { _ = submit(); submissions?.deactivate(fieldID) }
            }
            .onChange(of: value) { _, _ in restore(); registerSubmission() }
            .onChange(of: revision) { _, _ in restore(); registerSubmission() }
            .onAppear { restore(); registerSubmission() }
            .onDisappear { submissions?.deactivate(fieldID) }
            .accessibilityLabel(label)
            .accessibilityHint(invalid ? "Invalid number. Use \(range.lowerBound) to \(range.upperBound)." : "Press Return to apply. Escape cancels.")
            .help(invalid ? "Enter a number from \(range.lowerBound) to \(range.upperBound)." : label)
            .onExitCommand { restore(); focused = false }
    }
    private func restore() { draft.restore(value: value, decimals: decimals, revision: revision); invalid = false }
    private func registerSubmission() {
        if focused { submissions?.activate(fieldID, submit: submit) }
    }
    private func submit() -> PrecisionSubmissionCoordinator.Result {
        // A focus-loss callback may arrive after another control replaces the EQ.
        switch draft.submission(in: range, revision: currentRevision()) {
        case .stale: restore(); return .rejected
        case .unchanged: invalid = false; return .unchanged
        case .invalid:
            invalid = true
            NSSound.beep()
            return .rejected
        case .value(let number):
            draft.accept()
            commit(number)
            invalid = false
            return .submitted
        }
    }
}
