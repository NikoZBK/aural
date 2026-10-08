import Foundation

// Parses the complete file before the caller changes any profile or audio state.
enum AutoEQ {
    static func export(_ profile: Profile) throws -> String {
        _ = try profile.validated()
        guard profile.stereoSettings == StereoSettings() else {
            throw AudioFailure(message: "Equalizer APO text export cannot preserve Aural's stereo effects. Reset Stereo & delay before exporting EQ text, or save a preset and use Back up presets to preserve the complete configuration.")
        }
        // Use the same fixed-band conversion as the filter editor.
        let parametric = try ParametricDraft(profile).profile()
        guard let filters = parametric.filters else {
            throw AudioFailure(message: "Could not prepare EQ filters for copying.")
        }
        var lines = ["Preamp: \(parametric.preamp) dB"]
        var channel = ImportedFilter.Channel.stereo
        for (index, filter) in filters.enumerated() {
            if filter.effectiveChannel != channel {
                channel = filter.effectiveChannel
                lines.append("Channel: \(channel.rawValue)")
            }
            let gain = filter.kind.usesGain ? " Gain \(filter.gain) dB" : ""
            lines.append("Filter \(index + 1): \(filter.enabled ? "ON" : "OFF") \(filter.kind.rawValue) Fc \(filter.frequency) Hz\(gain) Q \(filter.q)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func parse(_ text: String, name: String) throws -> Profile {
        guard text.utf8.count <= 65536 else { throw AudioFailure(message: "The profile exceeds the 64 KB limit.") }
        let number = #"([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?)"#
        let preampPattern = try NSRegularExpression(pattern: "^Preamp:\\s*" + number + "\\s+dB$", options: [.caseInsensitive])
        let filterPattern = try NSRegularExpression(pattern: "^Filter\\s+(\\d+):\\s+(ON|OFF)\\s+(PK|LSC|HSC)\\s+Fc\\s+" + number + "\\s+Hz\\s+Gain\\s+" + number + "\\s+dB\\s+Q\\s+" + number + "$", options: [.caseInsensitive])
        let passPattern = try NSRegularExpression(pattern: "^Filter\\s+(\\d+):\\s+(ON|OFF)\\s+(LPQ|HPQ|BP|NO|AP)\\s+Fc\\s+" + number + "\\s+Hz\\s+Q\\s+" + number + "$", options: [.caseInsensitive])
        var filters: [ImportedFilter] = [], preamp: Double?, identifiers = Set<Int>()
        var channel = ImportedFilter.Channel.stereo
        // Windows exports use CRLF, which CharacterSet.newlines otherwise splits
        // twice and incorrectly counts as two lines in import diagnostics.
        let withoutBOM = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let content = withoutBOM.replacingOccurrences(of: "\r\n", with: "\n")
        for (index, original) in content.components(separatedBy: .newlines).enumerated() {
            let line = String(original.prefix(while: { $0 != "#" })).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            func failure(_ message: String) -> AudioFailure { AudioFailure(message: "Line \(index + 1): \(message)") }
            func groups(_ expression: NSRegularExpression) -> [String]? {
                guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
                return (1..<match.numberOfRanges).map { String(line[Range(match.range(at: $0), in: line)!]) }
            }
            if line.lowercased().hasPrefix("graphiceq:") {
                throw failure("GraphicEQ curves are not supported. Download AutoEQ's ParametricEQ.txt or FixedBandEQ.txt export instead.")
            }
            if line.lowercased().hasPrefix("channel:") {
                let target = line.dropFirst("Channel:".count).trimmingCharacters(in: .whitespaces).uppercased()
                guard let next = ImportedFilter.Channel(rawValue: target) else {
                    throw failure("Supported channel targets are ALL, L, or R. Surround channels and routing expressions are not supported.")
                }
                channel = next
            } else if let fields = groups(preampPattern) {
                guard channel == .stereo else { throw failure("Per-channel Preamp commands are not supported in text import. Place the master Preamp before Channel commands, then use Stereo & delay for channel trims.") }
                guard preamp == nil, let value = Double(fields[0]), value.isFinite, (-60...24).contains(value) else {
                    throw failure("Use one Preamp line with a value between −60 and +24 dB.")
                }
                preamp = value
            } else if let fields = groups(filterPattern) ?? groups(passPattern).map({ [$0[0], $0[1], $0[2], $0[3], "0", $0[4]] }) {
                guard let id = Int(fields[0]), id > 0, identifiers.insert(id).inserted else { throw failure("Filter numbers must be positive and unique.") }
                guard let kind = ImportedFilter.Kind(rawValue: fields[2].uppercased()),
                      let frequency = Double(fields[3]), let gain = Double(fields[4]), let q = Double(fields[5]) else {
                    throw failure("Invalid filter parameters.")
                }
                var filter = ImportedFilter(kind: kind, frequency: frequency, gain: gain, q: q, enabled: fields[1].uppercased() == "ON")
                filter.channel = channel == .stereo ? nil : channel
                do { try filter.validate() } catch { throw failure(error.localizedDescription) }
                filters.append(filter)
                guard filters.count <= Profile.maxFilters else { throw failure("At most \(Profile.maxFilters) filters are supported.") }
            } else {
                throw failure("Unsupported or malformed setting. Expected Preamp, Channel ALL/L/R, or a supported Filter with Fc and Q (and Gain for peaks/shelves). Unsupported commands are not applied.")
            }
        }
        return try Profile(preamp: preamp ?? 0, filters: filters, sourceName: name).validated()
    }
}
