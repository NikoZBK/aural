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
        // Channel delays have Delay commands; the other stereo effects have no equivalent.
        var effects = profile.stereoSettings
        let delays = [("L", effects.leftDelayMS), ("R", effects.rightDelayMS)]
        effects.leftDelayMS = 0
        effects.rightDelayMS = 0
        guard effects == StereoSettings() else {
            throw AudioFailure(message: "Equalizer APO text export cannot preserve Aural's stereo effects other than channel delays. Reset them in Stereo & delay before exporting EQ text, or save a preset and use Back up presets to preserve the complete configuration.")
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
            lines.append("Filter \(index + 1): \(filter.enabled ? "ON" : "OFF") \(filter.kind.rawValue) Fc \(apoFrequencyText(filter.frequency)) Hz\(gain) Q \(filter.q)")
        }
        if midSide { lines.append(midSideDecode) }
        // Aural delays the channels after every filter.
        for (channel, delay) in delays where delay > 0 {
            if channel != target {
                target = channel
                lines.append("Channel: \(target)")
            }
            lines.append("Delay: \(delay) ms")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func parse(_ text: String, name: String) throws -> Profile {
        guard text.utf8.count <= 65536 else { throw AudioFailure(message: "The profile exceeds the 64 KB limit.") }
        let number = #"([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?)"#
        let preampPattern = try NSRegularExpression(pattern: "^Preamp:\\s*" + number + "\\s*dB$", options: [.caseInsensitive])
        let filterPattern = try NSRegularExpression(pattern: "^Filter(?:\\s*(\\d+))?\\s*:\\s*(ON|OFF)\\s+([A-Za-z][A-Za-z0-9]*)(.*)$", options: [.caseInsensitive])
        let delayPattern = try NSRegularExpression(pattern: "^Delay:\\s*" + number + "\\s*(ms|samples)$", options: [.caseInsensitive])
        let missingColonPattern = try NSRegularExpression(pattern: #"^(?:Filter\s*\d*\s+(?:ON|OFF)\s|(?:Preamp|Delay)\s+[-+.\d]|Channel\s+(?:ALL|L|R)$)"#, options: [.caseInsensitive])
        var filters: [ImportedFilter] = [], preamp: Double?, identifiers = Set<Int>()
        // The selected Channel target, and after a mid/side Copy the factor that
        // scaled mid and side, which the decoding Copy must undo.
        var channel = ImportedFilter.Channel.stereo, midSideScale: Double?, midSideLine = 0
        // Left and right delays add up; Aural applies them after every filter.
        var delays = [0.0, 0.0]
        // Windows exports use CRLF, which CharacterSet.newlines otherwise splits
        // twice and incorrectly counts as two lines in import diagnostics.
        let withoutBOM = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let content = withoutBOM.replacingOccurrences(of: "\r\n", with: "\n")
        for (index, original) in content.components(separatedBy: .newlines).enumerated() {
            let line = String(original.prefix(while: { $0 != "#" })).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Like Equalizer APO, accept a comma as the decimal mark in numeric commands.
            let decimal = line.replacingOccurrences(of: ",", with: ".")
            func failure(_ message: String) -> AudioFailure { AudioFailure(message: "Line \(index + 1): \(message)") }
            func groups(_ expression: NSRegularExpression) -> [String?]? {
                guard let match = expression.firstMatch(in: decimal, range: NSRange(decimal.startIndex..., in: decimal)) else { return nil }
                return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: decimal).map { String(decimal[$0]) } }
            }
            // Equalizer APO ignores lines without a command, such as Room EQ Wizard's file header,
            // and the header's metadata commands. A command missing its colon is still an error.
            guard let colon = line.firstIndex(of: ":") else {
                if groups(missingColonPattern) != nil { throw failure("This command is missing its colon.") }
                continue
            }
            if ["dated", "notes", "equaliser"].contains(line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()) { continue }
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
                    guard abs(delays[0] - delays[1]) < 1e-9 else {
                        throw failure("Aural delays the channels after all filters, so a left/right delay difference must come after the mid/side filters.")
                    }
                    midSideScale = scale
                    midSideLine = index + 1
                }
            } else if let fields = groups(preampPattern) {
                guard channel == .stereo else { throw failure("Per-channel Preamp commands are not supported in text import. Place the master Preamp before Channel commands, then use Stereo & delay for channel trims.") }
                guard preamp == nil, let value = fields[0].flatMap(Double.init), value.isFinite, (-60...24).contains(value) else {
                    throw failure("Use one Preamp line with a value between −60 and +24 dB.")
                }
                preamp = value
            } else if let fields = groups(delayPattern) {
                guard fields[1]?.lowercased() == "ms" else {
                    throw failure("Delays in samples depend on the sample rate. Give the delay in ms instead.")
                }
                guard midSideScale == nil || channel == .stereo else {
                    throw failure("Delaying only the mid or side signal is not supported.")
                }
                guard let value = fields[0].flatMap(Double.init), value.isFinite, value >= 0 else { throw failure("Delays must be 0 ms or longer.") }
                if channel != .right { delays[0] += value }
                if channel != .left { delays[1] += value }
                guard delays.allSatisfy({ $0 <= 30 }) else { throw failure("Each channel can be delayed by at most 30 ms in total.") }
            } else if let fields = groups(filterPattern) {
                if let number = fields[0] {
                    guard let id = Int(number), id > 0, identifiers.insert(id).inserted else { throw failure("Filter numbers must be positive and unique.") }
                }
                let parsed: ImportedFilter?
                do { parsed = try filter(type: fields[2]!, parameters: fields[3] ?? "", enabled: fields[1]!.uppercased() == "ON") }
                catch { throw failure(error.localizedDescription) }
                // None marks an unused slot, as in Room EQ Wizard exports.
                guard var filter = parsed else { continue }
                switch channel {
                case .left: filter.channel = midSideScale == nil ? .left : .mid
                case .right: filter.channel = midSideScale == nil ? .right : .side
                default: filter.channel = nil
                }
                do { try filter.validate() } catch { throw failure(error.localizedDescription) }
                filters.append(filter)
                guard filters.count <= Profile.maxFilters else { throw failure("At most \(Profile.maxFilters) filters are supported.") }
            } else {
                throw failure("Unsupported or malformed setting. Expected Preamp, Channel ALL/L/R, a mid/side Copy, Delay in ms, or a Filter. Unsupported commands are not applied.")
            }
        }
        if midSideScale != nil {
            throw AudioFailure(message: "Line \(midSideLine): This mid/side Copy is never converted back to left/right. Add \(midSideDecode) after the mid and side filters.")
        }
        var stereo: StereoSettings?
        if delays != [0, 0] {
            stereo = StereoSettings()
            stereo?.leftDelayMS = delays[0]
            stereo?.rightDelayMS = delays[1]
        }
        return try Profile(preamp: preamp ?? 0, filters: filters, sourceName: name, stereo: stereo).validated()
    }

    private static let filterTypes: [String: ImportedFilter.Kind] = [
        "PK": .peak, "PEQ": .peak, "MODAL": .peak, "LP": .lowPass, "LPQ": .lowPass, "HP": .highPass, "HPQ": .highPass,
        "BP": .bandPass, "LS": .lowShelf, "LSC": .lowShelf, "HS": .highShelf, "HSC": .highShelf, "NO": .notch, "AP": .allPass,
    ]

    /// Converts one Equalizer APO filter to Aural's matched designs, or nil for a None placeholder.
    /// The defaults for an omitted Q, the shelf slope and corner frequency follow Equalizer APO.
    private static func filter(type name: String, parameters: String, enabled: Bool) throws -> ImportedFilter? {
        let type = name.uppercased()
        if type == "NONE" { return nil }
        guard let kind = filterTypes[type] else {
            if type == "IIR" { throw AudioFailure(message: "IIR filters with raw coefficients are not supported.") }
            throw AudioFailure(message: "Unsupported filter type \(name). Supported types are PK, PEQ, Modal, LP, LPQ, HP, HPQ, BP, LS, LSC, HS, HSC, NO, AP, and None.")
        }
        guard let clauses = filterClauses(parameters), clauses["T60"] == nil || type == "MODAL" else {
            throw AudioFailure(message: "Malformed filter parameters. Expected Fc in Hz, Gain in dB for peaks and shelves, and Q, BW Oct, or a shelf slope in dB.")
        }
        func value(_ key: String) throws -> Double? {
            guard let text = clauses[key] else { return nil }
            guard let value = Double(text), value.isFinite else { throw AudioFailure(message: "Invalid \(key) value \(text).") }
            return value
        }
        guard let fc = clauses["Fc"], var frequency = apoFrequency(fc) else {
            throw AudioFailure(message: "Filters need a frequency, such as Fc 1000 Hz.")
        }
        let isShelf = kind == .lowShelf || kind == .highShelf
        guard let gain = try value("Gain") ?? (kind.usesGain ? nil : 0) else {
            throw AudioFailure(message: "Peak and shelf filters need a gain, such as Gain -3 dB.")
        }
        let q = try value("Q"), bandwidth = try value("BW"), slope = try value("slope")
        guard slope == nil || isShelf else { throw AudioFailure(message: "Only shelves take a slope in dB.") }
        guard [q, bandwidth, slope].compactMap({ $0 }).count <= 1 else { throw AudioFailure(message: "Give only one of Q, BW Oct, or a shelf slope.") }
        guard bandwidth == nil || !isShelf else { throw AudioFailure(message: "Shelves take a Q or a slope in dB, not BW Oct.") }
        guard [q, bandwidth, slope].allSatisfy({ ($0 ?? 1) > 0 }) else { throw AudioFailure(message: "Q, BW Oct, and slopes must be greater than 0.") }
        // Aural's filters follow the analog prototypes, whose bandwidth in octaves sets Q directly.
        var filterQ = q ?? bandwidth.map { pow(2, $0 / 2) / (pow(2, $0) - 1) }
        // Shelf slope S, where 12 dB is S = 1.
        var shelfSlope = slope.map { $0 / 12 }
        if filterQ == nil && shelfSlope == nil {
            switch kind {
            case .peak, .allPass: throw AudioFailure(message: "Peak and all-pass filters need a Q or a BW Oct value.")
            case .notch: filterQ = 30
            case .lowShelf, .highShelf: shelfSlope = 0.9
            default: filterQ = 0.5.squareRoot()
            }
        }
        let a = pow(10, gain / 40)
        // LS and HS with a Q or slope give the corner frequency, which Equalizer APO moves to the shelf's center.
        if isShelf && !type.hasSuffix("C") && (q != nil || slope != nil) {
            let s = shelfSlope ?? 1 / ((1 / (filterQ! * filterQ!) - 2) / (a + 1 / a) + 1)
            let factor = pow(10, abs(gain) / 80 / s)
            frequency = kind == .lowShelf ? frequency * factor : frequency / factor
        }
        if let shelfSlope {
            let inverseSquare = (a + 1 / a) * (1 / shelfSlope - 1) + 2
            guard inverseSquare > 0 else { throw AudioFailure(message: "This shelf slope is too steep for its gain.") }
            filterQ = 1 / inverseSquare.squareRoot()
        }
        return ImportedFilter(kind: kind, frequency: frequency, gain: gain, q: filterQ!, enabled: enabled)
    }

    private static let clausePatterns: [(String, NSRegularExpression)] = {
        let number = #"([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?)"#
        return [("Fc", #"\s+Fc\s*([-+0-9.eE\u00A0]+)\s*H\s*z"#), ("Gain", #"\s+Gain\s*"# + number + #"\s*dB"#),
                ("Q", #"\s+Q\s*"# + number), ("BW", #"\s+BW\s+Oct\s*"# + number),
                ("T60", #"\s+T60\s+target\s*"# + number + #"\s*ms"#)].map {
            ($0.0, try! NSRegularExpression(pattern: "^" + $0.1 + #"(?=\s|$)"#, options: [.caseInsensitive]))
        }
    }()
    private static let slopePattern = try! NSRegularExpression(pattern: #"^\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?)\s*dB(?=\s|$)"#, options: [.caseInsensitive])

    /// The clauses after a filter type, in any order, each at most once. Nil for anything else.
    private static func filterClauses(_ text: String) -> [String: String]? {
        var values: [String: String] = [:]
        var rest = text[...]
        func read(_ expression: NSRegularExpression) -> String? {
            let string = String(rest)
            guard let match = expression.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else { return nil }
            rest = rest.dropFirst(string[Range(match.range, in: string)!].count)
            return String(string[Range(match.range(at: 1), in: string)!])
        }
        // A shelf slope directly follows the type, as in LSC 12dB.
        if let slope = read(slopePattern) { values["slope"] = slope }
        clauses: while !rest.allSatisfy(\.isWhitespace) {
            for (key, pattern) in clausePatterns {
                guard let value = read(pattern) else { continue }
                guard values.updateValue(value, forKey: key) == nil else { return nil }
                continue clauses
            }
            return nil
        }
        return values
    }

    /// Equalizer APO drops non-breaking spaces from a frequency and, for Room EQ Wizard's
    /// thousands separators, reads one with exactly three decimals and five characters or more in kHz.
    private static func apoFrequency(_ text: String) -> Double? {
        let digits = Array(text.replacingOccurrences(of: "\u{00A0}", with: ""))
        guard let value = Double(String(digits)), value.isFinite else { return nil }
        let isThousands = digits.count >= 5 && !digits.contains("e") && !digits.contains("E") && digits[digits.count - 4] == "."
        return isThousands ? value * 1000 : value
    }

    /// Writes a frequency that Equalizer APO cannot mistake for thousands.
    static func apoFrequencyText(_ frequency: Double) -> String {
        let text = "\(frequency)"
        return apoFrequency(text) == frequency ? text : text + "0"
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
