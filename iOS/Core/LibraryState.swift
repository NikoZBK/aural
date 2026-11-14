import Foundation

/// The same profiles and backup format as Aural for Mac; mobile preferences are separate.
struct LibraryState: Codable {
    var version = 1
    var profile = Profile()
    var library = Settings()
    var selectedPreset: String? = "Flat"
    var bypass = false
    var completedSetup = false

    init() {
        library.theme = .system
        library.filterPanelPosition = .right
    }
    func validated() throws -> Self {
        guard version == 1 else { throw AudioFailure(message: "These settings need a newer version of Aural.") }
        _ = try profile.validated()
        let backup = PresetBackup(presets: library.presets, favorites: library.favoritePresets)
        _ = try PresetBackup.decode(JSONEncoder().encode(backup))
        if let selectedPreset, library.preset(named: selectedPreset) == nil {
            throw AudioFailure(message: "The selected preset is missing from the library.")
        }
        return self
    }
    var modified: Bool {
        guard let selectedPreset, let original = library.preset(named: selectedPreset) else { return true }
        return !profile.hasSameEQ(as: original)
    }
}

struct LibraryFile {
    let url: URL
    func load() throws -> LibraryState {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 8 * 1024 * 1024 else { throw AudioFailure(message: "Aural’s settings file is too large to read.") }
            return try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: url)).validated()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return LibraryState()
        }
    }
    func save(_ state: LibraryState) throws {
        _ = try state.validated()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= 8 * 1024 * 1024 else { throw AudioFailure(message: "The settings exceed the 8 MB storage limit. Export a backup and remove unused presets.") }
        try data.write(to: url, options: .atomic)
    }
}

enum ProfileImport {
    case profile(Profile)
    case library(PresetBackup)

    static func read(_ data: Data, name: String, isJSON: Bool) throws -> Self {
        guard data.count <= 4 * 1024 * 1024 else { throw AudioFailure(message: "Imports must be smaller than 4 MB.") }
        if isJSON {
            let keys = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if keys?["presets"] != nil { return .library(try PresetBackup.decode(data)) }
            return .profile(try JSONDecoder().decode(Profile.self, from: data).validated())
        }
        guard data.count <= 65536, let text = String(data: data, encoding: .utf8) else {
            throw AudioFailure(message: "EQ text must be UTF-8 and smaller than 64 KB.")
        }
        return .profile(try AutoEQ.parse(text, name: name).validated())
    }
}
