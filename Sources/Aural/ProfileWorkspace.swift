import Foundation

struct ProfileSnapshot: Equatable {
    var profile: Profile
    var selectedPresetName: String?

    var title: String { selectedPresetName ?? profile.sourceName ?? "Custom EQ" }
}

enum ComparisonSlot: String, CaseIterable, Identifiable {
    case a = "A", b = "B"
    var id: Self { self }
    var other: Self { self == .a ? .b : .a }
}

// Each output gets an independent editing session. Snapshots include preset identity,
// so undo and comparison never relabel a recalled profile as an unrelated preset.
struct ProfileWorkspace {
    private struct Entry {
        var snapshot: ProfileSnapshot
        let label: String
        let comparisonSlot: ComparisonSlot
    }
    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []
    private var gestureID: UUID?
    private var recordedGestureID: UUID?
    private var gestureLabel: String?
    private var comparisons: [ComparisonSlot: ProfileSnapshot] = [:]
    private(set) var comparisonSlot: ComparisonSlot = .a

    var canUndo: Bool { !undoEntries.isEmpty }
    var hasActiveGesture: Bool { gestureID != nil }
    var canRedo: Bool { !redoEntries.isEmpty }
    var undoLabel: String { undoEntries.last?.label ?? "EQ change" }
    var redoLabel: String { redoEntries.last?.label ?? "EQ change" }
    var comparisonAvailable: Bool { comparisons[.a] != nil && comparisons[.b] != nil }
    var otherComparison: ProfileSnapshot? { comparisons[comparisonSlot.other] }

    func comparisonTitle(for slot: ComparisonSlot) -> String {
        comparisons[slot]?.title ?? "Capture current EQ"
    }

    mutating func beginGesture(label: String) {
        gestureID = UUID()
        gestureLabel = label
    }

    mutating func endGesture() {
        gestureID = nil
        recordedGestureID = nil
        gestureLabel = nil
    }

    mutating func record(before: ProfileSnapshot, after: ProfileSnapshot, label: String,
                         previousComparisonSlot: ComparisonSlot? = nil, coalescing: Bool = true) {
        // Presets, templates, and other discrete actions are separate edits even
        // if SwiftUI has not yet delivered a disappearing slider's end callback.
        if !coalescing { endGesture() }
        guard before != after else { return }
        if gestureID == nil || recordedGestureID != gestureID {
            undoEntries.append(Entry(snapshot: before, label: gestureLabel ?? label,
                                     comparisonSlot: previousComparisonSlot ?? comparisonSlot))
            if undoEntries.count > 100 { undoEntries.removeFirst() }
        }
        recordedGestureID = gestureID
        redoEntries.removeAll()
        updateComparison(after)
    }

    mutating func undo(current: ProfileSnapshot) throws -> ProfileSnapshot {
        guard let entry = undoEntries.popLast() else {
            throw AudioFailure(message: "There are no EQ changes to undo.")
        }
        endGesture()
        redoEntries.append(Entry(snapshot: current, label: entry.label, comparisonSlot: comparisonSlot))
        updateComparison(current)
        comparisonSlot = entry.comparisonSlot
        updateComparison(entry.snapshot)
        return entry.snapshot
    }

    mutating func redo(current: ProfileSnapshot) throws -> ProfileSnapshot {
        guard let entry = redoEntries.popLast() else {
            throw AudioFailure(message: "There are no EQ changes to redo.")
        }
        endGesture()
        undoEntries.append(Entry(snapshot: current, label: entry.label, comparisonSlot: comparisonSlot))
        updateComparison(current)
        comparisonSlot = entry.comparisonSlot
        updateComparison(entry.snapshot)
        return entry.snapshot
    }

    mutating func captureComparison(_ current: ProfileSnapshot) {
        endGesture()
        comparisons = [.a: current, .b: current]
        comparisonSlot = .a
    }

    mutating func selectComparison(_ slot: ComparisonSlot, current: ProfileSnapshot) throws -> ProfileSnapshot {
        guard comparisonAvailable, let target = comparisons[slot] else {
            throw AudioFailure(message: "Capture the current EQ before comparing A and B.")
        }
        guard slot != comparisonSlot else { return current }
        endGesture()
        comparisons[comparisonSlot] = current
        comparisonSlot = slot
        return target
    }

    mutating func copyComparisonToOther(_ current: ProfileSnapshot) throws {
        guard comparisonAvailable else {
            throw AudioFailure(message: "Capture the current EQ before copying a comparison.")
        }
        comparisons[comparisonSlot] = current
        comparisons[comparisonSlot.other] = current
    }

    mutating func updateComparison(_ snapshot: ProfileSnapshot) {
        if comparisonAvailable { comparisons[comparisonSlot] = snapshot }
    }

    mutating func renamePreset(_ old: String, to new: String?) {
        for index in undoEntries.indices where undoEntries[index].snapshot.selectedPresetName == old {
            undoEntries[index].snapshot.selectedPresetName = new
        }
        for index in redoEntries.indices where redoEntries[index].snapshot.selectedPresetName == old {
            redoEntries[index].snapshot.selectedPresetName = new
        }
        for slot in ComparisonSlot.allCases where comparisons[slot]?.selectedPresetName == old {
            comparisons[slot]?.selectedPresetName = new
        }
    }
}

enum ProfileTools {
    static let graphicFrequencies: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let thirdOctaveFrequencies: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500,
        630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000,
        10000, 12500, 16000, 20000
    ]

    static func parametric(_ profile: Profile) throws -> Profile {
        var result = try profile.validated()
        if result.filters == nil {
            result.filters = zip(graphicFrequencies, result.gains).map {
                ImportedFilter(kind: .peak, frequency: $0.0, gain: $0.1, q: 1.4, enabled: true)
            }
        }
        return result
    }

    static func graphicTemplate(bands: Int, preserving profile: Profile) throws -> Profile {
        guard bands == 10 || bands == 31 else {
            throw AudioFailure(message: "Choose the 10-band or 31-band graphic template.")
        }
        var result = profile
        result.gains = Array(repeating: 0, count: 10)
        result.preamp = 0
        result.sourceName = "\(bands)-band graphic EQ"
        let q = 1 / (pow(2, 1.0 / 6) - pow(2, -1.0 / 6))
        result.filters = bands == 10 ? nil : thirdOctaveFrequencies.map {
            ImportedFilter(kind: .peak, frequency: $0, gain: 0, q: q, enabled: true)
        }
        return try result.validated()
    }

    static func transformGains(_ profile: Profile, scale: Double, offset: Double) throws -> Profile {
        guard scale.isFinite, offset.isFinite else {
            throw AudioFailure(message: "Gain scale and offset must be finite numbers.")
        }
        var result = try profile.validated()
        if var filters = result.filters {
            for index in filters.indices where filters[index].kind.usesGain {
                filters[index].gain = filters[index].gain * scale + offset
            }
            result.filters = filters
        } else {
            result.gains = result.gains.map { $0 * scale + offset }
        }
        do { return try result.validated() }
        catch { throw AudioFailure(message: "The gain transformation exceeds the allowed band range. \(error.localizedDescription)") }
    }

    static func shiftFrequencies(_ profile: Profile, octaves: Double) throws -> Profile {
        guard octaves.isFinite, pow(2, octaves).isFinite, pow(2, octaves) > 0 else {
            throw AudioFailure(message: "Frequency shift must be a finite number of octaves.")
        }
        if octaves == 0 { return try profile.validated() }
        var result = try parametric(profile)
        let multiplier = pow(2, octaves)
        result.filters = result.filters?.map {
            var filter = $0
            filter.frequency *= multiplier
            return filter
        }
        do { return try result.validated() }
        catch { throw AudioFailure(message: "The frequency shift moves a filter outside 10–22000 Hz. Choose a smaller shift.") }
    }

    static func updateFilter(_ profile: Profile, at index: Int, with filter: ImportedFilter) throws -> Profile {
        var result = try parametric(profile)
        guard var filters = result.filters, filters.indices.contains(index) else {
            throw AudioFailure(message: "The filter no longer exists.")
        }
        try filter.validate()
        filters[index] = filter
        result.filters = filters
        return try result.validated()
    }

    static func duplicateFilter(_ profile: Profile, at index: Int) throws -> Profile {
        var result = try parametric(profile)
        guard var filters = result.filters, filters.indices.contains(index) else {
            throw AudioFailure(message: "The filter no longer exists.")
        }
        guard filters.count < Profile.maxFilters else { throw AudioFailure(message: "At most \(Profile.maxFilters) filters are supported.") }
        filters.insert(filters[index], at: index + 1)
        result.filters = filters
        return try result.validated()
    }

    static func deleteFilter(_ profile: Profile, at index: Int) throws -> Profile {
        var result = try parametric(profile)
        guard var filters = result.filters, filters.indices.contains(index) else {
            throw AudioFailure(message: "The filter no longer exists.")
        }
        guard filters.count > 1 else { throw AudioFailure(message: "Keep at least one filter, or choose a flat graphic template.") }
        filters.remove(at: index)
        result.filters = filters
        return try result.validated()
    }

    static func addFilter(_ profile: Profile) throws -> Profile {
        var result = try parametric(profile)
        guard var filters = result.filters, filters.count < Profile.maxFilters else {
            throw AudioFailure(message: "At most \(Profile.maxFilters) filters are supported.")
        }
        filters.append(ImportedFilter(kind: .peak, frequency: 1000, gain: 0, q: 1.4, enabled: true))
        result.filters = filters
        return try result.validated()
    }
}
