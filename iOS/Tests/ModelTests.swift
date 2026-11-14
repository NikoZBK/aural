import Foundation

@main
struct ModelTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aural-ios-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { fatalError("Test cleanup failed: \(error)") } }
        let model = AuralModel(directory: root)
        assert(model.audio.starts == 0 && !model.audio.running)
        assert(model.state.library.theme == .system && model.state.library.peakProtectionEnabled)
        model.play(); model.setBypass(true)
        model.gesture(true)
        for value in [1.0, 2, 3] { model.edit { $0.gains[0] = value } }
        model.gesture(false)
        model.undo(); assert(model.profile.gains[0] == 0 && !model.history.canUndo)
        model.undo(redo: true); assert(model.profile.gains[0] == 3)
        assert(model.audio.running && model.audio.bypass && model.audio.starts == 1 && model.audio.stops == 0)
        model.captureComparison()
        model.edit { $0.gains[1] = -2 }
        model.swapComparison(); assert(model.profile.gains[1] == 0)
        model.swapComparison(); assert(model.profile.gains[1] == -2)
        assert(model.audio.bypass && model.audio.running)
        let before = model.profile
        model.audio.rejectNext = true
        do { try model.apply(Profile()); fatalError("Accepted rejected configuration") } catch {}
        assert(model.profile == before)
        do { try model.apply(Profile(), expectedRevision: model.revision - 1); fatalError("Accepted stale editor") } catch {}
        assert(model.profile == before)
        print("PASS grouped undo/redo, A/B, stale drafts and engine rejection preserve sound and bypass")

        try model.savePreset("Listening")
        model.edit { $0.preamp = -2 }
        assert(model.canUpdatePreset)
        try model.updateSelectedPreset()
        assert(model.state.library.presets["Listening"]?.preamp == -2 && !model.canUpdatePreset)
        model.edit { $0.preamp = before.preamp }
        try model.updateSelectedPreset()
        try model.libraryEdit { try $0.toggleFavorite("Listening") }
        try model.renamePreset("Listening", to: "Travel")
        assert(model.state.selectedPreset == "Travel" && model.state.library.favoritePresets?.contains("Travel") == true)
        let backup = PresetBackup(presets: ["Travel": Profile()], favorites: ["Travel"])
        try model.acceptImport(.library(backup))
        assert(model.state.library.presets["Travel"] == before)
        assert(model.state.library.presets["Travel (2)"] == Profile())
        assert(model.state.library.favoritePresets?.contains("Travel (2)") == true)
        try model.libraryEdit { try $0.deletePreset("Travel") }
        assert(model.profile == before && model.state.selectedPreset == nil && model.audio.running)
        do { try model.savePreset("Flat"); fatalError("Overwrote factory preset") } catch {}
        print("PASS preset identity, favorites, rename/delete, collision-safe backup merge")

        var precise = Profile()
        precise.filters = [ImportedFilter(kind: .lowPass, frequency: 1234.56789012345, gain: 0, q: 0.71234567890123, enabled: true, channel: .left, slope: .linkwitzRiley48)]
        precise.preamp = -3.123456789
        precise.stereo = StereoSettings(); precise.stereo?.rightDelayMS = 0.123456789
        let encoded = try JSONEncoder().encode(precise)
        let imported = try ProfileImport.read(encoded, name: "Precision", isJSON: true)
        assert(model.audio.running) // Parsing/preview is audio-neutral.
        try model.acceptImport(imported)
        assert(model.profile == precise && !model.audio.running)
        let loaded = AuralModel(directory: root)
        assert(loaded.profile == precise && loaded.state.bypass && loaded.audio.starts == 0)
        assert(loaded.audio.configuration?.filters.count == 4)
        assert(loaded.audio.configuration?.stereo.rightDelayMS == precise.stereo?.rightDelayMS)
        do { _ = try ProfileImport.read(Data("{bad".utf8), name: "Broken", isJSON: true); fatalError("Accepted malformed JSON") } catch {}
        do { _ = try ProfileImport.read(Data(repeating: 0, count: 4 * 1024 * 1024 + 1), name: "Huge", isJSON: true); fatalError("Accepted oversized import") } catch {}
        assert(loaded.profile == precise)
        print("PASS exact profile round trip, full filter expansion, import preview isolation, malformed/oversized rejection")

        let corrupt = root.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let brokenFile = corrupt.appendingPathComponent("library.json")
        let evidence = Data("invalid original settings".utf8)
        try evidence.write(to: brokenFile)
        let broken = AuralModel(directory: corrupt)
        assert(broken.storageProblem != nil && broken.issue != nil)
        broken.edit { $0.preamp = -4 }; broken.persist()
        let preserved = try Data(contentsOf: brokenFile)
        assert(preserved == evidence)
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let unsaved = AuralModel(directory: blocked)
        unsaved.edit { $0.preamp = -5 }
        assert(unsaved.storageProblem != nil && unsaved.issue != nil)
        print("PASS unreadable settings preserved, failed saves surfaced")
    }
}
