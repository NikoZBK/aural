import Foundation

struct FilterDraft: Identifiable {
    let id = UUID()
    var kind: ImportedFilter.Kind
    var frequency: String
    var gain: String
    var q: String
    var enabled: Bool

    init(_ filter: ImportedFilter = ImportedFilter(kind: .peak, frequency: 1000, gain: 0, q: 1.4, enabled: true)) {
        kind = filter.kind; frequency = String(filter.frequency)
        gain = String(filter.gain); q = String(filter.q); enabled = filter.enabled
    }

    func filter(row: Int) throws -> ImportedFilter {
        guard let hz = Double(frequency.trimmingCharacters(in: .whitespaces)),
              let db = Double(gain.trimmingCharacters(in: .whitespaces)),
              let quality = Double(q.trimmingCharacters(in: .whitespaces)) else {
            throw AudioFailure(message: "Filter \(row): enter numbers for frequency, gain, and Q (use a decimal point).")
        }
        let result = ImportedFilter(kind: kind, frequency: hz, gain: db, q: quality, enabled: enabled)
        do { try result.validate() }
        catch { throw AudioFailure(message: "Filter \(row): \(error.localizedDescription)") }
        return result
    }
}

struct ParametricDraft {
    var filters: [FilterDraft]
    var preamp: String
    private let original: Profile

    init(_ profile: Profile) {
        original = profile
        preamp = String(profile.preamp)
        let frequencies: [Double] = [31.5,63,125,250,500,1000,2000,4000,8000,16000]
        filters = (profile.filters ?? zip(frequencies, profile.gains).map {
            ImportedFilter(kind: .peak, frequency: $0.0, gain: $0.1, q: 1.4, enabled: true)
        }).map { FilterDraft($0) }
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
