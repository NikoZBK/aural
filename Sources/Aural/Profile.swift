import Foundation

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct ImportedFilter: Codable, Equatable {
    enum Kind: String, Codable { case peak = "PK", lowShelf = "LSC", highShelf = "HSC" }
    var kind: Kind
    var frequency: Double
    var gain: Double
    var q: Double
    var enabled: Bool
    func validate() throws {
        guard frequency.isFinite, (10...22000).contains(frequency), gain.isFinite, abs(gain) <= 30,
              q.isFinite, (0.05...50).contains(q) else {
            throw AudioFailure(message: "Filter values must be 10–22000 Hz, −30 to +30 dB, and Q 0.05–50.")
        }
    }
}
struct Profile: Codable, Equatable {
    var gains = Array(repeating: 0.0, count: 10)
    var preamp = 0.0
    var filters: [ImportedFilter]?
    var sourceName: String?
    var preampRange: ClosedRange<Double> { filters == nil ? -24...0 : -60...24 }
    func validated() throws -> Profile {
        guard gains.count == 10, gains.allSatisfy({ $0.isFinite && abs($0) <= 12 }),
              preamp.isFinite, preampRange.contains(preamp) else {
            throw AudioFailure(message: "The profile contains invalid gain or preamp values.")
        }
        if let filters {
            guard (1...32).contains(filters.count), filters.contains(where: \.enabled) else {
                throw AudioFailure(message: "A profile must contain 1–32 filters, with at least one enabled.")
            }
            for filter in filters { try filter.validate() }
        }
        return self
    }
}

struct Settings: Codable {
    var devices: [String: Profile] = [:]
    var presets: [String: Profile] = [:]
    var selectedUID = ""
    var startEQAutomatically: Bool?
}
