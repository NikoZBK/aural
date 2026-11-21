import SwiftUI

/// Keep expensive native controls intact when their visible inputs are unchanged.
/// Actions still read the live model; environment changes flow into retained content.
struct AuralEquatableContent<Key: Equatable, Content: View>: View, Equatable {
    let key: Key
    let content: () -> Content
    init(key: Key, @ViewBuilder content: @escaping () -> Content) { self.key = key; self.content = content }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    var body: some View { content() }
}

extension AuralTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .sand: return .light
        case .dark, .slate: return .dark
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light, .sand: return NSAppearance(named: .aqua)
        case .dark, .slate: return NSAppearance(named: .darkAqua)
        }
    }
    var palette: AuralPalette {
        switch self {
        case .system, .light, .dark: return AuralStyle.standardPalette
        case .sand: return AuralStyle.sandPalette
        case .slate: return AuralStyle.slatePalette
        }
    }
}

struct AuralPalette: Equatable {
    let background: Color
    let metalTop: Color
    let metalBottom: Color
    let surface: Color
    let elevated: Color
    let field: Color
    let plotBackground: Color
}

private struct AuralPaletteKey: EnvironmentKey {
    static let defaultValue = AuralStyle.standardPalette
}

extension EnvironmentValues {
    var auralPalette: AuralPalette {
        get { self[AuralPaletteKey.self] }
        set { self[AuralPaletteKey.self] = newValue }
    }
}

enum AuralStyle {
    static let controlHeight: CGFloat = 27
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
    /// The capsule outline shared by gel buttons.
    static let pill = RoundedRectangle(cornerRadius: 1000)
    // A fixed Aqua blue, identical on every Mac, instead of the system accent.
    // It marks active state and data: the curve, selection, Start EQ, and the meter.
    private static let accentLight = (red: 0.11, green: 0.40, blue: 0.84)
    private static let accentDark = (red: 0.42, green: 0.70, blue: 1.0)
    private static let accentHighContrastLight = (red: 0.05, green: 0.30, blue: 0.72)
    private static let accentHighContrastDark = (red: 0.60, green: 0.80, blue: 1.0)
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
    static let standardPalette = AuralPalette(
        background: adaptive(light: NSColor(srgbRed: 0.74, green: 0.74, blue: 0.75, alpha: 1),
                             dark: NSColor(srgbRed: 0.21, green: 0.21, blue: 0.22, alpha: 1)),
        metalTop: adaptive(light: NSColor(srgbRed: 0.86, green: 0.86, blue: 0.87, alpha: 1),
                           dark: NSColor(srgbRed: 0.31, green: 0.31, blue: 0.32, alpha: 1)),
        metalBottom: adaptive(light: NSColor(srgbRed: 0.62, green: 0.62, blue: 0.64, alpha: 1),
                              dark: NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)),
        surface: adaptive(light: NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1),
                          dark: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1)),
        elevated: adaptive(light: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.97, alpha: 1),
                           dark: NSColor(srgbRed: 0.27, green: 0.27, blue: 0.28, alpha: 1)),
        field: adaptive(light: .white, dark: NSColor(srgbRed: 0.21, green: 0.21, blue: 0.22, alpha: 1)),
        plotBackground: adaptive(light: .white.withAlphaComponent(0.60), dark: .black.withAlphaComponent(0.16))
    )
    static let sandPalette = AuralPalette(
        background: Color(.sRGB, red: 0.81, green: 0.76, blue: 0.67),
        metalTop: Color(.sRGB, red: 0.89, green: 0.83, blue: 0.74),
        metalBottom: Color(.sRGB, red: 0.70, green: 0.62, blue: 0.52),
        surface: Color(.sRGB, red: 0.95, green: 0.91, blue: 0.84),
        elevated: Color(.sRGB, red: 0.98, green: 0.95, blue: 0.89),
        field: Color(.sRGB, red: 1.00, green: 0.99, blue: 0.96),
        plotBackground: Color(.sRGB, red: 0.98, green: 0.95, blue: 0.90)
    )
    static let slatePalette = AuralPalette(
        background: Color(.sRGB, red: 0.16, green: 0.21, blue: 0.26),
        metalTop: Color(.sRGB, red: 0.23, green: 0.30, blue: 0.35),
        metalBottom: Color(.sRGB, red: 0.08, green: 0.12, blue: 0.17),
        surface: Color(.sRGB, red: 0.15, green: 0.20, blue: 0.25),
        elevated: Color(.sRGB, red: 0.21, green: 0.28, blue: 0.34),
        field: Color(.sRGB, red: 0.11, green: 0.16, blue: 0.21),
        plotBackground: Color(.sRGB, red: 0.12, green: 0.17, blue: 0.22)
    )
    /// The lit lower edge of an inset well or an etched label.
    static let etch = adaptive(light: .white.withAlphaComponent(0.75), dark: .white.withAlphaComponent(0.10))
    static let violet = adaptive(light: NSColor(srgbRed: 0.42, green: 0.29, blue: 0.73, alpha: 1),
                                  dark: NSColor(srgbRed: 0.72, green: 0.66, blue: 1, alpha: 1))
    static let border = adaptive(light: .black.withAlphaComponent(0.14), dark: .white.withAlphaComponent(0.085),
                                 highContrastLight: .black.withAlphaComponent(0.6), highContrastDark: .white.withAlphaComponent(0.6))
    static let controlBorder = adaptive(light: .black.withAlphaComponent(0.5), dark: .white.withAlphaComponent(0.5),
                                        highContrastLight: .black, highContrastDark: .white)
    static let secondary = adaptive(light: NSColor(srgbRed: 0.22, green: 0.24, blue: 0.27, alpha: 1),
                                    dark: NSColor(srgbRed: 0.76, green: 0.79, blue: 0.83, alpha: 1))
    static let warning = adaptive(light: NSColor(srgbRed: 0.45, green: 0.20, blue: 0.0, alpha: 1),
                                  dark: NSColor(srgbRed: 1, green: 0.73, blue: 0.40, alpha: 1))
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
        content.background { AuralBackdrop() }
            .environment(\.colorScheme, scheme)
            .environment(\.auralPalette, theme.palette)
            // Native controls can resolve a bridged dynamic NSColor as red in the
            // older SDK compatibility path. Tint checkboxes and segmented controls
            // with a static color for the current scheme; custom drawing uses the
            // adaptive accent, and menu buttons use `AuralMenuButtonStyle`.
            .preferredColorScheme(theme.colorScheme).tint(AuralStyle.staticAccent(for: scheme, increasedContrast: contrast == .increased))
    }
}

/// A static sheet of brushed metal. It never animates with audio levels.
private struct AuralBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.auralPalette) private var palette
    var body: some View {
        ZStack {
            palette.background
            if contrast != .increased {
                LinearGradient(colors: [palette.metalTop, palette.metalBottom], startPoint: .top, endPoint: .bottom)
                // Fine horizontal grain. Drawn once per size; nothing here follows audio.
                Canvas { context, size in
                    var light = Path(), dark = Path()
                    var y: CGFloat = 0.5, row = 0
                    while y < size.height {
                        let line = CGRect(x: 0, y: y, width: size.width, height: 1)
                        if row % 3 == 0 { light.addRect(line) } else if row % 3 == 1 { dark.addRect(line) }
                        y += 1; row += 1
                    }
                    context.fill(light, with: .color(.white.opacity(scheme == .dark ? 0.025 : 0.10)))
                    context.fill(dark, with: .color(.black.opacity(scheme == .dark ? 0.06 : 0.025)))
                }
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Content stays outside appearance branches so drafts and focus survive a theme change.
private struct AuralSurfaceBackground: View {
    var emphasized = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.auralInterfaceScale) private var scale
    @Environment(\.auralPalette) private var palette
    private var decoration: Bool { contrast != .increased && !reduceTransparency }
    var body: some View {
        // An inset well in the metal: shaded along its top edge, lit along its bottom.
        let shape = RoundedRectangle(cornerRadius: 6 * scale)
        shape.fill(palette.surface)
            .overlay {
                if decoration {
                    shape.fill(LinearGradient(colors: [.black.opacity(scheme == .dark ? 0.28 : 0.09), .clear],
                                              startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.06)))
                }
            }
            .overlay {
                shape.strokeBorder(decoration ? AnyShapeStyle(LinearGradient(colors: [.black.opacity(scheme == .dark ? 0.75 : 0.45),
                                                                                      .black.opacity(scheme == .dark ? 0.5 : 0.22)],
                                                                             startPoint: .top, endPoint: .bottom))
                                              : AnyShapeStyle(AuralStyle.border))
            }
            .shadow(color: decoration ? AuralStyle.etch : .clear, radius: 0, y: 1)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The same inset well as every panel, with opaque accessibility fallbacks.
struct AuralChromeBackground: View {
    var body: some View {
        AuralSurfaceBackground()
    }
}

private struct AuralWorkspaceSurface: ViewModifier {
    let padding: CGFloat
    let emphasized: Bool
    @Environment(\.auralInterfaceScale) private var scale
    func body(content: Content) -> some View {
        content.padding(padding * scale).background { AuralSurfaceBackground(emphasized: emphasized) }
    }
}

extension View {
    func auralAppearance(_ theme: AuralTheme) -> some View {
        modifier(AuralAppearance(theme: theme))
    }
    func auralWorkspaceSurface(padding: CGFloat = 12, emphasized: Bool = false) -> some View {
        modifier(AuralWorkspaceSurface(padding: padding, emphasized: emphasized))
    }
    func auralPanel(padding: CGFloat = 18) -> some View {
        auralWorkspaceSurface(padding: padding)
    }
}

struct AuralSymbolBadge: View {
    let systemImage: String
    var size: CGFloat = 48
    @Environment(\.auralInterfaceScale) private var scale
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.auralPalette) private var palette
    var body: some View {
        Image(systemName: systemImage)
            .auralFont(size: size * 0.44, weight: .semibold)
            .foregroundStyle(AuralStyle.violet)
            .auralFrame(width: size, height: size)
            .background {
                // An opaque base keeps violet legible over native list selection colors.
                RoundedRectangle(cornerRadius: size * 0.3 * scale, style: .continuous)
                    .fill(palette.elevated)
                    .overlay {
                        if contrast != .increased && !reduceTransparency {
                            RoundedRectangle(cornerRadius: size * 0.3 * scale, style: .continuous)
                                .fill(AuralStyle.violet.opacity(0.08))
                        }
                    }
            }
            .accessibilityHidden(true)
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
        }.auralFont(size: 11, weight: .semibold).foregroundStyle(AuralStyle.secondary)
            .shadow(color: AuralStyle.etch, radius: 0, y: 1)
    }
}

/// The glossy gel of a mid-2000s Mac button: a lit upper half over a tinted body.
struct AuralGel: View {
    var prominent = false
    var pressed = false
    var radius: CGFloat? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.auralPalette) private var palette
    var body: some View {
        // A capsule unless a corner radius is given.
        let shape = radius.map { AnyShape(RoundedRectangle(cornerRadius: $0)) } ?? AnyShape(AuralStyle.pill)
        return Group {
            shape.fill(prominent ? AuralStyle.accent : palette.elevated)
                .overlay {
                    if contrast != .increased {
                        shape.fill(LinearGradient(stops: [.init(color: .white.opacity(prominent ? 0.55 : (scheme == .dark ? 0.22 : 0.9)), location: 0),
                                                          .init(color: .white.opacity(prominent ? 0.16 : (scheme == .dark ? 0.06 : 0.3)), location: 0.48),
                                                          .init(color: .black.opacity(scheme == .dark ? 0.16 : 0.06), location: 0.5),
                                                          .init(color: .white.opacity(prominent ? 0.22 : 0.04), location: 1)],
                                                  startPoint: .top, endPoint: .bottom))
                    }
                }
                .overlay { if pressed { shape.fill(.black.opacity(0.22)) } }
        }
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
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.self) private var environment
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .auralFont(size: 12)
            .auralPadding(.horizontal, compact ? 7 : 12).auralPadding(.vertical, 4)
            .auralFrame(minHeight: AuralStyle.controlHeight)
            .foregroundStyle(prominent ? AuralStyle.accentForeground(in: environment) : Color.primary)
            // The border is a filled pill behind an inset gel: stroking a pill leaves stray end marks.
            .background {
                AuralGel(prominent: prominent, pressed: configuration.isPressed).padding(isFocused ? 2 : 1)
                    .background(AuralStyle.pill.fill(isFocused ? Color.primary : AuralStyle.controlBorder))
            }
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A push-on, push-off gel button that lights blue while on.
struct AuralGelToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.self) private var environment
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label.auralFont(size: 11)
                .auralPadding(.horizontal, 10).auralPadding(.vertical, 4)
                .auralFrame(minHeight: AuralStyle.controlHeight)
                .foregroundStyle(configuration.isOn ? AuralStyle.accentForeground(in: environment) : Color.primary)
                .background {
                    AuralGel(prominent: configuration.isOn).padding(isFocused ? 2 : 1)
                        .background(AuralStyle.pill.fill(isFocused ? Color.primary : AuralStyle.controlBorder))
                }
                .contentShape(AuralStyle.pill)
        }.buttonStyle(.plain).opacity(isEnabled ? 1 : 0.4)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// A gel checkbox: a lit square that turns blue and takes a tick when on.
struct AuralCheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.self) private var environment
    @Environment(\.auralInterfaceScale) private var scale
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6 * scale) {
                AuralGel(prominent: configuration.isOn, radius: 3 * scale)
                    .overlay(RoundedRectangle(cornerRadius: 3 * scale).strokeBorder(isFocused ? Color.primary : AuralStyle.controlBorder, lineWidth: isFocused ? 2 : 1))
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark").font(.system(size: 9 * scale, weight: .heavy))
                                .foregroundStyle(AuralStyle.accentForeground(in: environment))
                        }
                    }
                    .frame(width: 14 * scale, height: 14 * scale)
                configuration.label
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).opacity(isEnabled ? 1 : 0.4)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// A segmented control drawn as one gel strip; the chosen segment is blue. It stays a
/// native `NSSegmentedControl` for keyboard, accessibility, and tracking, and only paints itself.
struct AuralSegmented<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var small = false
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> AuralGelSegmentedControl {
        let control = AuralGelSegmentedControl(labels: options.map(\.label), trackingMode: .selectOne,
                                               target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel(title)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }
    func updateNSView(_ control: AuralGelSegmentedControl, context: Context) {
        context.coordinator.parent = self
        if control.segmentCount != options.count { control.segmentCount = options.count }
        for (index, option) in options.enumerated() where control.label(forSegment: index) != option.label {
            control.setLabel(option.label, forSegment: index)
        }
        let scale = context.environment.auralInterfaceScale
        let size = (small ? 11 : 12) * scale
        control.font = NSFont(name: "LucidaGrande", size: size) ?? .systemFont(ofSize: size)
        control.chosenText = NSColor(AuralStyle.accentForeground(in: context.environment))
        control.unchosenFill = NSColor(context.environment.auralPalette.elevated)
        control.radius = 5 * scale
        control.isEnabled = context.environment.isEnabled
        control.selectedSegment = options.firstIndex { $0.value == selection } ?? -1
        control.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: AuralGelSegmentedControl, context: Context) -> CGSize? {
        let scale = context.environment.auralInterfaceScale
        let font = control.font ?? .systemFont(ofSize: 12)
        let widest = options.map { ($0.label as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let ideal = (ceil(widest) + (small ? 16 : 24) * scale) * CGFloat(options.count)
        return CGSize(width: proposal.width ?? ideal, height: (small ? 22 : AuralStyle.controlHeight) * scale)
    }
    final class Coordinator: NSObject {
        var parent: AuralSegmented
        init(_ parent: AuralSegmented) { self.parent = parent }
        @objc func changed(_ control: NSSegmentedControl) {
            let index = control.selectedSegment
            if parent.options.indices.contains(index) { parent.selection = parent.options[index].value }
            // A refused change leaves the binding as it was; show what is actually selected.
            control.selectedSegment = parent.options.firstIndex { $0.value == parent.selection } ?? -1
            control.needsDisplay = true
        }
    }
}

final class AuralGelSegmentedControl: NSSegmentedControl {
    var chosenText = NSColor.white
    var unchosenFill = NSColor(AuralStyle.standardPalette.elevated)
    var radius: CGFloat = 5
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard segmentCount > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let plain = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let outline = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        context.saveGState()
        if !isEnabled { context.setAlpha(0.4) }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        let width = bounds.width / CGFloat(segmentCount)
        for index in 0..<segmentCount {
            let chosen = index == selectedSegment
            let rect = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
            (chosen ? NSColor(AuralStyle.accent) : unchosenFill).setFill()
            rect.fill()
            if !plain {
                // The same gloss as `AuralGel`.
                let white = { (alpha: CGFloat) in NSColor.white.withAlphaComponent(alpha) }
                NSGradient(colors: [white(chosen ? 0.55 : (dark ? 0.22 : 0.9)), white(chosen ? 0.16 : (dark ? 0.06 : 0.3)),
                                    NSColor.black.withAlphaComponent(dark ? 0.16 : 0.06), white(chosen ? 0.22 : 0.04)],
                           atLocations: [0, 0.48, 0.5, 1], colorSpace: .sRGB)?.draw(in: rect, angle: 90)
            }
            if index > 0 {
                NSColor(AuralStyle.controlBorder).setFill()
                NSRect(x: rect.minX.rounded(), y: 0, width: 1, height: bounds.height).fill()
            }
            let text = NSAttributedString(string: label(forSegment: index) ?? "", attributes: [
                .font: font ?? .systemFont(ofSize: 12), .foregroundColor: chosen ? chosenText : NSColor.labelColor])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        (focused ? NSColor.labelColor : NSColor(AuralStyle.controlBorder)).setStroke()
        outline.lineWidth = focused ? 2 : 1
        outline.stroke()
        context.endTransparencyLayer()
        context.restoreGState()
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
            Image(systemName: "chevron.up.chevron.down").auralFont(size: size == .large ? 11 : 9, weight: .semibold)
                .foregroundStyle(AuralStyle.secondary).accessibilityHidden(true)
        }
        .auralFont(size: size == .small ? 11 : (size == .large ? 14 : 12), weight: size == .regular ? .medium : .regular)
        .foregroundStyle(Color.primary)
        .auralPadding(.horizontal, size == .small ? 8 : 10)
        .auralFrame(minHeight: size == .large ? 35 : AuralStyle.controlHeight)
        .background { AuralGel(pressed: configuration.isPressed, radius: 5 * scale) }
        .contentShape(RoundedRectangle(cornerRadius: 5 * scale))
        .animation(AuralMotion.quick) { content in
            content.overlay(RoundedRectangle(cornerRadius: 5 * scale).strokeBorder(isFocused ? Color.primary : AuralStyle.controlBorder, lineWidth: isFocused ? 2 : 1))
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
    @Environment(\.auralPalette) private var palette
    let value: Double
    let range: ClosedRange<Double>
    let label: String
    var decimals = 2
    var revision = 0
    let currentRevision: () -> Int
    weak var submissions: PrecisionSubmissionCoordinator? = nil
    let commit: (Double) -> Void
    // Revision bookkeeping is not display state. Keeping it separate prevents
    // every retained field from redrawing when one filter changes.
    @State private var draft = PrecisionFieldDraft()
    // Only user input is local display state. Formatting a new model value into
    // State creates another render/layout transaction for every fader event.
    @State private var text: String?
    @State private var invalid = false
    @State private var fieldID = UUID()
    @State private var focused = false

    var body: some View {
        NativePrecisionTextField(text: Binding(get: { text ?? String(format: "%.*f", decimals, value) },
                                              set: { text = $0; draft.input.edit($0); invalid = false }),
                                 focused: $focused, label: label,
                                 hint: invalid ? "Invalid number. Use \(range.lowerBound) to \(range.upperBound)." : "Press Return to apply. Escape cancels.",
                                 beginEditing: { draft.input.beginEditing(revision: currentRevision()); focused = true },
                                 submit: { submit() != .rejected }, cancel: restore)
            .auralFont(size: 12, design: .monospaced).monospacedDigit()
            .auralPadding(.horizontal, 7).auralFrame(height: AuralStyle.controlHeight)
            .background(palette.field, in: RoundedRectangle(cornerRadius: 4))
            .animation(AuralMotion.quick) { content in
                content.overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(invalid ? AuralStyle.warning : (focused ? Color.primary : AuralStyle.controlBorder), lineWidth: focused ? 2 : 1))
            }
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
    }
    private func restore() {
        draft.input.restore(value: value, decimals: decimals, revision: currentRevision())
        if text != nil { text = nil }
        if invalid { invalid = false }
    }
    private func registerSubmission() {
        if focused { submissions?.activate(fieldID, submit: submit) }
    }
    private func submit() -> PrecisionSubmissionCoordinator.Result {
        // A focus-loss callback may arrive after another control replaces the EQ.
        switch draft.input.submission(in: range, revision: currentRevision()) {
        case .stale: restore(); return .rejected
        case .unchanged: invalid = false; return .unchanged
        case .invalid:
            invalid = true
            NSSound.beep()
            AccessibilityNotification.Announcement("Invalid \(label). Enter a number from \(range.lowerBound) to \(range.upperBound). Press Escape to cancel.").post()
            return .rejected
        case .value(let number):
            draft.input.accept()
            // End native editing before the model publishes its rounded display.
            // Otherwise AppKit can echo that display text back as another edit.
            focused = false
            commit(number)
            invalid = false
            return .submitted
        }
    }
}

private final class PrecisionFieldDraft {
    var input = PrecisionInput()
}

/// AppKit distinguishes user text edits from programmatic display updates. That
/// prevents a newly formatted value from coming back through SwiftUI as typed input.
private struct NativePrecisionTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let label: String
    let hint: String
    let beginEditing: () -> Void
    let submit: () -> Bool
    let cancel: () -> Void
    @Environment(\.auralInterfaceScale) private var scale
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> NSTextField {
        let field = PrecisionNativeTextField()
        field.beganFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.beginEditing() }
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .right
        field.isEditable = true
        field.isSelectable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        let font = NSFont.monospacedSystemFont(ofSize: 12 * scale, weight: .regular)
        // AppKit invalidates text layout even for redundant font assignments.
        // A gain edit must not remeasure every retained numeric field.
        if field.font != font { field.font = font }
        if field.textColor != .labelColor { field.textColor = .labelColor }
        if field.isEnabled != enabled { field.isEnabled = enabled }
        if field.stringValue != text { field.stringValue = text }
        if field.accessibilityLabel() != label { field.setAccessibilityLabel(label) }
        if field.accessibilityHelp() != hint { field.setAccessibilityHelp(hint) }
        if !focused, field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        // These fields live in explicitly sized columns. Let AppKit determine the
        // font's height, but never let a changing number alter the column width.
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: max(0, width), height: field.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativePrecisionTextField
        init(parent: NativePrecisionTextField) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.beginEditing() }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                assertionFailure("A precision edit must come from its native text field")
                return
            }
            parent.text = field.stringValue
        }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focused = false }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if parent.submit() { control.window?.makeFirstResponder(nil) }
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.cancel()
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}

private final class PrecisionNativeTextField: NSTextField {
    var beganFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { beganFocus?() }
        return accepted
    }
}
