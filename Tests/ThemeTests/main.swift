import AppKit
import SwiftUI
import Combine

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

func resolved(_ color: Color, scheme: ColorScheme) -> Color.Resolved {
    var environment = EnvironmentValues()
    environment.colorScheme = scheme
    return color.resolve(in: environment)
}

func luminance(_ color: Color.Resolved) -> Double {
    func linear(_ component: Float) -> Double {
        let value = Double(component)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
}

func contrast(_ foreground: Color, _ background: Color, scheme: ColorScheme) -> Double {
    let ink = resolved(foreground, scheme: scheme)
    let surface = resolved(background, scheme: scheme)
    let first = luminance(Color.Resolved(red: ink.red * ink.opacity + surface.red * (1 - ink.opacity),
                                        green: ink.green * ink.opacity + surface.green * (1 - ink.opacity),
                                        blue: ink.blue * ink.opacity + surface.blue * (1 - ink.opacity)))
    let second = luminance(surface)
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
}

@main struct ThemeTests {
    @MainActor static func main() async throws {
        if Bundle.main.bundleIdentifier == "local.aural.performance-preview" { PerformancePreview.main(); return }
        if CommandLine.arguments.contains("--benchmark-rack") { try runRackBenchmark(); return }
        if CommandLine.arguments.contains("--benchmark-ui") { try runUIBenchmark(); return }
        if CommandLine.arguments.contains("--check-accessibility") { _ = NSApplication.shared; checkAccessibility(); return }
        if CommandLine.arguments.contains("--check-autoeq-live") { try await checkAutoEQLive(); return }
        try checkThemes()
        try await checkAutoEQCatalog()
    }

    @MainActor private static func checkThemes() throws {
        let legacy = try JSONDecoder().decode(Settings.self, from: Data(#"{"devices":{},"presets":{},"selectedUID":"headphones"}"#.utf8))
        require(Settings().theme == .dark && legacy.theme == .dark, "New and existing installs must preserve the original dark appearance")
        require(Settings().interfaceStyle == .standard && legacy.interfaceStyle == .standard,
                "Liquid Glass must be opt-in for both new and existing installations")
        for theme in AuralTheme.allCases {
            var settings = legacy
            settings.devices["headphones"] = Profile(gains: [1,2,3,4,5,6,7,8,9,10], preamp: -12.3456789)
            settings.startEQAutomatically = false
            settings.theme = theme
            let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
            require(restored.theme == theme, "Theme must survive restarting the app")
            require(restored.devices == settings.devices && restored.selectedUID == settings.selectedUID && restored.startEQAutomatically == false,
                    "Saving a theme must preserve exact EQ and startup preferences")
        }
        for invalid in [#""unknown""#, "12", "{}"] {
            let data = Data("{\"devices\":{},\"presets\":{},\"selectedUID\":\"\",\"theme\":\(invalid)}".utf8)
            do {
                _ = try JSONDecoder().decode(Settings.self, from: data)
                fatalError("Invalid themes must report a decoding error")
            } catch is DecodingError { }
        }
        for style in AuralInterfaceStyle.allCases {
            for theme in AuralTheme.allCases {
                var settings = legacy
                settings.theme = theme
                settings.interfaceStyle = style
                settings.devices["headphones"] = Profile(gains: [1,2,3,4,5,6,7,8,9,10], preamp: -12.3456789)
                settings.startEQAutomatically = false
                let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
                require(restored.interfaceStyle == style && restored.theme == theme && restored.devices == settings.devices
                        && restored.selectedUID == settings.selectedUID && restored.startEQAutomatically == false,
                        "Material and color scheme must persist independently without changing saved audio settings")
            }
        }
        for invalid in [#""unknown""#, "12", "{}"] {
            let data = Data("{\"devices\":{},\"presets\":{},\"selectedUID\":\"\",\"interfaceStyle\":\(invalid)}".utf8)
            do {
                _ = try JSONDecoder().decode(Settings.self, from: data)
                fatalError("Invalid appearance styles must report a decoding error")
            } catch is DecodingError { }
        }
        require(AuralInterfaceStyle.liquidGlass.usesLiquidGlass(supported: true, reduceTransparency: false, increasedContrast: false),
                "Liquid Glass must be available on a supported system when explicitly selected")
        for style in AuralInterfaceStyle.allCases {
            require(!style.usesLiquidGlass(supported: false, reduceTransparency: false, increasedContrast: false), "Older macOS must use solid surfaces")
            require(!style.usesLiquidGlass(supported: true, reduceTransparency: true, increasedContrast: false), "Reduce Transparency must use solid surfaces")
            require(!style.usesLiquidGlass(supported: true, reduceTransparency: false, increasedContrast: true), "Increase Contrast must use solid surfaces")
        }
        require(!AuralInterfaceStyle.standard.usesLiquidGlass(supported: true, reduceTransparency: false, increasedContrast: false),
                "Standard must retain solid surfaces on macOS 26")

        for scheme in [ColorScheme.light, .dark] {
            for background in [AuralStyle.background, AuralStyle.surface, AuralStyle.elevated] {
                require(contrast(AuralStyle.controlBorder, background, scheme: scheme) >= 3, "Interactive control outlines must be visible after alpha compositing")
                for foreground in [AuralStyle.secondary, AuralStyle.warning] {
                    require(contrast(foreground, background, scheme: scheme) >= 4.5, "Theme text must maintain readable contrast on every surface")
                }
            }
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            require(resolved(AuralStyle.accent, scheme: scheme) == resolved(Color(nsColor: .controlAccentColor), scheme: scheme),
                    "Accent must match the user's macOS accent in each appearance")
            require(contrast(AuralStyle.accentForeground(in: environment), AuralStyle.accent, scheme: scheme) >= 4.5,
                    "Prominent button labels must remain readable with the system accent")
            for trace in AuralStyle.plotColors.dropFirst() {
                require(contrast(trace, AuralStyle.surface, scheme: scheme) >= 3, "Each filter/channel trace must remain visible")
            }
        }
        require(luminance(resolved(AuralStyle.background, scheme: .light)) > 0.8, "Light theme must actually resolve to a light surface")
        require(luminance(resolved(AuralStyle.background, scheme: .dark)) < 0.02, "Dark theme must retain its dark surface")
        require(abs(resolved(AuralStyle.grid, scheme: .light).red) < 0.001 && abs(resolved(AuralStyle.grid, scheme: .dark).red - 1) < 0.001,
                "Graph grids must change ink with the appearance")
        require(AuralTheme.system.colorScheme == nil && AuralTheme.system.appearance == nil, "System must release both SwiftUI and AppKit overrides")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-theme-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try! FileManager.default.removeItem(at: directory) }
        let settingsFile = directory.appendingPathComponent("settings.json")
        let model = Model(settingsFile: settingsFile)
        let originalProfile = model.profile
        let originalRevision = model.editRevision
        let originalOutput = model.selectedUID
        let originalComparison = model.comparisonSlot
        var publishedThemes: [AuralTheme] = []
        let subscription = model.$theme.dropFirst().sink { theme in
            let saved = try! JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsFile))
            require(saved.theme == theme, "A theme must be saved before it is published")
            publishedThemes.append(theme)
        }
        for theme in [AuralTheme.light, .system, .dark] {
            model.setTheme(theme)
            require(model.theme == theme && model.error == nil, "The model must apply a successfully saved theme")
            require(model.profile == originalProfile && model.editRevision == originalRevision && model.selectedUID == originalOutput && model.comparisonSlot == originalComparison,
                    "Theme changes must leave EQ, edits, output, and comparison unchanged")
            require(!model.running && !model.route.hasResources, "Theme changes must never start audio")
        }
        model.setTheme(.dark)
        require(publishedThemes == [.light, .system, .dark], "Selecting the current theme must not publish another change")
        let restarted = Model(settingsFile: settingsFile)
        require(restarted.theme == .dark, "The model must restore the saved theme on launch")
        subscription.cancel()

        var publishedStyles: [AuralInterfaceStyle] = []
        let styles = model.$interfaceStyle.dropFirst().sink { style in
            let saved = try! JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsFile))
            require(saved.interfaceStyle == style, "An appearance style must be saved before it is published")
            publishedStyles.append(style)
        }
        if AuralInterfaceStyle.liquidGlassSupported {
            model.bypass = true
            for style in [AuralInterfaceStyle.liquidGlass, .standard, .liquidGlass] {
                model.setInterfaceStyle(style)
                require(model.interfaceStyle == style && model.theme == .dark && model.error == nil, "Style must change independently of theme")
                require(model.profile == originalProfile && model.editRevision == originalRevision && model.selectedUID == originalOutput
                        && model.comparisonSlot == originalComparison && model.bypass && !model.running && !model.route.hasResources,
                        "Appearance style changes must preserve EQ, edits, output, comparison, bypass, and playback")
            }
            model.setInterfaceStyle(.liquidGlass)
            require(publishedStyles == [.liquidGlass, .standard, .liquidGlass], "Re-selecting a style must not publish another change")
            require(Model(settingsFile: settingsFile).interfaceStyle == .liquidGlass, "Liquid Glass must survive relaunch")
        } else {
            model.setInterfaceStyle(.liquidGlass)
            require(model.interfaceStyle == .standard && model.error == "Liquid Glass requires macOS 26 or later." && publishedStyles.isEmpty,
                    "Unsupported style selections must report the required macOS version without changing settings")
        }
        styles.cancel()

        let blockedParent = directory.appendingPathComponent("file-as-directory")
        try Data("fixture".utf8).write(to: blockedParent)
        let blocked = Model(settingsFile: blockedParent.appendingPathComponent("settings.json"))
        blocked.setTheme(.light)
        require(blocked.theme == .dark && blocked.error?.contains("Could not save theme:") == true,
                "A failed save must keep the accepted theme and report the failure")
        require(!blocked.running && !blocked.route.hasResources, "A failed theme save must leave audio stopped")
        if AuralInterfaceStyle.liquidGlassSupported {
            blocked.setInterfaceStyle(.liquidGlass)
            require(blocked.interfaceStyle == .standard && blocked.error?.contains("Could not save appearance style:") == true,
                    "A failed style save must retain the previous style and report the failure")
            require(!blocked.running && !blocked.route.hasResources, "A failed style save must not start audio")
        }

        let application = NSApplication.shared
        let originalAppearance = application.appearance
        defer { application.appearance = originalAppearance }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        for theme in [AuralTheme.light, .dark, .system, .light, .system] {
            application.appearance = theme.appearance
            let expected = theme == .system ? application.effectiveAppearance : theme.appearance!
            for presentation in [window, panel] {
                let deadline = Date().addingTimeInterval(1)
                while presentation.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != expected.bestMatch(from: [.aqua, .darkAqua]) && Date() < deadline {
                    RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
                }
                require(presentation.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected.bestMatch(from: [.aqua, .darkAqua]),
                        "Native \(type(of: presentation)) must follow \(theme): got \(presentation.effectiveAppearance.name), expected \(expected.name)")
            }
        }
        checkPanelHosting()
        checkGlassPresentationPolicy()
        try checkResizablePanes()
        try runRackBenchmark()
        try checkEQBars()
        try checkCurveEditing()
        checkAccessibility()
        try checkPerformanceIsolation()
        try checkAnalysisWorker()
        print("PASS theme migration, persistence, save failure, audio neutrality, system accent, palette contrast, graph ink, and native appearance switching")
    }
}
