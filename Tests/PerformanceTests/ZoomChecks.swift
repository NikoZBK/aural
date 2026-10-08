import AppKit
import Combine
import SwiftUI

@MainActor func checkInterfaceZoom() throws {
    let legacy = try JSONDecoder().decode(Settings.self, from: Data(#"{"devices":{},"presets":{},"selectedUID":""}"#.utf8))
    require(legacy.interfaceZoom == .actualSize && Settings().interfaceZoom == .actualSize,
            "New and existing installs must retain their original size")
    for invalid in ["75", "141", "110.5", "\"large\""] {
        let data = Data("{\"devices\":{},\"presets\":{},\"selectedUID\":\"\",\"interfaceZoom\":\(invalid)}".utf8)
        do { _ = try JSONDecoder().decode(Settings.self, from: data); fatalError("Invalid zoom must be rejected") }
        catch is DecodingError { }
    }
    for (key, flags, expected): (String, NSEvent.ModifierFlags, InterfaceZoomShortcut) in [
        ("+", .command, .increase), ("=", .command, .increase), ("=", [.command, .shift], .increase),
        ("+", [.command, .shift], .increase), ("+", [.command, .numericPad], .increase),
        ("-", [.command, .capsLock], .decrease), ("0", .command, .reset)
    ] {
        require(InterfaceZoomShortcut(key: key, modifiers: flags) == expected, "Standard zoom key variants must work")
    }
    for flags: NSEvent.ModifierFlags in [[], .control, [.command, .option], [.command, .control]] {
        require(InterfaceZoomShortcut(key: "+", modifiers: flags) == nil, "Other shortcuts and ordinary typing must pass through")
    }
    require(InterfaceZoomShortcut(key: "-", modifiers: [.command, .shift]) == nil &&
            InterfaceZoomShortcut(key: "z", modifiers: .command) == nil, "Zoom must not capture undo or unrelated keys")

    // Native probes check the real layout contract at both roomy and overflowing
    // sizes: fixed rows remain separate, and the curve gets the remaining space.
    for scale: CGFloat in [1, 1.4] {
        for height: CGFloat in [350, 500, 700] {
            let probes = (0..<6).map { _ in NSView() }
            let layout = NSHostingView(rootView:
                AuralWorkspaceLayout(availableHeight: height, minimumInspectorHeight: 80 * scale, scale: scale) {
                    ZoomLayoutProbe(view: probes[0]).frame(height: 44 * scale)
                    ZoomLayoutProbe(view: probes[1]).frame(height: 0)
                    ZoomLayoutProbe(view: probes[2]).frame(minHeight: 210 * scale, maxHeight: .infinity)
                    ZoomLayoutProbe(view: probes[3])
                    ZoomLayoutProbe(view: probes[4]).frame(height: 24 * scale)
                    ZoomLayoutProbe(view: probes[5]).frame(minHeight: 40, idealHeight: 146 * scale, maxHeight: 146 * scale)
                })
            layout.frame = NSRect(x: 0, y: 0, width: 900, height: height)
            layout.layoutSubtreeIfNeeded()
            let frames = probes.map { $0.convert($0.bounds, to: layout) }
            let rows = [frames[0], frames[1], frames[2], frames[4]]
            for (above, below) in zip(rows, rows.dropFirst()) {
                require(below.minY >= above.maxY + 10 * scale - 0.1, "Zoom layout must keep every row separate even when it needs to scroll")
            }
            require(abs(frames[5].minY - frames[4].maxY) < 1 && frames[3].insetBy(dx: -1, dy: -1).contains(frames[4].union(frames[5])) &&
                    frames[4].union(frames[5]).insetBy(dx: -1, dy: -1).contains(frames[3]),
                    "The inspector card must hold its tabs and the inspector together: \(frames)")
            require(abs(frames[0].height - 44 * scale) <= 1 && abs(frames[4].height - 24 * scale) <= 1 &&
                    frames[2].height + 1 >= 210 * scale && frames[5].height + 1 >= 80 * scale,
                    "Zoom layout must preserve controls, a readable curve, and a reachable inspector: \(frames)")
            if height == 700 {
                require(abs(frames[5].maxY - height) < 1, "The graph must fill the remaining room in a large workspace")
            } else if height == 350 {
                require(frames[5].maxY > height, "A constrained workspace must scroll without compressing its controls")
            }
        }
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-zoom-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("settings.json")
    let model = Model(settingsFile: file, readLoginStatus: { .notRegistered })
    defer { model.stop() }
    model.setPreamp(-4.312345)
    model.selectComparison(.b)
    model.setPreamp(-5.123456)
    model.setBypass(true)
    let profile = model.profile, revision = model.editRevision, output = model.selectedUID
    let comparison = model.otherComparisonProfile, undoLabel = model.undoLabel, slot = model.comparisonSlot
    let preset = model.selectedPresetName, mode = model.interfaceMode, theme = model.theme
    var publications = 0
    let observation = model.$interfaceZoom.dropFirst().sink { zoom in
        let saved = try! JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
        require(saved.interfaceZoom == zoom, "Zoom must be saved before publishing the new size")
        publications += 1
    }
    for _ in 0..<10 { InterfaceZoomShortcut.increase.perform(on: model) }
    require(model.interfaceZoom == .largest && publications == 4, "Zoom in must stop at its upper bound without duplicate publications")
    for _ in 0..<10 { InterfaceZoomShortcut.decrease.perform(on: model) }
    require(model.interfaceZoom == .smallest && publications == 10, "Zoom out must stop at its lower bound")
    InterfaceZoomShortcut.reset.perform(on: model)
    require(model.interfaceZoom == .actualSize && publications == 11, "Command-0 must restore the default size")
    model.resetZoom()
    require(publications == 11, "Reset at actual size must be a no-op")
    model.zoomIn()
    require(Model(settingsFile: file, readLoginStatus: { .notRegistered }).interfaceZoom == .large,
            "Zoom must survive relaunch")
    observation.cancel()
    require(model.profile == profile && model.editRevision == revision && model.selectedUID == output &&
            model.otherComparisonProfile == comparison && model.comparisonSlot == slot && model.undoLabel == undoLabel &&
            model.selectedPresetName == preset && model.interfaceMode == mode && model.theme == theme &&
            !model.running && model.bypass && !model.route.hasResources,
            "Zoom must preserve exact EQ, history, A/B, presets, output, appearance, and audio state")

    let blockedParent = directory.appendingPathComponent("file-as-directory")
    try Data("fixture".utf8).write(to: blockedParent)
    let blocked = Model(settingsFile: blockedParent.appendingPathComponent("settings.json"), readLoginStatus: { .notRegistered })
    blocked.zoomIn()
    require(blocked.interfaceZoom == .actualSize && blocked.error?.contains("Could not save interface zoom:") == true,
            "A failed save must keep the previous size and surface the error")

    let icon = AppIconController(running: model.$running.eraseToAnyPublisher(), bypass: model.$bypass.eraseToAnyPublisher(),
                                 loadImage: { _ in NSImage(size: NSSize(width: 16, height: 16)) }, reportError: { fatalError($0) })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 690), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: MainView(model: model, icon: icon))
    window.contentView = host
    func flush() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
    func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    model.setInterfaceMode(.professional)
    model.resetZoom()
    flush()
    let editors = fields(in: host).filter(\.isEditable)
    require(!editors.isEmpty, "The zoom fixture must contain native numeric editors")
    let editorIDs = Set(editors.map(ObjectIdentifier.init))
    let field = editors[0]
    guard let originalFontSize = field.font?.pointSize else { fatalError("The numeric editor must have a native font") }
    let originalWidth = field.convert(field.bounds, to: host).width
    require(window.makeFirstResponder(field), "The numeric field must accept keyboard focus")
    guard let editor = field.currentEditor() as? NSTextView else { fatalError("The focused field must use the native text editor") }
    editor.insertText("-", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    let pending = field.stringValue
    model.zoomIn()
    flush()
    require(field.stringValue == pending && field.currentEditor() === editor && model.profile == profile,
            "Zoom must retain focused partial numbers without submitting or replacing the field")
    require((field.font?.pointSize ?? 0) > originalFontSize && field.convert(field.bounds, to: host).width > originalWidth,
            "Zoom must enlarge the actual native font and control bounds, not just surrounding artwork")
    for size in [NSSize(width: 900, height: 620), NSSize(width: 1040, height: 690), NSSize(width: 1500, height: 900)] {
        window.setContentSize(size)
        for zoom in AuralInterfaceZoom.allCases {
            model.setInterfaceZoom(zoom)
            for position in FilterPanelPosition.allCases {
                model.setFilterPanelPosition(position)
                flush()
                require(host.frame.size == size, "Zoom must keep the main window's supported dimensions")
                require(editorIDs.isSubset(of: Set(fields(in: host).filter(\.isEditable).map(ObjectIdentifier.init))),
                        "Zoom, panel placement, and responsive toolbar changes must retain native numeric editors")
            }
        }
    }
    require(field.stringValue == pending && field.currentEditor() === editor && model.profile == profile,
            "Resizing, panel placement, and zoom bounds must keep the pending draft focused without changing EQ")
    print("PASS zoom key variants, bounds, migration, persistence, failed saves, retained focused drafts, workspace sizes, history, and audio neutrality")
}

// The level bar once multiplied its already-zoomed track width by the zoom again, so above
// 100% any peak louder than about −14 dB covered the whole track and the meter looked pinned.
@MainActor func checkMeterZoom() {
    for zoom in AuralInterfaceZoom.allCases {
        let meter = AudioMeter()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: StudioMeter(meter: meter, running: true, protectionEnabled: .constant(true), compact: true)
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.black).environment(\.auralInterfaceScale, zoom.scale))
        window.contentView = host
        func render(peak: Float) -> NSBitmapImageRep {
            meter.update(peak)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Could not allocate the meter capture") }
            host.cacheDisplay(in: host.bounds, to: image)
            return image
        }
        let silent = render(peak: 0)
        let pixels = CGFloat(silent.pixelsWide) / host.bounds.width
        // The bar is the first run of changed columns; the reading's text starts well after it.
        func fillWidth(peak: Float) -> CGFloat {
            let image = render(peak: peak)
            let changed = (0..<image.pixelsWide).map { x in
                (0..<image.pixelsHigh).contains { y in
                    guard let a = image.colorAt(x: x, y: y), let b = silent.colorAt(x: x, y: y) else { return false }
                    return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.15
                }
            }
            guard let start = changed.firstIndex(of: true) else { return 0 }
            return CGFloat((changed[start...].firstIndex(of: false) ?? changed.count) - start) / pixels
        }
        let track = 70 * zoom.scale
        let full = fillWidth(peak: 1), loud = fillWidth(peak: 0.5)
        require(abs(full - track) <= 1.5, "A 0 dB peak must fill exactly the track at \(zoom.rawValue)%: \(full) of \(track) pt")
        require(abs(loud - track * (20 * log10(0.5) + 60) / 60) <= 1.5,
                "A −6 dB peak must fill 90% of the track at \(zoom.rawValue)%: \(loud) of \(track) pt")
    }
    print("PASS level meter fills its track in proportion at every interface zoom")
}

private struct ZoomLayoutProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ view: NSView, context: Context) { }
}

@MainActor func checkFilterPanelPosition() throws {
    let legacy = try JSONDecoder().decode(Settings.self, from: Data(#"{"devices":{},"presets":{},"selectedUID":""}"#.utf8))
    require(legacy.filterPanelPosition == .below && Settings().filterPanelPosition == .below,
            "New and existing settings must keep the panel below until the user moves it")
    do {
        _ = try JSONDecoder().decode(Settings.self, from: Data(#"{"devices":{},"presets":{},"selectedUID":"","filterPanelPosition":"floating"}"#.utf8))
        fatalError("Unknown panel placements must be rejected")
    } catch is DecodingError { }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-panel-position-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("settings.json")
    let model = Model(settingsFile: file, readLoginStatus: { .notRegistered })
    model.setPreamp(-4.123456)
    model.selectComparison(.b)
    model.setPreamp(-5.765432)
    let profile = model.profile, comparison = model.otherComparisonProfile, revision = model.editRevision
    let undo = model.undoLabel, slot = model.comparisonSlot, output = model.selectedUID
    var publications = 0
    let observation = model.$filterPanelPosition.dropFirst().sink { position in
        let saved = try! JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
        require(saved.filterPanelPosition == position, "Panel placement must save before publication")
        publications += 1
    }
    model.setFilterPanelPosition(.right)
    model.setFilterPanelPosition(.right)
    require(publications == 1, "Repeated panel selections must be no-ops")
    require(Model(settingsFile: file, readLoginStatus: { .notRegistered }).filterPanelPosition == .right,
            "Panel position must survive relaunch")
    model.setFilterPanelPosition(.below)
    observation.cancel()
    require(model.profile == profile && model.otherComparisonProfile == comparison && model.editRevision == revision &&
            model.undoLabel == undo && model.comparisonSlot == slot && model.selectedUID == output && !model.running && !model.route.hasResources,
            "Moving the panel must preserve exact audio, A/B, history, and routing")
    let blockedFile = directory.appendingPathComponent("blocked")
    try Data("fixture".utf8).write(to: blockedFile)
    let blocked = Model(settingsFile: blockedFile.appendingPathComponent("settings.json"), readLoginStatus: { .notRegistered })
    blocked.setFilterPanelPosition(.right)
    require(blocked.filterPanelPosition == .below && blocked.error?.contains("Could not save filter panel position:") == true,
            "Failed saves must preserve placement and report the problem")

    for scale: CGFloat in [0.8, 1, 1.4] {
        for width: CGFloat in [860, 1460] {
            let probes = (0..<6).map { _ in NSView() }
            let panelWidth = AuralWorkspaceLayout.sidePanelWidth(in: width, scale: scale)
            let layout = NSHostingView(rootView:
                AuralWorkspaceLayout(availableHeight: 700, minimumInspectorHeight: 80 * scale, sidePanelWidth: panelWidth, scale: scale) {
                    ZoomLayoutProbe(view: probes[0]).frame(height: 70 * scale)
                    ZoomLayoutProbe(view: probes[1]).frame(height: 0)
                    ZoomLayoutProbe(view: probes[2]).frame(minHeight: 210 * scale, maxHeight: .infinity)
                    ZoomLayoutProbe(view: probes[3])
                    ZoomLayoutProbe(view: probes[4]).frame(height: 36 * scale)
                    ZoomLayoutProbe(view: probes[5]).frame(maxHeight: .infinity)
                })
            layout.frame = NSRect(x: 0, y: 0, width: width, height: 700)
            layout.layoutSubtreeIfNeeded()
            let frames = probes.map { $0.convert($0.bounds, to: layout) }
            require(abs(frames[2].maxX + 20 * scale - frames[5].minX) < 1 && abs(frames[5].maxX - width) < 1,
                    "The graph must shrink to leave a separate right-hand panel: \(frames)")
            require(abs(frames[2].maxY - 700) < 1 && abs(frames[5].maxY - 700) < 1 && frames[5].height > 206 * scale,
                    "The side inspector must use the remaining height rather than the four-row cap")
            require(abs(frames[3].minY - frames[2].minY) < 1 && abs(frames[3].minX - frames[4].minX) < 1 &&
                    abs(frames[3].maxY - frames[5].maxY) < 1 && abs(frames[5].minY - frames[4].maxY) < 1,
                    "The side card must start level with the graph and hold its tabs and inspector together: \(frames)")
            for compact in [false, true] {
                let cells = (0..<7).map { _ in NSView() }
                let columnWidth = (compact ? 320.0 : 540.0) * scale
                let columnHeight = (compact ? 78.0 : 39.0) * scale
                let columns = NSHostingView(rootView: FilterColumns(height: columnHeight, scale: scale, compact: compact) {
                    ForEach(0..<7) { index in ZoomLayoutProbe(view: cells[index]) }
                })
                columns.frame = NSRect(x: 0, y: 0, width: columnWidth, height: columnHeight)
                columns.layoutSubtreeIfNeeded()
                let cellFrames = cells.map { $0.convert($0.bounds, to: columns) }
                for (index, frame) in cellFrames.enumerated() {
                    require(frame.minX >= -1 && frame.maxX <= columnWidth + 1 && frame.minY >= -1 && frame.maxY <= columnHeight + 1,
                            "Every filter control must stay inside its row at all zoom sizes: \(scale), \(compact), \(columnWidth), \(columnHeight), \(cellFrames)")
                    for other in cellFrames.dropFirst(index + 1) {
                        require(!frame.intersects(other), "Compact numeric fields must wrap without overlapping other controls")
                    }
                }
            }
        }
    }
    print("PASS panel placement persistence, failed saves, full-height side layout, compact fields, and audio neutrality")
}
