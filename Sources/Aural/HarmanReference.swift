import Foundation

enum HarmanTarget: String, CaseIterable, Sendable {
    case overEar2018 = "harman-over-ear-2018"
    case inEar2019 = "harman-in-ear-2019"

    var label: String { self == .overEar2018 ? "Harman over-ear 2018" : "Harman in-ear 2019" }
    var sourceURL: URL {
        AutoEQCatalog.rawResultsURL.deletingLastPathComponent().appendingPathComponent("targets")
            .appendingPathComponent(self == .overEar2018 ? "Harman over-ear 2018.csv" : "Harman in-ear 2019.csv")
    }
    static func suggested(for profile: Profile) -> Self {
        let collection = profile.autoEQSource?.url.deletingLastPathComponent().lastPathComponent ?? ""
        return collection.localizedCaseInsensitiveContains("in-ear") ? .inEar2019 : .overEar2018
    }
}

/// An acoustic target, not an EQ transfer function or a measured headphone response.
/// Preserve the published samples; only subtract the log-interpolated 1 kHz value.
struct HarmanReference: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        let frequency: Double
        let decibels: Double
    }
    let target: HarmanTarget
    let samples: [Sample]

    init(csv: String, target: HarmanTarget) throws {
        guard csv.utf8.count <= 65536 else { throw AudioFailure(message: "The Harman reference exceeds the 64 KB limit.") }
        let lines = csv.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        guard lines.first == "frequency,raw" else { throw AudioFailure(message: "The Harman reference has an unsupported CSV header.") }
        var values: [Sample] = []
        for (index, line) in lines.dropFirst().enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count == 2, let frequency = Double(columns[0]), let decibels = Double(columns[1]),
                  frequency.isFinite, (10...24000).contains(frequency), decibels.isFinite, abs(decibels) <= 120,
                  values.last.map({ frequency > $0.frequency }) ?? true else {
                throw AudioFailure(message: "Harman reference line \(index + 2) contains invalid or unordered samples.")
            }
            values.append(Sample(frequency: frequency, decibels: decibels))
        }
        guard values.count >= 2, let first = values.first, let last = values.last,
              first.frequency <= 20, last.frequency >= 19000,
              let anchor = Self.interpolate(1000, in: values) else {
            throw AudioFailure(message: "The Harman reference does not cover the audible range and 1 kHz normalization point.")
        }
        self.target = target
        samples = values.map { Sample(frequency: $0.frequency, decibels: $0.decibels - anchor) }
    }

    static func load(_ target: HarmanTarget) throws -> Self {
        var url = Bundle.main.url(forResource: target.rawValue, withExtension: "csv", subdirectory: "Targets")
        #if SWIFT_PACKAGE
        if url == nil { url = Bundle.module.url(forResource: target.rawValue, withExtension: "csv", subdirectory: "Targets") }
        #endif
        guard let url else { throw AudioFailure(message: "The bundled \(target.label) reference is missing. Reinstall Aural to restore it.") }
        let data = try Data(contentsOf: url)
        guard data.count <= 65536, let csv = String(data: data, encoding: .utf8) else {
            throw AudioFailure(message: "The bundled Harman reference is too large or is not UTF-8 text.")
        }
        return try Self(csv: csv, target: target)
    }

    func decibels(at frequency: Double) -> Double? { Self.interpolate(frequency, in: samples) }

    func plottedSamples(maximumFrequency: Double) -> [Sample] {
        let visible = samples.filter { (20...maximumFrequency).contains($0.frequency) }
        // Include a sample-rate boundary, but never extrapolate beyond the
        // published target (whose last sample is just below 20 kHz).
        if let value = decibels(at: maximumFrequency), visible.last?.frequency != maximumFrequency {
            return visible + [Sample(frequency: maximumFrequency, decibels: value)]
        }
        return visible
    }

    private static func interpolate(_ frequency: Double, in samples: [Sample]) -> Double? {
        guard frequency.isFinite, let first = samples.first, let last = samples.last,
              (first.frequency...last.frequency).contains(frequency) else { return nil }
        var lower = 0, upper = samples.count - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if samples[middle].frequency <= frequency { lower = middle } else { upper = middle }
        }
        let fraction = log(frequency / samples[lower].frequency) / log(samples[upper].frequency / samples[lower].frequency)
        return samples[lower].decibels + fraction * (samples[upper].decibels - samples[lower].decibels)
    }
}

actor HarmanReferenceLibrary {
    static let shared = HarmanReferenceLibrary()
    private var references: [HarmanTarget: HarmanReference] = [:]

    func reference(_ target: HarmanTarget) throws -> HarmanReference {
        try Task.checkCancellation()
        if let reference = references[target] { return reference }
        let reference = try HarmanReference.load(target)
        references[target] = reference
        return reference
    }
}
