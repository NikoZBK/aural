import Foundation

// Parses the complete file before the caller changes any profile or audio state.
enum AutoEQ {
    /// Equalizer APO has no mid/side channels: Copy routes mid into the left slot and
    /// side into the right, where Channel L and R filter them, and a second Copy decodes.
    /// Each assignment reads the audio from before its line.
    static let midSideEncode = "Copy: L=0.5*L+0.5*R R=0.5*L+-0.5*R"
    static let midSideDecode = "Copy: L=L+R R=L+-1*R"

    static func export(_ profile: Profile) throws -> String {
        _ = try profile.validated()
        guard profile.stereoSettings == StereoSettings() else {
            throw AudioFailure(message: "Equalizer APO text export cannot preserve Aural's stereo effects. Reset Stereo & delay before exporting EQ text, or save a preset and use Back up presets to preserve the complete configuration.")
        }
        guard profile.tilt == 0 else {
            throw AudioFailure(message: "Equalizer APO text has no 6 dB/octave shelves for Aural's tilt. Set Tilt to 0 dB before exporting EQ text, or save a preset and use Back up presets to preserve it.")
        }
        // Use the same fixed-band conversion as the filter editor.
        let parametric = try ParametricDraft(profile).profile()
        guard let filters = parametric.filters else {
            throw AudioFailure(message: "Could not prepare EQ filters for copying.")
        }
        if let index = filters.firstIndex(where: { !$0.kind.usesQ }) {
            throw AudioFailure(message: "Equalizer APO text has no 6 dB/octave shelf that matches filter \(index + 1). Change it to a Low shelf or High shelf before exporting EQ text, or save a preset and use Back up presets to preserve it.")
        }
        var lines = ["Preamp: \(parametric.preamp) dB"]
        // Stereo filters act the same on left/right and mid/side, so they never switch.
        var target = "ALL", midSide = false
        for (index, filter) in filters.enumerated() {
            let channel = filter.effectiveChannel
            if channel != .stereo && channel.isMidSide != midSide {
                midSide.toggle()
                lines.append(midSide ? midSideEncode : midSideDecode)
            }
            let next = channel == .stereo ? "ALL" : channel == .left || channel == .mid ? "L" : "R"
            if next != target {
                target = next
                lines.append("Channel: \(target)")
            }
            let gain = filter.kind.usesGain ? " Gain \(filter.gain) dB" : ""
            lines.append("Filter \(index + 1): \(filter.enabled ? "ON" : "OFF") \(filter.kind.rawValue) Fc \(filter.frequency) Hz\(gain) Q \(filter.q)")
        }
        if midSide { lines.append(midSideDecode) }
        return lines.joined(separator: "\n") + "\n"
    }

    static func parse(_ text: String, name: String) throws -> Profile {
        guard text.utf8.count <= 65536 else { throw AudioFailure(message: "The profile exceeds the 64 KB limit.") }
        let number = #"([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?)"#
        let preampPattern = try NSRegularExpression(pattern: "^Preamp:\\s*" + number + "\\s+dB$", options: [.caseInsensitive])
        let filterPattern = try NSRegularExpression(pattern: "^Filter\\s+(\\d+):\\s+(ON|OFF)\\s+(PK|LSC|HSC)\\s+Fc\\s+" + number + "\\s+Hz\\s+Gain\\s+" + number + "\\s+dB\\s+Q\\s+" + number + "$", options: [.caseInsensitive])
        let passPattern = try NSRegularExpression(pattern: "^Filter\\s+(\\d+):\\s+(ON|OFF)\\s+(LPQ|HPQ|BP|NO|AP)\\s+Fc\\s+" + number + "\\s+Hz\\s+Q\\s+" + number + "$", options: [.caseInsensitive])
        var filters: [ImportedFilter] = [], preamp: Double?, identifiers = Set<Int>()
        // The selected Channel target, and after a mid/side Copy the factor that
        // scaled mid and side, which the decoding Copy must undo.
        var channel = ImportedFilter.Channel.stereo, midSideScale: Double?, midSideLine = 0
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
                guard ["ALL", "L", "R"].contains(target), let next = ImportedFilter.Channel(rawValue: target) else {
                    throw failure("Supported channel targets are ALL, L, or R. Surround channels and routing expressions are not supported.")
                }
                channel = next
            } else if line.lowercased().hasPrefix("copy:") {
                guard let scale = midSideCopy(line.dropFirst("Copy:".count)) else {
                    throw failure("Only Copy commands that convert left/right to mid/side and back are supported, such as \(midSideEncode) and \(midSideDecode).")
                }
                if let encoded = midSideScale {
                    guard abs(2 * encoded * scale - 1) < 1e-3 else {
                        throw failure("This Copy does not convert the mid/side Copy on line \(midSideLine) back to left/right.")
                    }
                    midSideScale = nil
                } else {
                    midSideScale = scale
                    midSideLine = index + 1
                }
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
                switch channel {
                case .left: filter.channel = midSideScale == nil ? .left : .mid
                case .right: filter.channel = midSideScale == nil ? .right : .side
                default: filter.channel = nil
                }
                do { try filter.validate() } catch { throw failure(error.localizedDescription) }
                filters.append(filter)
                guard filters.count <= Profile.maxFilters else { throw failure("At most \(Profile.maxFilters) filters are supported.") }
            } else {
                throw failure("Unsupported or malformed setting. Expected Preamp, Channel ALL/L/R, a mid/side Copy, or a supported Filter with Fc and Q (and Gain for peaks/shelves). Unsupported commands are not applied.")
            }
        }
        if midSideScale != nil {
            throw AudioFailure(message: "Line \(midSideLine): This mid/side Copy is never converted back to left/right. Add \(midSideDecode) after the mid and side filters.")
        }
        return try Profile(preamp: preamp ?? 0, filters: filters, sourceName: name).validated()
    }

    /// The scale k of a Copy that sets L = k·(L + R) and R = k·(L − R) from the audio
    /// before it, which both encodes mid/side (k = 0.5) and decodes it (k = 1). Nil for any other routing.
    private static func midSideCopy(_ text: Substring) -> Double? {
        let number = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?"#
        guard let term = try? NSRegularExpression(pattern: "^(?:(" + number + ")(dB)?\\*)?(L|R)$", options: [.caseInsensitive]) else { return nil }
        var rows: [String: [Double]] = [:]
        for assignment in text.split(whereSeparator: \.isWhitespace) {
            let sides = assignment.split(separator: "=", omittingEmptySubsequences: false)
            guard sides.count == 2 else { return nil }
            let target = sides[0].uppercased()
            guard ["L", "R"].contains(target), rows[target] == nil else { return nil }
            var row = [0.0, 0.0]
            // Terms are joined by +; a negative factor is written +-. A dB factor is a level, never negative.
            for part in sides[1].split(separator: "+", omittingEmptySubsequences: false) {
                let part = String(part)
                guard let match = term.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)) else { return nil }
                func group(_ index: Int) -> String? { Range(match.range(at: index), in: part).map { String(part[$0]) } }
                let value = group(1).flatMap(Double.init) ?? 1
                row[group(3)!.uppercased() == "L" ? 0 : 1] += group(2) == nil ? value : pow(10, value / 20)
            }
            rows[target] = row
        }
        guard let left = rows["L"], let right = rows["R"] else { return nil }
        let k = left[0]
        let tolerance = 1e-3 * abs(k)
        guard k.isFinite, k > 0, abs(left[1] - k) <= tolerance, abs(right[0] - k) <= tolerance, abs(right[1] + k) <= tolerance else { return nil }
        return k
    }
}
