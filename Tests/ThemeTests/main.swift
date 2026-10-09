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
        if ["local.aural.performance-preview", "local.aural.performance-preview.zoom-minimum", "local.aural.performance-preview.accent", "local.aural.performance-preview.peak-protection"].contains(Bundle.main.bundleIdentifier) { PerformancePreview.main(); return }
        if CommandLine.arguments.contains("--benchmark-rack") { try runRackBenchmark(); return }
        if CommandLine.arguments.contains("--benchmark-ui") { try runUIBenchmark(); return }
        if CommandLine.arguments.contains("--check-history-shortcuts") { _ = NSApplication.shared; try checkHistoryShortcuts(); return }
        if CommandLine.arguments.contains("--check-interface-zoom") { _ = NSApplication.shared; try checkInterfaceZoom(); return }
        if CommandLine.arguments.contains("--check-meter-zoom") { _ = NSApplication.shared; checkMeterZoom(); return }
        if CommandLine.arguments.contains("--check-accessibility") { _ = NSApplication.shared; checkAccessibility(); return }
        if CommandLine.arguments.contains("--check-autoeq-live") { try await checkAutoEQLive(); return }
        try checkThemes()
        checkRouteCleanup()
        try await checkAutoEQCatalog()
    }

    /// A failed step must not end cleanup early: a callback that cannot be stopped
    /// on a vanished device must not keep the tap muting system audio.
    @MainActor private static func checkRouteCleanup() {
        let route = AudioRoute()
        route.adoptForTesting(tap: 0x7fff_fff1, aggregate: 0x7fff_fff2,
                              device: OutputDevice(id: 0x7fff_fff0, uid: "missing", name: "Missing"))
        do {
            try route.stop()
            require(false, "Stopping audio on a missing device must fail")
        } catch {
            require((error as? CoreAudioFailure)?.action == "Stop audio", "Cleanup must report its first failure")
        }
        require(route.device == nil && !route.hasResources && route.readMeter().peak == 0,
                "A failed audio stop must still release the engine, private route, and tap")
        do { try route.stop() } catch { require(false, "Stopping a released route must succeed") }
    }

    @MainActor private static func checkThemes() throws {
        let legacy = try JSONDecoder().decode(Settings.self, from: Data(#"{"devices":{},"presets":{},"selectedUID":"headphones"}"#.utf8))
        require(Settings().theme == .dark && legacy.theme == .dark, "New and existing installs must preserve the original dark appearance")
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
        for style in ["standard", "liquidGlass"] {
            for theme in AuralTheme.allCases {
                var settings = legacy
                settings.theme = theme
                settings.devices["headphones"] = Profile(gains: [1,2,3,4,5,6,7,8,9,10], preamp: -12.3456789)
                settings.presets["Listening"] = settings.devices["headphones"]
                settings.selectedPresets = ["headphones": "Listening"]
                settings.startEQAutomatically = false
                guard var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any] else {
                    fatalError("Settings must encode as a JSON object")
                }
                json["interfaceStyle"] = style
                let restored = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: json))
                require(restored.theme == theme && restored.devices == settings.devices && restored.presets == settings.presets
                        && restored.selectedPresets == settings.selectedPresets && restored.selectedUID == settings.selectedUID
                        && restored.startEQAutomatically == false, "Retiring either style preference must preserve all listening settings")
                guard let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any] else {
                    fatalError("Migrated settings must encode as a JSON object")
                }
                require(saved["interfaceStyle"] == nil, "The retired style toggle must not be saved again")
            }
        }
        for invalid in [#""unknown""#, "12", "{}"] {
            let data = Data("{\"devices\":{},\"presets\":{},\"selectedUID\":\"\",\"interfaceStyle\":\(invalid)}".utf8)
            do {
                _ = try JSONDecoder().decode(Settings.self, from: data)
                fatalError("Invalid appearance styles must report a decoding error")
            } catch is DecodingError { }
        }

        for scheme in [ColorScheme.light, .dark] {
            for background in [AuralStyle.background, AuralStyle.surface, AuralStyle.elevated] {
                require(contrast(AuralStyle.controlBorder, background, scheme: scheme) >= 3, "Interactive control outlines must be visible after alpha compositing")
                for foreground in [AuralStyle.secondary, AuralStyle.warning] {
                    require(contrast(foreground, background, scheme: scheme) >= 4.5, "Theme text must maintain readable contrast on every surface")
                }
            }
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let accent = resolved(AuralStyle.accent, scheme: scheme), tint = resolved(AuralStyle.staticAccent(for: scheme), scheme: scheme)
            require(abs(accent.red - tint.red) < 0.002 && abs(accent.green - tint.green) < 0.002 && abs(accent.blue - tint.blue) < 0.002,
                    "Native control tint must match the fixed instrument accent in each appearance")
            require(accent.blue > accent.red && accent.green > accent.red, "The instrument accent must stay cyan, distinct from the amber warning")
            require(contrast(AuralStyle.accent, AuralStyle.surface, scheme: scheme) >= 3, "The accent curve and meter must stand out from their surface")
            require(contrast(AuralStyle.accentForeground(in: environment), AuralStyle.accent, scheme: scheme) >= 4.5,
                    "Prominent button labels must remain readable on the accent")
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

        let blockedParent = directory.appendingPathComponent("file-as-directory")
        try Data("fixture".utf8).write(to: blockedParent)
        let blocked = Model(settingsFile: blockedParent.appendingPathComponent("settings.json"))
        blocked.setTheme(.light)
        require(blocked.theme == .dark && blocked.error?.contains("Could not save theme:") == true,
                "A failed save must keep the accepted theme and report the failure")
        require(!blocked.running && !blocked.route.hasResources, "A failed theme save must leave audio stopped")

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
        try checkResizablePanes()
        try runRackBenchmark()
        try checkEQBars()
        try checkCurveEditing()
        checkAccessibility()
        try checkAudioFormatsAndSettings()
        try checkPeakProtectionSettings()
        try checkOutputFollowingAndLevelMatching()
        try checkBandSolo()
        try checkHistoryShortcuts()
        try checkInterfaceZoom()
        checkMeterZoom()
        try checkFilterPanelPosition()
        try checkPerformanceIsolation()
        try checkAnalysisWorker()
        print("PASS theme migration, persistence, save failure, audio neutrality, fixed instrument accent, palette contrast, graph ink, and native appearance switching")
    }
}
