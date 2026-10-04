import AppKit
import SwiftUI
import Combine
import QuartzCore

@MainActor func runUIBenchmark() throws {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-perf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    for bands in [10, 31] {
        let file = directory.appendingPathComponent("settings-\(bands).json")
        var settings = Settings()
        settings.interfaceMode = .easy
        settings.startEQAutomatically = false
        try JSONEncoder().encode(settings).write(to: file)
        let model = Model(settingsFile: file, readLoginStatus: { .notRegistered })
        if bands == 31 { model.useGraphicTemplate(bands: bands) }
        application.appearance = model.theme.appearance
        let icon = AppIconController(running: model.$running.eraseToAnyPublisher(), bypass: model.$bypass.eraseToAnyPublisher(), loadImage: { _ in NSImage(size: NSSize(width: 16, height: 16)) }, reportError: { fatalError($0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MainView(model: model, icon: icon))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1240, height: 820)
        func flush() {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        func capture(_ name: String) throws {
            guard let captureDirectory = ProcessInfo.processInfo.environment["AURAL_BENCH_CAPTURE_DIR"] else { return }
            guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Could not allocate the UI preview") }
            host.cacheDisplay(in: host.bounds, to: image)
            guard let png = image.representation(using: .png, properties: [:]) else { fatalError("Could not encode the UI preview") }
            try png.write(to: URL(fileURLWithPath: captureDirectory).appendingPathComponent(name))
        }
        flush()
        try capture("startup-\(bands).png")
        let preparationStarted = CACurrentMediaTime()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        flush()
        print(String(format: "Startup bands=%d workspace=%.2fms", bands, (CACurrentMediaTime() - preparationStarted) * 1000))
        for mode in [InterfaceMode.professional, .easy, .professional, .easy] {
            let begin = CACurrentMediaTime()
            model.setInterfaceMode(mode)
            let saved = CACurrentMediaTime()
            flush()
            let laidOut = CACurrentMediaTime()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            flush()
            print(String(format: "UI bands=%d mode=%@ save=%.2fms layout=%.2fms", bands, mode.rawValue, (saved - begin) * 1000, (laidOut - saved) * 1000))
        }
        for count in [10, 31] {
            var profile = count == 10 ? Profile(gains: Array(repeating: 3, count: 10), preamp: -6) : try ProfileTools.graphicTemplate(bands: count, preserving: Profile())
            if let filters = profile.filters {
                profile.filters = filters.enumerated().map { index, filter in
                    var next = filter
                    next.gain = index.isMultiple(of: 2) ? 3 : -2
                    return next
                }
            }
            let begin = CACurrentMediaTime()
            for _ in 0..<30 { _ = ResponseAnalysis(profile: profile, rate: 48000, bypass: false) }
            print(String(format: "Response bands=%d average=%.2fms", count, (CACurrentMediaTime() - begin) * 1000 / 30))
        }
        model.setInterfaceMode(.professional)
        window.setContentSize(NSSize(width: 900, height: 620))
        flush()
        require(host.frame.size == NSSize(width: 900, height: 620), "Expanded workspace must fit its supported minimum viewport")
        try capture("professional-minimum-\(bands).png")
        model.setInterfaceMode(.easy)
        for (name, width, height) in [("minimum", 900.0, 620.0), ("wide", 1694.0, 970.0)] {
            window.setContentSize(NSSize(width: width, height: height))
            flush()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            flush()
            try capture("simple-\(name)-\(bands).png")
        }
        model.stop()
        window.close()
    }
}

@MainActor private final class RackBenchmarkState: ObservableObject {
    @Published var display = FilterDisplay.selected
    @Published var selected = 0
}

private struct RackBenchmarkView: View {
    @ObservedObject var model: Model
    @ObservedObject var state: RackBenchmarkState
    @StateObject private var submissions = PrecisionSubmissionCoordinator()
    var body: some View {
        FilterRack(model: model, submissions: submissions, selectedBand: $state.selected, display: $state.display)
            .frame(height: 206).padding(20).auralAppearance(.dark)
    }
}

@MainActor func runRackBenchmark() throws {
    NSApplication.shared.setActivationPolicy(.accessory)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-rack-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    for count in [10, 31] {
        var settings = Settings()
        settings.startEQAutomatically = false
        let file = directory.appendingPathComponent("settings.json")
        try JSONEncoder().encode(settings).write(to: file)
        let model = Model(settingsFile: file, readLoginStatus: { .notRegistered })
        model.useGraphicTemplate(bands: count)
        if model.profile.filters == nil { model.editGraphicAsFilters() }
        let original = model.profile
        model.setInterfaceMode(.professional)
        let icon = AppIconController(running: model.$running.eraseToAnyPublisher(), bypass: model.$bypass.eraseToAnyPublisher(), loadImage: { _ in NSImage(size: NSSize(width: 16, height: 16)) }, reportError: { fatalError($0) })
        let fullWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 690), styleMask: [.titled], backing: .buffered, defer: false)
        fullWindow.isReleasedWhenClosed = false
        let fullHost = NSHostingView(rootView: MainView(model: model, icon: icon))
        fullWindow.contentView = fullHost
        fullHost.layoutSubtreeIfNeeded()
        func segments(in view: NSView) -> [NSSegmentedControl] {
            (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap { segments(in: $0) }
        }
        guard let picker = segments(in: fullHost).first(where: { control in
            (0..<control.segmentCount).contains { control.label(forSegment: $0) == "All rows" }
        }) else { fatalError("Missing native filter display control") }
        func editableFields(in view: NSView) -> Set<ObjectIdentifier> {
            if let field = view as? NSTextField, field.isEditable { return [ObjectIdentifier(field)] }
            return view.subviews.reduce(into: Set<ObjectIdentifier>()) { $0.formUnion(editableFields(in: $1)) }
        }
        let retainedFields = editableFields(in: fullHost)
        require(!retainedFields.isEmpty, "The workspace must create its exact-value controls")
        for index in [1, 0, 1, 2, 1] {
            let start = CACurrentMediaTime()
            picker.selectedSegment = index
            picker.sendAction(picker.action, to: picker.target)
            fullHost.layoutSubtreeIfNeeded()
            fullWindow.displayIfNeeded()
            CATransaction.flush()
            require(retainedFields.isSubset(of: editableFields(in: fullHost)), "Changing filter views must retain native numeric editors")
            print(String(format: "Workspace bands=%d segment=%d layout=%.2fms", count, index, (CACurrentMediaTime()-start)*1000))
        }
        for mode in [InterfaceMode.easy, .professional] {
            model.setInterfaceMode(mode)
            fullHost.layoutSubtreeIfNeeded()
            require(retainedFields.isSubset(of: editableFields(in: fullHost)), "Disclosure must retain numeric editors")
        }
        if let path = ProcessInfo.processInfo.environment["AURAL_BENCH_CAPTURE_DIR"] {
            guard let image = fullHost.bitmapImageRepForCachingDisplay(in: fullHost.bounds) else { fatalError("Could not allocate rows capture") }
            fullHost.cacheDisplay(in: fullHost.bounds, to: image)
            guard let png = image.representation(using: .png, properties: [:]) else { fatalError("Could not encode rows capture") }
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("all-rows-\(count).png"))
        }
        fullWindow.close()
        let state = RackBenchmarkState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 246), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RackBenchmarkView(model: model, state: state))
        window.contentView = host
        func flush() { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush() }
        flush()
        for display in [FilterDisplay.rows, .selected, .rows, .faders, .rows] {
            let start = CACurrentMediaTime()
            state.display = display
            flush()
            let layout = CACurrentMediaTime()
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            flush()
            print(String(format: "Rack bands=%d view=%@ layout=%.2fms settled=%.2fms", count, String(describing: display), (layout-start)*1000, (CACurrentMediaTime()-start)*1000))
        }
        require(model.profile == original && !model.running, "View switches must preserve EQ and playback")
        window.close()
    }
}
