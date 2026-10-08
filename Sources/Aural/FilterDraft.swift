import Foundation

struct FilterDraft: Identifiable, Equatable {
    let id = UUID()
    var kind: ImportedFilter.Kind
    var frequency: String
    var gain: String
    var q: String
    var enabled: Bool
    var channel: ImportedFilter.Channel

    init(_ filter: ImportedFilter = ImportedFilter(kind: .peak, frequency: 1000, gain: 0, q: 1.4, enabled: true)) {
        kind = filter.kind; frequency = String(filter.frequency)
        gain = String(filter.gain); q = String(filter.q); enabled = filter.enabled
        channel = filter.effectiveChannel
    }

    func filter(row: Int) throws -> ImportedFilter {
        guard let hz = Double(frequency.trimmingCharacters(in: .whitespaces)),
              let db = kind.usesGain ? Double(gain.trimmingCharacters(in: .whitespaces)) : 0,
              let quality = Double(q.trimmingCharacters(in: .whitespaces)) else {
            throw AudioFailure(message: "Filter \(row): enter numbers for frequency, gain, and Q (use a decimal point).")
        }
        let result = ImportedFilter(kind: kind, frequency: hz, gain: db, q: quality, enabled: enabled, channel: channel == .stereo ? nil : channel)
        do { try result.validate() }
        catch { throw AudioFailure(message: "Filter \(row): \(error.localizedDescription)") }
        return result
    }
}

struct ParametricDraft: Equatable {
    var filters: [FilterDraft]
    var preamp: String
    private let original: Profile

    init(_ profile: Profile) {
        original = profile
        preamp = String(profile.preamp)
        filters = (profile.filters ?? zip(GraphicEQ.frequencies, GraphicEQ.bandGains(for: profile.gains)).map {
            ImportedFilter(kind: .peak, frequency: $0.0, gain: $0.1, q: GraphicEQ.q, enabled: true)
        }).map { FilterDraft($0) }
    }

    mutating func duplicateFilter(_ id: UUID) throws {
        guard filters.count < Profile.maxFilters else { throw AudioFailure(message: "At most \(Profile.maxFilters) filters are supported.") }
        guard let index = filters.firstIndex(where: { $0.id == id }) else {
            throw AudioFailure(message: "The filter no longer exists.")
        }
        let original = filters[index]
        var copy = FilterDraft()
        copy.kind = original.kind; copy.frequency = original.frequency
        copy.gain = original.gain; copy.q = original.q; copy.enabled = original.enabled
        copy.channel = original.channel
        filters.insert(copy, at: index + 1)
    }

    mutating func moveFilter(_ id: UUID, by offset: Int) throws {
        guard let index = filters.firstIndex(where: { $0.id == id }),
              offset == -1 || offset == 1, filters.indices.contains(index + offset) else {
            throw AudioFailure(message: "The filter cannot move in that direction.")
        }
        filters.swapAt(index, index + offset)
    }

    func profile() throws -> Profile {
        guard let db = Double(preamp.trimmingCharacters(in: .whitespaces)), db.isFinite, (-60...24).contains(db) else {
            throw AudioFailure(message: "Preamp must be a number from −60 to +24 dB.")
        }
        var result = original
        result.filters = try filters.enumerated().map { try $0.element.filter(row: $0.offset + 1) }
        result.preamp = db
        result.sourceName = "Custom parametric EQ"
        return try result.validated()
    }
}

// Bounded history is local to an editing session; applying remains explicit.
struct EditHistory<Value> {
    private var undoValues: [Value] = []
    private var redoValues: [Value] = []
    var canUndo: Bool { !undoValues.isEmpty }
    var canRedo: Bool { !redoValues.isEmpty }
    mutating func record(_ value: Value) {
        undoValues.append(value)
        if undoValues.count > 100 { undoValues.removeFirst() }
        redoValues.removeAll()
    }
    mutating func undo(_ current: Value) throws -> Value {
        guard let previous = undoValues.popLast() else { throw AudioFailure(message: "There are no edits to undo.") }
        redoValues.append(current)
        return previous
    }
    mutating func redo(_ current: Value) throws -> Value {
        guard let next = redoValues.popLast() else { throw AudioFailure(message: "There are no edits to redo.") }
        undoValues.append(current)
        return next
    }
}
