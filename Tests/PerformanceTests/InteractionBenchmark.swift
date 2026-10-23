import AppKit
import Combine
import QuartzCore
import SwiftUI

private enum InteractionSurface: String, CaseIterable {
    case workspaceFaders, workspaceRows, rackFaders, rackRows, bars, curve
}

private struct InteractionProbe: View {
    @ObservedObject var model: Model
    let icon: AppIconController
    let surface: InteractionSurface
    @StateObject private var submissions = PrecisionSubmissionCoordinator()
    @State private var selected = 0
    @State private var display = FilterDisplay.faders

    var body: some View {
        Group {
            switch surface {
            case .workspaceFaders, .workspaceRows:
                MainView(model: model, icon: icon)
            case .rackFaders, .rackRows:
                FilterRack(model: model, submissions: submissions, selectedBand: $selected, display: $display)
                    .padding(16)
            case .bars:
                EQBars(model: model, submissions: submissions, showParameters: true).padding(16)
            case .curve:
                ResponseCurve(profile: model.profile, rate: 48000, bypass: false, running: false,
                              selectedBand: selected, selectBand: { selected = $0 }).equatable().padding(16)
            }
        }.auralAppearance(.dark)
    }
}

private struct InteractionTiming: Codable {
    let surface: String
    let filters: Int
    let samples: Int
    let documentMedianMS: Double
    let layoutMedianMS: Double
    let medianMS: Double
    let p95MS: Double
    let maximumMS: Double
}

/// Separate graph work, retained controls, and workspace layout using the same
/// model edits and real hosting views. No user settings or audio route is used.
@MainActor func runInteractionBenchmark() async throws {
    NSApplication.shared.setActivationPolicy(.accessory)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-interactions-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let environment = ProcessInfo.processInfo.environment
    let surfaces: [InteractionSurface]
    if let name = environment["AURAL_INTERACTION_SURFACE"] {
        guard let surface = InteractionSurface(rawValue: name) else { fatalError("Unknown interaction surface: \(name)") }
        surfaces = [surface]
    } else { surfaces = InteractionSurface.allCases }
    var measurements: [InteractionTiming] = []
    for count in [10, 31, Profile.maxFilters] {
        for surface in surfaces {
            let model = Model(settingsFile: directory.appendingPathComponent("\(count)-\(surface).json"), readLoginStatus: { .notRegistered })
            var profile = Profile()
            profile.filters = (0..<count).map {
                ImportedFilter(kind: .peak, frequency: 25 * pow(700, Double($0) / Double(count - 1)), gain: 0, q: 1.4, enabled: true)
            }
            require(model.replaceProfile(profile), "Interaction fixtures must validate")
            model.setInterfaceMode(.professional)
            let original = model.profile
            let icon = AppIconController(running: model.$running.eraseToAnyPublisher(), bypass: model.$bypass.eraseToAnyPublisher(),
                                         loadImage: { _ in NSImage(size: NSSize(width: 16, height: 16)) }, reportError: { fatalError($0) })
            let workspace = surface == .workspaceFaders || surface == .workspaceRows
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: workspace ? 1240 : 1000, height: workspace ? 820 : 380),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: InteractionProbe(model: model, icon: icon, surface: surface))
            window.contentView = host
            func flush() { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush() }
            flush()
            if surface == .workspaceRows || surface == .rackRows {
                func segments(_ view: NSView) -> [NSSegmentedControl] {
                    (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap(segments)
                }
                guard let control = segments(host).first(where: { candidate in
                    (0..<candidate.segmentCount).contains { candidate.label(forSegment: $0) == "All rows" }
                }), let index = (0..<control.segmentCount).first(where: { control.label(forSegment: $0) == "All rows" }) else {
                    fatalError("Missing native filter-view picker")
                }
                control.selectedSegment = index
                control.sendAction(control.action, to: control.target)
            }
            try await Task.sleep(for: .milliseconds(400))
            flush()
            print("INTERACTION begin \(surface.rawValue) filters=\(count)"); fflush(stdout)
            var document: [Double] = [], layout: [Double] = [], total: [Double] = []
            model.beginProfileGesture(label: "Interaction benchmark")
            for index in 0..<60 {
                let start = CACurrentMediaTime()
                // Gain, frequency and Q all use the same live filter-edit path.
                var filter = model.profile.filters![0]
                filter.gain = sin(Double(index) / 6) * 8
                filter.frequency = 25 + Double(index % 10) / 10
                filter.q = 1.4 + Double(index % 5) / 100
                model.updateFilter(at: 0, with: filter)
                let committed = CACurrentMediaTime()
                flush()
                let end = CACurrentMediaTime()
                document.append((committed - start) * 1000)
                layout.append((end - committed) * 1000)
                total.append((end - start) * 1000)
                try await Task.sleep(for: .milliseconds(8))
            }
            model.endProfileGesture()
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            let sorted = total.sorted()
            let timing = InteractionTiming(surface: surface.rawValue, filters: count, samples: total.count,
                                           documentMedianMS: median(document), layoutMedianMS: median(layout), medianMS: median(total),
                                           p95MS: sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], maximumMS: sorted.last!)
            measurements.append(timing)
            print(String(format: "INTERACTION %@ filters=%d document=%.2fms layout=%.2fms median=%.2fms p95=%.2fms max=%.2fms",
                         timing.surface, count, timing.documentMedianMS, timing.layoutMedianMS, timing.medianMS, timing.p95MS, timing.maximumMS))
            fflush(stdout)
            try await Task.sleep(for: .milliseconds(80))
            flush()
            if surface != .curve {
                func fields(_ view: NSView) -> [NSTextField] {
                    (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
                }
                guard let gain = fields(host).first(where: { $0.isEnabled && $0.isEditable && $0.accessibilityLabel() == "Filter 1 gain in decibels" }) else {
                    fatalError("Missing live gain editor in \(surface.rawValue)")
                }
                require(gain.stringValue == String(format: "%.2f", model.profile.filters![0].gain),
                        "A fast editor must still display the final accepted gain in \(surface.rawValue)")
            }
            model.undoProfile()
            require(model.profile == original && !model.running && !model.route.hasResources, "Interaction edits must retain one-step undo and never start audio")
            window.close()
        }
    }
    if let path = environment["AURAL_INTERACTION_JSON"] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(measurements).write(to: URL(fileURLWithPath: path))
    }
}
