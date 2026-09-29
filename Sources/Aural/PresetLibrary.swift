import Foundation

struct PresetBackup: Codable {
    var version = 1
    var presets: [String: Profile]
    var favorites: Set<String>?

    static func decode(_ data: Data) throws -> PresetBackup {
        guard data.count <= 4 * 1024 * 1024 else { throw AudioFailure(message: "Preset backups must be smaller than 4 MB.") }
        let backup = try JSONDecoder().decode(Self.self, from: data)
        guard backup.version == 1 else { throw AudioFailure(message: "This preset backup requires a different version of Aural.") }
        guard backup.presets.count <= 1000 else { throw AudioFailure(message: "A backup can contain at most 1,000 presets.") }
        for (name, profile) in backup.presets {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AudioFailure(message: "The backup contains an empty preset name.")
            }
            _ = try profile.validated()
        }
        let known = Set(backup.presets.keys).union(Profile.builtInPresets.keys)
        guard (backup.favorites ?? []).isSubset(of: known) else {
            throw AudioFailure(message: "The backup refers to a missing favorite preset.")
        }
        return backup
    }
}

extension Settings {
    func preset(named name: String) -> Profile? {
        Profile.builtInPresets[name] ?? presets[name]
    }

    func selectedPresetName(forOutput uid: String) -> String? {
        guard let name = selectedPresets?[uid], preset(named: name) != nil else { return nil }
        return name
    }

    mutating func migratePresetSelections() {
        guard selectedPresets == nil else { return }
        var selections: [String: String] = [:]
        let names = Set(Profile.builtInPresets.keys).union(presets.keys)
        for (uid, profile) in devices {
            // Imported profiles retain their origin after a preamp adjustment.
            if let name = profile.sourceName, let original = preset(named: name),
               profile.gains == original.gains, profile.filters == original.filters {
                selections[uid] = name
                continue
            }
            let matches = names.filter { preset(named: $0)?.hasSameEQ(as: profile) == true }
            if matches.count == 1 { selections[uid] = matches.first }
        }
        selectedPresets = selections
    }

    mutating func setSelectedPreset(_ name: String?, forOutput uid: String) throws {
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AudioFailure(message: "Select an output before choosing a preset.")
        }
        if let name {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  preset(named: name) != nil else {
                throw AudioFailure(message: "The preset no longer exists.")
            }
        }
        var selections = selectedPresets ?? [:]
        selections[uid] = name
        selectedPresets = selections
    }

    func availablePresetName(_ base: String) -> String {
        var name = base, suffix = 2
        while presets[name] != nil || Profile.builtInPresets[name] != nil {
            name = "\(base) (\(suffix))"; suffix += 1
        }
        return name
    }

    mutating func renamePreset(_ old: String, to proposed: String) throws {
        guard let profile = presets[old] else { throw AudioFailure(message: "The preset no longer exists.") }
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AudioFailure(message: "Enter a preset name.") }
        guard name == old || (presets[name] == nil && Profile.builtInPresets[name] == nil) else {
            throw AudioFailure(message: "That preset name is already in use.")
        }
        presets.removeValue(forKey: old)
        presets[name] = profile
        if favoritePresets?.remove(old) != nil { favoritePresets?.insert(name) }
        selectedPresets = selectedPresets?.mapValues { $0 == old ? name : $0 }
    }

    mutating func deletePreset(_ name: String) throws {
        guard presets[name] != nil else { throw AudioFailure(message: "The preset no longer exists.") }
        presets.removeValue(forKey: name)
        favoritePresets?.remove(name)
        selectedPresets = selectedPresets?.filter { $0.value != name }
    }

    mutating func toggleFavorite(_ name: String) throws {
        guard presets[name] != nil || Profile.builtInPresets[name] != nil else {
            throw AudioFailure(message: "The preset no longer exists.")
        }
        var favorites = favoritePresets ?? []
        if !favorites.insert(name).inserted { favorites.remove(name) }
        favoritePresets = favorites
    }

    mutating func duplicatePreset(_ name: String) throws {
        guard let profile = presets[name] ?? Profile.builtInPresets[name] else {
            throw AudioFailure(message: "The preset no longer exists.")
        }
        presets[availablePresetName(name + " copy")] = profile
    }

    mutating func mergePresets(_ backup: PresetBackup) {
        var favorites = favoritePresets ?? []
        for name in backup.presets.keys.sorted() {
            let restored = availablePresetName(name)
            presets[restored] = backup.presets[name]
            if backup.favorites?.contains(name) == true { favorites.insert(restored) }
        }
        favorites.formUnion((backup.favorites ?? []).intersection(Profile.builtInPresets.keys))
        favoritePresets = favorites
    }
}
