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
    private static func adaptive(light: NSColor, dark: NSColor, highContrastLight: NSColor? = nil, highContrastDark: NSColor? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua, .aqua, .darkAqua]) {
            case .accessibilityHighContrastAqua: return highContrastLight ?? light
            case .accessibilityHighContrastDarkAqua: return highContrastDark ?? dark
            case .darkAqua: return dark
            default: return light
            }
        })
    }
    // A fixed instrument color, identical on every Mac, instead of the system accent.
    // It marks active state and data: the curve, selection, Start EQ, and the meter.
    private static let accentLight = (red: 0.04, green: 0.47, blue: 0.60)
    private static let accentDark = (red: 0.30, green: 0.74, blue: 0.86)
    private static let accentHighContrastLight = (red: 0.0, green: 0.36, blue: 0.47)
    private static let accentHighContrastDark = (red: 0.50, green: 0.85, blue: 0.95)
    static let accent = adaptive(light: NSColor(srgbRed: accentLight.red, green: accentLight.green, blue: accentLight.blue, alpha: 1),
                                 dark: NSColor(srgbRed: accentDark.red, green: accentDark.green, blue: accentDark.blue, alpha: 1),
                                 highContrastLight: NSColor(srgbRed: accentHighContrastLight.red, green: accentHighContrastLight.green, blue: accentHighContrastLight.blue, alpha: 1),
                                 highContrastDark: NSColor(srgbRed: accentHighContrastDark.red, green: accentHighContrastDark.green, blue: accentHighContrastDark.blue, alpha: 1))
    /// The accent as a plain SwiftUI color for native control tints; see `AuralAppearance`.
    static func staticAccent(for scheme: ColorScheme, increasedContrast: Bool = false) -> Color {
        let components = switch (scheme, increasedContrast) {
        case (.dark, false): accentDark
        case (.dark, true): accentHighContrastDark
        case (_, false): accentLight
        case (_, true): accentHighContrastLight
        }
        return Color(.sRGB, red: components.red, green: components.green, blue: components.blue)
    }
    static func accentForeground(in environment: EnvironmentValues) -> Color {
        let resolved = accent.resolve(in: environment)
        func linear(_ component: Float) -> Double {
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(resolved.red) + 0.7152 * linear(resolved.green) + 0.0722 * linear(resolved.blue)
        return luminance > 0.179 ? .black : .white
    }
    static let background = adaptive(light: NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1),
                                     dark: NSColor(srgbRed: 0.08, green: 0.08, blue: 0.085, alpha: 1))
    static let surface = adaptive(light: .white,
                                  dark: NSColor(srgbRed: 0.10, green: 0.105, blue: 0.11, alpha: 1))
    static let elevated = adaptive(light: NSColor(srgbRed: 0.89, green: 0.89, blue: 0.90, alpha: 1),
                                   dark: NSColor(srgbRed: 0.16, green: 0.165, blue: 0.17, alpha: 1))
    static let border = adaptive(light: .black.withAlphaComponent(0.14), dark: .white.withAlphaComponent(0.085),
                                 highContrastLight: .black.withAlphaComponent(0.6), highContrastDark: .white.withAlphaComponent(0.6))
    static let controlBorder = adaptive(light: .black.withAlphaComponent(0.5), dark: .white.withAlphaComponent(0.4),
                                        highContrastLight: .black, highContrastDark: .white)
    static let secondary = adaptive(light: NSColor(srgbRed: 0.36, green: 0.40, blue: 0.46, alpha: 1),
                                    dark: NSColor(srgbRed: 0.66, green: 0.71, blue: 0.77, alpha: 1))
    static let warning = adaptive(light: NSColor(srgbRed: 0.60, green: 0.29, blue: 0.025, alpha: 1),
                                  dark: NSColor(srgbRed: 1, green: 0.73, blue: 0.40, alpha: 1))
    static let plotBackground = adaptive(light: .white.withAlphaComponent(0.60), dark: .black.withAlphaComponent(0.16))
    static let grid = adaptive(light: .black, dark: .white)
    // Every trace stays distinct from the accent: right channel, Harman reference, then filters.
    static let plotColors: [Color] = [accent,
        adaptive(light: NSColor(srgbRed: 0.73, green: 0.26, blue: 0.38, alpha: 1),
                 dark: NSColor(srgbRed: 0.98, green: 0.51, blue: 0.61, alpha: 1)),
        adaptive(light: NSColor(srgbRed: 0.55, green: 0.30, blue: 0.75, alpha: 1),
                 dark: NSColor(srgbRed: 0.77, green: 0.59, blue: 1, alpha: 1)), warning,
        adaptive(light: NSColor(srgbRed: 0.35, green: 0.46, blue: 0.10, alpha: 1),
                 dark: NSColor(srgbRed: 0.69, green: 0.82, blue: 0.46, alpha: 1))]
}

private struct AuralAppearance: ViewModifier {
    let theme: AuralTheme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let scheme = theme.colorScheme ?? colorScheme
        // Forward an explicit theme in the same update as the surfaces, so
        // dynamic colors never resolve against the previous appearance.
        content.environment(\.colorScheme, scheme)
            .background(AuralStyle.background)
            // Native controls can resolve a bridged dynamic NSColor as red in the
            // older SDK compatibility path. Tint checkboxes and segmented controls
            // with a static color for the current scheme; custom drawing uses the
            // adaptive accent, and menu buttons use `AuralMenuButtonStyle`.
            .preferredColorScheme(theme.colorScheme).tint(AuralStyle.staticAccent(for: scheme, increasedContrast: contrast == .increased))
    }
}

private struct AuralWorkspaceSurface: ViewModifier {
    let padding: CGFloat
    @Environment(\.auralInterfaceScale) private var scale
    func body(content: Content) -> some View {
        content.padding(padding * scale)
            .background(AuralStyle.surface, in: RoundedRectangle(cornerRadius: 6 * scale))
            .overlay(RoundedRectangle(cornerRadius: 6 * scale).strokeBorder(AuralStyle.border))
    }
}

extension View {
    func auralAppearance(_ theme: AuralTheme) -> some View {
        modifier(AuralAppearance(theme: theme))
    }
    func auralWorkspaceSurface(padding: CGFloat = 12) -> some View { modifier(AuralWorkspaceSurface(padding: padding)) }
    func auralPanel(padding: CGFloat = 18) -> some View {
        self.auralPadding(padding)
            .background(AuralStyle.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AuralStyle.border))
    }
}

struct AuralSectionLabel: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    let title: String
    var systemImage: String? = nil
    var body: some View {
        HStack(spacing: 7 * interfaceScale) {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(title)
        }.auralFont(size: 11, weight: .medium).foregroundStyle(AuralStyle.secondary)
    }
}

struct AuralNotice: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    let message: String
    var isError = false
    var body: some View {
        HStack(alignment: .top, spacing: 9 * interfaceScale) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(isError ? AuralStyle.warning : AuralStyle.accent)
                .accessibilityHidden(true)
            Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .auralFrame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(isError ? "Error: \(message)" : message)
        }.auralFont(size: 12).auralPadding(12)
            .background((isError ? AuralStyle.warning : AuralStyle.accent).opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct AuralButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.self) private var environment
    @Environment(\.auralInterfaceScale) private var scale
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .auralFont(size: 12, weight: .medium)
            .padding(.horizontal, 10 * scale).padding(.vertical, 7 * scale)
            .foregroundStyle(prominent ? AuralStyle.accentForeground(in: environment) : Color.primary)
            .background(prominent ? AuralStyle.accent : AuralStyle.elevated, in: RoundedRectangle(cornerRadius: 5))
            // Scoped animations keep press and focus feedback from retiming the label.
            .animation(AuralMotion.quick) { content in
                content.overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isFocused ? Color.primary : (prominent ? .clear : AuralStyle.controlBorder), lineWidth: isFocused ? 2 : 1))
            }
            .animation(AuralMotion.instant) { content in
                content.opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
            }
    }
}

/// Menu buttons drawn in SwiftUI. A native pop-up button paints its indicator with the
/// system accent whenever AppKit redraws it on its own, such as when the window becomes
/// key, so it can't hold the fixed accent. These stay neutral, like `AuralButtonStyle`.
struct AuralMenuButtonStyle: ButtonStyle {
    /// Small buttons match the 27-point numeric fields in filter rows.
    enum Size { case small, regular, large }
    var size = Size.regular
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.auralInterfaceScale) private var scale
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6 * scale) {
            configuration.label.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.down").auralFont(size: size == .large ? 11 : 9, weight: .semibold)
                .foregroundStyle(AuralStyle.secondary).accessibilityHidden(true)
        }
        .auralFont(size: size == .small ? 11 : (size == .large ? 14 : 12), weight: size == .regular ? .medium : .regular)
        .foregroundStyle(Color.primary)
        .padding(.horizontal, (size == .small ? 8 : 10) * scale).padding(.vertical, (size == .large ? 9 : 7) * scale)
        .auralFrame(minHeight: size == .small ? 27 : nil)
        .background(AuralStyle.elevated, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .animation(AuralMotion.quick) { content in
            content.overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isFocused ? Color.primary : AuralStyle.controlBorder, lineWidth: isFocused ? 2 : 1))
        }
        .animation(AuralMotion.instant) { content in
            content.opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
        }
    }
}

/// A pop-up picker on an `AuralMenuButtonStyle` button. Its menu checks the selection.
struct AuralPicker<Selection: Hashable, Content: View>: View {
    let title: String
    let value: String
    @Binding var selection: Selection
    var size = AuralMenuButtonStyle.Size.regular
    @ViewBuilder let content: () -> Content
    var body: some View {
        Menu {
            Picker(title, selection: $selection, content: content).pickerStyle(.inline).labelsHidden()
        } label: { Text(value) }
        .auralMenuButton(size)
        .accessibilityLabel(title).accessibilityValue(value)
    }
}

extension View {
    /// Draws a `Menu` as an `AuralMenuButtonStyle` button.
    func auralMenuButton(_ size: AuralMenuButtonStyle.Size = .regular) -> some View {
        menuStyle(.button).buttonStyle(AuralMenuButtonStyle(size: size))
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
            .auralFont(size: 12, design: .monospaced).monospacedDigit()
            .auralPadding(.horizontal, 7).auralFrame(height: 27)
            .background(AuralStyle.background, in: RoundedRectangle(cornerRadius: 4))
            .animation(AuralMotion.quick) { content in
                content.overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(invalid ? AuralStyle.warning : (focused ? Color.primary : AuralStyle.controlBorder), lineWidth: focused ? 2 : 1))
            }
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
            .help(invalid ? "Invalid \(label). Enter a number from \(range.lowerBound) to \(range.upperBound). Escape cancels." : "\(label). Press Return to apply. Escape cancels.")
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
            AccessibilityNotification.Announcement("Invalid \(label). Enter a number from \(range.lowerBound) to \(range.upperBound). Press Escape to cancel.").post()
            return .rejected
        case .value(let number):
            draft.accept()
            commit(number)
            invalid = false
            return .submitted
        }
    }
}
