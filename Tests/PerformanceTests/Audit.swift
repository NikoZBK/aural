import AppKit
import Combine
import QuartzCore
import SwiftUI

private struct AuditMeasurement: Codable {
    let name: String
    let samples: Int
    let medianMS: Double
    let p95MS: Double
    let maximumMS: Double
}

/// Disposable settings, real native controls, and asynchronous curve work. These
/// are main-thread action/layout timings, not GPU frame or hardware route timings.
@MainActor func runPerformanceAudit() async throws {
    NSApplication.shared.setActivationPolicy(.accessory)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-audit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    var results: [AuditMeasurement] = []
    func report(_ name: String, _ values: [Double]) {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        let result = AuditMeasurement(name: name, samples: values.count, medianMS: sorted[sorted.count / 2],
                                      p95MS: sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], maximumMS: sorted.last!)
        results.append(result)
        print(String(format: "AUDIT %@ n=%d median=%.2fms p95=%.2fms max=%.2fms", name, values.count, result.medianMS, result.p95MS, result.maximumMS))
        fflush(stdout)
    }
    func segments(_ view: NSView) -> [NSSegmentedControl] {
        (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap(segments)
    }
    for count in [10, 31, Profile.maxFilters] {
        let model = Model(settingsFile: directory.appendingPathComponent("settings-\(count).json"), readLoginStatus: { .notRegistered })
        var profile = Profile()
        profile.filters = (0..<count).map {
            ImportedFilter(kind: .peak, frequency: 25 * pow(700, Double($0) / Double(count - 1)), gain: 0, q: 1.4, enabled: true)
        }
        require(model.replaceProfile(profile), "The audit EQ must validate")
        model.setInterfaceMode(.professional)
        let original = model.profile
        let icon = AppIconController(running: model.$running.eraseToAnyPublisher(), bypass: model.$bypass.eraseToAnyPublisher(),
                                     loadImage: { _ in NSImage(size: NSSize(width: 16, height: 16)) }, reportError: { fatalError($0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let start = CACurrentMediaTime()
        let host = NSHostingView(rootView: MainView(model: model, icon: icon))
        window.contentView = host
        func flush() { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush() }
        flush()
        report("construct.\(count)", [(CACurrentMediaTime() - start) * 1000])
        try await Task.sleep(for: .milliseconds(450))
        flush()
        func select(_ title: String) {
            guard let control = segments(host).first(where: { candidate in
                (0..<candidate.segmentCount).contains { candidate.label(forSegment: $0) == title }
            }), let index = (0..<control.segmentCount).first(where: { control.label(forSegment: $0) == title }) else {
                fatalError("Missing native audit control: \(title)")
            }
            control.selectedSegment = index
            control.sendAction(control.action, to: control.target)
        }
        for title in ["Faders", "All rows", "Selected"] {
            select(title); flush()
            try await Task.sleep(for: .milliseconds(450))
            var timings: [Double] = []
            model.beginProfileGesture(label: "Audit drag")
            for index in 0..<40 {
                let begin = CACurrentMediaTime()
                model.setBandGain(at: 0, to: sin(Double(index) / 6) * 8)
                flush()
                timings.append((CACurrentMediaTime() - begin) * 1000)
                try await Task.sleep(for: .milliseconds(8))
            }
            model.endProfileGesture()
            report("edit.\(title).\(count)", timings)
            model.undoProfile()
            require(model.profile == original, "Audited drags must retain exact one-step undo")
        }
        var switches: [Double] = []
        for title in ["Faders", "All rows", "Selected", "Faders", "All rows", "Selected"] {
            let begin = CACurrentMediaTime()
            select(title); flush()
            switches.append((CACurrentMediaTime() - begin) * 1000)
            try await Task.sleep(for: .milliseconds(450))
        }
        report("view-switch.\(count)", switches)
        var resizes: [Double] = []
        for size in [NSSize(width: 900, height: 620), NSSize(width: 1500, height: 900), NSSize(width: 1040, height: 690)] {
            let begin = CACurrentMediaTime()
            window.setContentSize(size); flush()
            resizes.append((CACurrentMediaTime() - begin) * 1000)
            try await Task.sleep(for: .milliseconds(120))
        }
        report("resize.\(count)", resizes)
        var actions: [Double] = []
        for index in 0..<12 {
            let begin = CACurrentMediaTime()
            model.setBypass(index.isMultiple(of: 2)); flush()
            actions.append((CACurrentMediaTime() - begin) * 1000)
            try await Task.sleep(for: .milliseconds(50))
        }
        report("bypass.\(count)", actions)
        model.setBypass(false)
        model.setMatchLevels(true)
        var matched: [Double] = []
        model.beginProfileGesture(label: "Audit matched drag")
        for index in 0..<20 {
            let begin = CACurrentMediaTime()
            model.setBandGain(at: 0, to: Double(index) / 5); flush()
            matched.append((CACurrentMediaTime() - begin) * 1000)
            try await Task.sleep(for: .milliseconds(16))
        }
        model.endProfileGesture(); model.undoProfile(); model.setMatchLevels(false)
        report("match-level-edit.\(count)", matched)
        model.setInterfaceZoom(.largest)
        window.setContentSize(NSSize(width: 900, height: 620))
        model.setFilterPanelPosition(.right)
        select("Faders"); flush()
        try await Task.sleep(for: .milliseconds(500))
        var compactEdits: [Double] = []
        model.beginProfileGesture(label: "Audit compact drag")
        for index in 0..<20 {
            let begin = CACurrentMediaTime()
            model.setBandGain(at: count - 1, to: Double(index) / 5); flush()
            compactEdits.append((CACurrentMediaTime() - begin) * 1000)
            try await Task.sleep(for: .milliseconds(16))
        }
        model.endProfileGesture(); model.undoProfile()
        report("edit.compact-side-140.\(count)", compactEdits)
        model.setInterfaceZoom(.actualSize)
        model.setFilterPanelPosition(.below)
        // Meter polling and background login-status queries must not republish the
        // document after settling. The model's live timer remains enabled here.
        try await Task.sleep(for: .milliseconds(400))
        var publications = 0
        let observer = model.objectWillChange.sink { publications += 1 }
        for _ in 0..<100 { model.meter.update(0.1); model.meter.update(0.2) }
        try await Task.sleep(for: .seconds(1.1))
        observer.cancel()
        require(publications == 0 && !model.running && !model.route.hasResources, "Idle and meter updates must leave the document and routing alone")
        print("AUDIT idle.\(count) document-publications=\(publications)")
        window.close()
    }
    // A realistic large catalog exercises local search without network timing.
    let index = (0..<15000).map { "- [Headphone \($0)](./Provider/collection/Headphone%20\($0)) by Provider" }.joined(separator: "\n")
    let catalog = try AutoEQCatalog.parse(index)
    var searches: [Double] = []
    for query in ["Headphone", "Headphone 123", "missing model", "1234", "Provider"] {
        let begin = CACurrentMediaTime()
        _ = AutoEQCatalogEntry.matching(catalog, query: query)
        searches.append((CACurrentMediaTime() - begin) * 1000)
    }
    report("catalog-search.15000", searches)
    func secondary<Content: View>(_ name: String, content: Content, size: NSSize, searchPlaceholder: String? = nil,
                                 editing model: Model? = nil) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let begin = CACurrentMediaTime()
        let host = NSHostingView(rootView: content)
        window.contentView = host
        func flush() { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush() }
        flush()
        report("open.\(name)", [(CACurrentMediaTime() - begin) * 1000])
        try await Task.sleep(for: .milliseconds(300))
        flush()
        if let searchPlaceholder {
            func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            guard let field = fields(host).first(where: { $0.isEditable && $0.placeholderString == searchPlaceholder }),
                  window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else {
                fatalError("Missing native search field in \(name)")
            }
            var timings: [Double] = []
            for query in ["1", "12", "123", "missing", "", "Headphone", "Preset"] {
                let start = CACurrentMediaTime()
                editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                flush()
                timings.append((CACurrentMediaTime() - start) * 1000)
                try await Task.sleep(for: .milliseconds(60))
            }
            report("search.\(name)", timings)
        }
        if let model {
            model.setInterfaceMode(.professional)
            let original = model.profile
            let icon = AppIconController(running: model.$running.eraseToAnyPublisher(), bypass: model.$bypass.eraseToAnyPublisher(),
                                         loadImage: { _ in NSImage(size: NSSize(width: 16, height: 16)) }, reportError: { fatalError($0) })
            let mainWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
            mainWindow.isReleasedWhenClosed = false
            let mainHost = NSHostingView(rootView: MainView(model: model, icon: icon))
            mainWindow.contentView = mainHost
            mainHost.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            var timings: [Double] = []
            model.beginProfileGesture(label: "Audit multiple windows")
            for index in 0..<20 {
                let start = CACurrentMediaTime()
                model.setBandGain(at: 0, to: Double(index) / 5)
                mainHost.layoutSubtreeIfNeeded(); mainWindow.displayIfNeeded(); flush()
                timings.append((CACurrentMediaTime() - start) * 1000)
                try await Task.sleep(for: .milliseconds(16))
            }
            model.endProfileGesture(); model.undoProfile()
            require(model.profile == original, "Multiple-window edits must retain exact drag undo")
            report("edit.with-\(name)", timings)
            mainWindow.close()
        }
        window.close()
    }
    var settings = Settings()
    settings.startEQAutomatically = false
    for index in 0..<1000 { settings.presets[String(format: "Preset %04d", index)] = Profile() }
    let file = directory.appendingPathComponent("library.json")
    try JSONEncoder().encode(settings).write(to: file)
    let libraryModel = Model(settingsFile: file, readLoginStatus: { .notRegistered })
    try await secondary("preset-library.1000", content: PresetLibraryView(model: libraryModel), size: NSSize(width: 900, height: 680), searchPlaceholder: "Search presets", editing: libraryModel)
    let browser = AutoEQBrowser(fetchCatalog: { _ in catalog }, fetchPreview: { AutoEQPreview(entry: $0, profile: Profile()) })
    try await secondary("autoeq.15000", content: AutoEQBrowserView(model: libraryModel, browser: browser), size: NSSize(width: 900, height: 680), searchPlaceholder: "Search headphones", editing: libraryModel)
    var draftProfile = Profile()
    draftProfile.filters = (0..<Profile.maxFilters).map { ImportedFilter(kind: .peak, frequency: 30 + Double($0) * 200, gain: 0, q: 1.4, enabled: true) }
    require(libraryModel.replaceProfile(draftProfile), "The maximum draft must validate")
    try await secondary("draft-editor.64", content: FilterEditor(model: libraryModel), size: NSSize(width: 960, height: 760), editing: libraryModel)
    try await secondary("stereo", content: StereoPanel(model: libraryModel, submissions: PrecisionSubmissionCoordinator()), size: NSSize(width: 900, height: 360))
    try await secondary("settings", content: StartupSettings(model: libraryModel), size: NSSize(width: 500, height: 650))
    require(!libraryModel.running && !libraryModel.route.hasResources, "Secondary-window audits must never start audio")
    if let path = ProcessInfo.processInfo.environment["AURAL_AUDIT_JSON"] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: path))
    }
}
