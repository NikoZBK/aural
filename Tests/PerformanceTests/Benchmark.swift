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
        func panelContainer(in view: NSView) -> InterfacePanelContainer? {
            if let container = view as? InterfacePanelContainer { return container }
            return view.subviews.lazy.compactMap { panelContainer(in: $0) }.first
        }
        guard let container = panelContainer(in: host) else { fatalError("Missing interface panel container") }
        let preparationStarted = CACurrentMediaTime()
        let preparationDeadline = Date().addingTimeInterval(10)
        while container.isLoading {
            require(Date() < preparationDeadline, "Startup preload did not finish")
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            flush()
        }
        print(String(format: "Startup bands=%d two-panel preload=%.2fms", bands, (CACurrentMediaTime() - preparationStarted) * 1000))
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
        window.setContentSize(NSSize(width: 1060, height: 700))
        flush()
        require(host.frame.size == NSSize(width: 1060, height: 700), "Professional must fit its supported minimum viewport")
        try capture("professional-minimum-\(bands).png")
        model.setInterfaceMode(.easy)
        for (name, width, height) in [("minimum", 900.0, 640.0), ("wide", 1694.0, 970.0)] {
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
