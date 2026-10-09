import Foundation

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct ImportedFilter: Codable, Equatable, Sendable {
    enum Channel: String, Codable, CaseIterable, Sendable {
        /// Mid filters act on (L + R)/2 and Side filters on (L − R)/2, as in Equalizer APO's
        /// mid/side Copy routing. Aural 1.3 and earlier cannot read profiles that use them.
        case stereo = "ALL", left = "L", right = "R", mid = "M", side = "S"
        var label: String {
            switch self {
            case .stereo: return "Stereo"
            case .left: return "Left"
            case .right: return "Right"
            case .mid: return "Mid"
            case .side: return "Side"
            }
        }
        var isMidSide: Bool { self == .mid || self == .side }
    }
    enum Kind: String, Codable, CaseIterable, Sendable {
        case peak = "PK", lowShelf = "LSC", highShelf = "HSC"
        /// First-order shelves with a fixed 6 dB/octave slope. Equalizer APO text has no match for them.
        case firstOrderLowShelf = "LS1", firstOrderHighShelf = "HS1"
        case lowPass = "LPQ", highPass = "HPQ", bandPass = "BP", notch = "NO", allPass = "AP"
        var usesGain: Bool { [.peak, .lowShelf, .highShelf, .firstOrderLowShelf, .firstOrderHighShelf].contains(self) }
        var usesQ: Bool { self != .firstOrderLowShelf && self != .firstOrderHighShelf }
        var hasSlopes: Bool { self == .lowPass || self == .highPass }
        /// The label without its Equalizer APO code.
        var name: String { label.components(separatedBy: " · ")[0] }
        var label: String {
            switch self {
            case .peak: return "Peak · PK"
            case .lowShelf: return "Low shelf · LSC"
            case .highShelf: return "High shelf · HSC"
            case .firstOrderLowShelf: return "Low shelf 6 dB/oct · LS1"
            case .firstOrderHighShelf: return "High shelf 6 dB/oct · HS1"
            case .lowPass: return "Low pass · LPQ"
            case .highPass: return "High pass · HPQ"
            case .bandPass: return "Band pass · BP"
            case .notch: return "Notch · NO"
            case .allPass: return "All pass · AP"
            }
        }
    }
    /// Low- and high-pass slopes other than 12 dB/octave, which has its own Q and is nil.
    /// The others are fixed sections at the filter frequency: Butterworth slopes are 3 dB down
    /// there, and Linkwitz-Riley slopes, two Butterworth filters in a row, 6 dB. Each section
    /// takes one of the profile's filter slots. Aural 1.4 and earlier play them at 12 dB/octave.
    enum Slope: String, Codable, CaseIterable, Sendable {
        case butterworth6 = "BW6", butterworth18 = "BW18", butterworth24 = "BW24", linkwitzRiley24 = "LR24"
        case butterworth30 = "BW30", butterworth36 = "BW36", linkwitzRiley36 = "LR36"
        case butterworth42 = "BW42", butterworth48 = "BW48", linkwitzRiley48 = "LR48"
        var decibelsPerOctave: Int { Int(rawValue.dropFirst(2))! }
        var isLinkwitzRiley: Bool { rawValue.hasPrefix("LR") }
        /// A first-order section for odd Butterworth orders, then second-order sections by Q.
        var sections: (firstOrder: Bool, q: [Double]) {
            func butterworth(_ order: Int) -> [Double] {
                stride(from: order % 2 == 0 ? 1 : 2, to: order, by: 2).map { 1 / (2 * cos(Double($0) * .pi / Double(2 * order))) }
            }
            let order = decibelsPerOctave / 6
            guard isLinkwitzRiley else { return (!order.isMultiple(of: 2), butterworth(order)) }
            // Two first-order sections in a row are one second-order section with Q 0.5.
            let half = butterworth(order / 2)
            return (false, ((order / 2).isMultiple(of: 2) ? [] : [0.5]) + (half + half).sorted())
        }
        var slots: Int { sections.q.count + (sections.firstOrder ? 1 : 0) }
        /// Short, for menu buttons in filter rows.
        var name: String { "\(decibelsPerOctave) dB" + (isLinkwitzRiley ? " LR" : "") }
        var label: String {
            decibelsPerOctave == 6 ? "6 dB/oct" : "\(decibelsPerOctave) dB/oct " + (isLinkwitzRiley ? "Linkwitz-Riley" : "Butterworth")
        }
    }
    var kind: Kind
    var frequency: Double
    var gain: Double
    var q: Double
    var enabled: Bool
    var channel: Channel?
    /// Only low- and high-pass filters have one.
    var slope: Slope?
    var effectiveChannel: Channel { channel ?? .stereo }
    var shape: FilterShape {
        get { FilterShape(kind: kind, slope: slope) }
        set { kind = newValue.kind; slope = newValue.slope }
    }
    var usesQ: Bool { shape.usesQ }
    var slots: Int { shape.slots }
    static func == (lhs: ImportedFilter, rhs: ImportedFilter) -> Bool {
        lhs.kind == rhs.kind && lhs.frequency == rhs.frequency && lhs.gain == rhs.gain &&
        lhs.q == rhs.q && lhs.enabled == rhs.enabled && lhs.effectiveChannel == rhs.effectiveChannel && lhs.slope == rhs.slope
    }
    func validate() throws {
        guard frequency.isFinite, (10...22000).contains(frequency), gain.isFinite, abs(gain) <= 30,
              q.isFinite, (0.05...50).contains(q) else {
            throw AudioFailure(message: "Filter values must be 10–22000 Hz, −30 to +30 dB, and Q 0.05–50.")
        }
        guard kind.usesGain || gain == 0 else {
            throw AudioFailure(message: "Pass and notch filters do not have a gain parameter. Use preamp to adjust overall level.")
        }
        guard slope == nil || kind.hasSlopes else {
            throw AudioFailure(message: "Only low- and high-pass filters have a slope setting.")
        }
    }
}
/// A filter type as the type menus offer it: the kind, and a low- or high-pass filter's slope.
struct FilterShape: Hashable, Sendable {
    let kind: ImportedFilter.Kind
    let slope: ImportedFilter.Slope?
    init(kind: ImportedFilter.Kind, slope: ImportedFilter.Slope? = nil) {
        self.kind = kind
        self.slope = kind.hasSlopes ? slope : nil
    }
    /// The slopes a type menu offers for a kind: nil is 12 dB/octave, with Q.
    static func slopes(for kind: ImportedFilter.Kind) -> [FilterShape] {
        let slopes: [ImportedFilter.Slope?] = [.butterworth6, nil] + ImportedFilter.Slope.allCases.dropFirst().map(Optional.some)
        return slopes.map { FilterShape(kind: kind, slope: $0) }
    }
    var usesQ: Bool { kind.usesQ && slope == nil }
    var slots: Int { slope?.slots ?? 1 }
    /// Short, for menu buttons: "Low pass 24 dB LR".
    var name: String { slope.map { "\(kind.name) \($0.name)" } ?? kind.name }
    var label: String { slope.map { "\(kind.name) \($0.label)" } ?? kind.label }
    /// Why the Q field is empty.
    var fixedQHelp: String {
        slope == nil ? "This shelf has a fixed 6 dB/octave slope, so it has no Q." : "This slope has a fixed shape, so it has no Q."
    }
}
extension Array where Element == ImportedFilter {
    /// The filter slots these filters take of Profile.maxFilters.
    var slots: Int { reduce(0) { $0 + $1.slots } }
}
struct StereoSettings: Codable, Equatable, Sendable {
    var leftTrimDB = 0.0
    var rightTrimDB = 0.0
    var balance = 0.0
    var width = 1.0
    var crossfeed = 0.0
    var leftDelayMS = 0.0
    var rightDelayMS = 0.0
    var invertLeft = false
    var invertRight = false
    var mono = false
    /// Plays the left input on the right output and the right on the left.
    var swapChannels = false

    var isNeutral: Bool { self == StereoSettings() }
    func resettingListeningControls() -> Self {
        var next = self
        next.balance = 0
        next.width = 1
        next.mono = false
        next.crossfeed = 0
        return next
    }
    // A conservative peak bound; crossfeed is normalized and polarity/delay
    // cannot increase a channel's peak. Reserve this in addition to EQ headroom.
    var headroomGainDB: Double {
        let left = pow(10, leftTrimDB / 20) * (1 - max(0, balance))
        let right = pow(10, rightTrimDB / 20) * (1 + min(0, balance))
        return 20 * log10(max(left, right) * (mono ? 1 : max(1, width)))
    }
    func validate() throws {
        guard [leftTrimDB, rightTrimDB].allSatisfy({ $0.isFinite && (-24...12).contains($0) }),
              balance.isFinite, (-1...1).contains(balance),
              width.isFinite, (0...2).contains(width),
              crossfeed.isFinite, (0...1).contains(crossfeed),
              [leftDelayMS, rightDelayMS].allSatisfy({ $0.isFinite && (0...30).contains($0) }) else {
            throw AudioFailure(message: "Stereo settings must use −24 to +12 dB trims, balance −1 to +1, width 0–200%, crossfeed 0–100%, and delays 0–30 ms.")
        }
    }
}

extension StereoSettings {
    private enum CodingKeys: String, CodingKey {
        case leftTrimDB, rightTrimDB, balance, width, crossfeed, leftDelayMS, rightDelayMS, invertLeft, invertRight, mono, swapChannels
    }

    // Settings saved before the swap existed have no swapChannels key.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        leftTrimDB = try values.decode(Double.self, forKey: .leftTrimDB)
        rightTrimDB = try values.decode(Double.self, forKey: .rightTrimDB)
        balance = try values.decode(Double.self, forKey: .balance)
        width = try values.decode(Double.self, forKey: .width)
        crossfeed = try values.decode(Double.self, forKey: .crossfeed)
        leftDelayMS = try values.decode(Double.self, forKey: .leftDelayMS)
        rightDelayMS = try values.decode(Double.self, forKey: .rightDelayMS)
        invertLeft = try values.decode(Bool.self, forKey: .invertLeft)
        invertRight = try values.decode(Bool.self, forKey: .invertRight)
        mono = try values.decode(Bool.self, forKey: .mono)
        swapChannels = try values.decodeIfPresent(Bool.self, forKey: .swapChannels) ?? false
    }
}

struct AutoEQSource: Codable, Equatable, Sendable {
    let name: String
    let measurement: String
    let url: URL

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !measurement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/jaakkopasanen/AutoEq/tree/master/results/"),
              url.pathComponents.count == 9,
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else {
            throw AudioFailure(message: "The profile contains invalid AutoEQ source information.")
        }
    }
}

struct Profile: Codable, Equatable, Sendable {
    /// Filter slots: steeper low- and high-pass filters take one per section. The engine's
    /// EQMaxFilters also holds tilt, loudness compensation and solo; the bridge tests check this.
    static let maxFilters = 64
    /// Tilt pivots on 1 kHz: positive values raise the treble and lower the bass by up to that many dB.
    static let tiltRange = -6.0...6.0
    static let tiltPivot = 1000.0
    var gains = Array(repeating: 0.0, count: 10)
    var preamp = 0.0
    var filters: [ImportedFilter]?
    var sourceName: String?
    var stereo: StereoSettings?
    var autoEQSource: AutoEQSource?
    var tilt = 0.0
    var stereoSettings: StereoSettings { stereo ?? StereoSettings() }
    var preampRange: ClosedRange<Double> { filters == nil ? -24...0 : -60...24 }
    func hasSameEQ(as other: Profile) -> Bool {
        // Parametric filters replace the graphic bands. Their retained slider
        // values are inactive and need not survive an APO text round trip.
        let sameBands = filters != nil || gains == other.gains
        return sameBands && preamp == other.preamp && tilt == other.tilt && filters == other.filters && stereoSettings == other.stereoSettings
    }
    func validated() throws -> Profile {
        guard gains.count == 10, gains.allSatisfy({ $0.isFinite && abs($0) <= 12 }),
              preamp.isFinite, preampRange.contains(preamp) else {
            throw AudioFailure(message: "The profile contains invalid gain or preamp values.")
        }
        guard tilt.isFinite, Self.tiltRange.contains(tilt) else {
            throw AudioFailure(message: "Tilt must be from −6 to +6 dB.")
        }
        if let filters {
            guard !filters.isEmpty, filters.slots <= Self.maxFilters else {
                throw AudioFailure(message: "A profile must contain 1–\(Self.maxFilters) filters, and each low- or high-pass filter steeper than 12 dB/octave counts as 2–4. Disabled filters are retained but do not affect the sound.")
            }
            for filter in filters { try filter.validate() }
        }
        try stereoSettings.validate()
        try autoEQSource?.validate()
        return self
    }
}

extension Profile {
    // Aural 1.3 and earlier saved graphic sliders as raw band gains, whose overlapping
    // bands overshoot. Profiles now record that their sliders set the level at each centre.
    private enum CodingKeys: String, CodingKey {
        case gains, preamp, filters, sourceName, stereo, autoEQSource, tilt, graphicVersion
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        gains = try values.decode([Double].self, forKey: .gains)
        preamp = try values.decode(Double.self, forKey: .preamp)
        filters = try values.decodeIfPresent([ImportedFilter].self, forKey: .filters)
        sourceName = try values.decodeIfPresent(String.self, forKey: .sourceName)
        stereo = try values.decodeIfPresent(StereoSettings.self, forKey: .stereo)
        autoEQSource = try values.decodeIfPresent(AutoEQSource.self, forKey: .autoEQSource)
        tilt = try values.decodeIfPresent(Double.self, forKey: .tilt) ?? 0
        if try values.decodeIfPresent(Int.self, forKey: .graphicVersion) == nil { self = migratingLegacySliders() }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(gains, forKey: .gains)
        try values.encode(preamp, forKey: .preamp)
        try values.encodeIfPresent(filters, forKey: .filters)
        try values.encodeIfPresent(sourceName, forKey: .sourceName)
        try values.encodeIfPresent(stereo, forKey: .stereo)
        try values.encodeIfPresent(autoEQSource, forKey: .autoEQSource)
        // Untilted profiles keep the format earlier releases read.
        if tilt != 0 { try values.encode(tilt, forKey: .tilt) }
        try values.encode(2, forKey: .graphicVersion)
    }

    /// Keeps the sound of a graphic profile saved with raw band gains: each slider moves
    /// to the level that was heard at its centre. A profile that would need more than
    /// ±12 dB becomes the same ten bands as parametric filters instead.
    func migratingLegacySliders() -> Profile {
        guard filters == nil, gains.count == GraphicEQ.frequencies.count,
              gains.allSatisfy({ $0.isFinite && abs($0) <= 12 }) else { return self }
        var result = self
        if let sliders = GraphicEQ.sliders(forBandGains: gains) {
            result.gains = sliders
        } else {
            result.filters = zip(GraphicEQ.frequencies, gains).map {
                ImportedFilter(kind: .peak, frequency: $0.0, gain: $0.1, q: GraphicEQ.q, enabled: true)
            }
        }
        return result
    }
}

enum InterfaceMode: String, Codable, CaseIterable {
    case easy, professional

    var label: String {
        switch self {
        case .easy: return "Simple"
        case .professional: return "Professional"
        }
    }
}

enum AuralTheme: String, Codable, CaseIterable {
    case system, light, dark
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

enum AuralInterfaceZoom: Int, Codable, CaseIterable, Sendable {
    case smallest = 80, small = 90, actualSize = 100, large = 110, larger = 120, extraLarge = 130, largest = 140

    var scale: CGFloat { CGFloat(rawValue) / 100 }
    var increased: Self { Self(rawValue: rawValue + 10) ?? self }
    var decreased: Self { Self(rawValue: rawValue - 10) ?? self }
}

enum FilterPanelPosition: String, Codable, CaseIterable {
    case below, right
    var label: String { self == .below ? "Below graph" : "Right of graph" }
    var symbol: String { self == .below ? "rectangle.bottomthird.inset.filled" : "sidebar.right" }
}

struct Settings: Codable {
    var devices: [String: Profile] = [:]
    var presets: [String: Profile] = [:]
    var selectedUID = ""
    var startEQAutomatically: Bool?
    var peakProtectionEnabled = true
    var favoritePresets: Set<String>?
    var selectedPresets: [String: String]?
    var interfaceMode: InterfaceMode = .easy
    var theme: AuralTheme = .dark
    var interfaceZoom: AuralInterfaceZoom = .actualSize
    var filterPanelPosition: FilterPanelPosition = .below
    var followSystemOutput = false
    var matchLevels = false
    var loudness = LoudnessSettings()

    private enum CodingKeys: String, CodingKey {
        case devices, presets, selectedUID, startEQAutomatically, peakProtectionEnabled, favoritePresets, selectedPresets, interfaceMode, theme, interfaceZoom, filterPanelPosition, followSystemOutput, matchLevels, loudness
    }
}

/// Loudness compensation follows each output's volume from the reference set for it.
struct LoudnessSettings: Codable, Equatable {
    var enabled = false
    /// The listening level in phon at the reference volume.
    var referenceLevel = 80.0
    /// Output UID → the volume in dB at which music plays at `referenceLevel`.
    var referenceVolumes: [String: Double] = [:]

    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let level = try values.decodeIfPresent(Double.self, forKey: .referenceLevel) ?? 80
        referenceLevel = (70...90).contains(level) ? level : 80
        referenceVolumes = try (values.decodeIfPresent([String: Double].self, forKey: .referenceVolumes) ?? [:]).filter { $0.value.isFinite }
    }
}

extension Settings {
    private enum LegacyKeys: String, CodingKey { case interfaceStyle }
    private enum LegacyStyle: String, Decodable { case standard, liquidGlass }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        devices = try values.decode([String: Profile].self, forKey: .devices)
        presets = try values.decode([String: Profile].self, forKey: .presets)
        selectedUID = try values.decode(String.self, forKey: .selectedUID)
        startEQAutomatically = try values.decodeIfPresent(Bool.self, forKey: .startEQAutomatically)
        peakProtectionEnabled = try values.decodeIfPresent(Bool.self, forKey: .peakProtectionEnabled) ?? true
        favoritePresets = try values.decodeIfPresent(Set<String>.self, forKey: .favoritePresets)
        selectedPresets = try values.decodeIfPresent([String: String].self, forKey: .selectedPresets)
        // Keep the full controls visible for people upgrading an existing install.
        interfaceMode = try values.decodeIfPresent(InterfaceMode.self, forKey: .interfaceMode) ?? .professional
        // Preserve Aural's original appearance until a theme is explicitly chosen.
        theme = try values.decodeIfPresent(AuralTheme.self, forKey: .theme) ?? .dark
        // Validate the interface style older versions saved, then drop it: every
        // install now uses the same solid surfaces.
        // The retired key is deliberately omitted when settings are next saved.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        _ = try legacy.decodeIfPresent(LegacyStyle.self, forKey: .interfaceStyle)
        interfaceZoom = try values.decodeIfPresent(AuralInterfaceZoom.self, forKey: .interfaceZoom) ?? .actualSize
        filterPanelPosition = try values.decodeIfPresent(FilterPanelPosition.self, forKey: .filterPanelPosition) ?? .below
        followSystemOutput = try values.decodeIfPresent(Bool.self, forKey: .followSystemOutput) ?? false
        matchLevels = try values.decodeIfPresent(Bool.self, forKey: .matchLevels) ?? false
        loudness = try values.decodeIfPresent(LoudnessSettings.self, forKey: .loudness) ?? LoudnessSettings()
    }
}

// Broad listening curves, ordered from 31.5 Hz to 16 kHz.
// These are creative starting points, not headphone correction profiles.
// They sound as in Aural 1.3; the import tests derive them from its raw band gains.
extension Profile {
    static let builtInPresets: [String: Profile] = [
        "Flat": Profile(),
        "Warm": Profile(gains: [2.6,3.8,2.8,1.5,0.2,-0.2,-1.2,-1.2,-0.2,0], preamp: -5),
        "Voice": Profile(gains: [-4.6,-4.1,-2.7,-0.2,1.4,2.8,3.8,2.6,0.3,-0.9], preamp: -5),
        "Detail": Profile(gains: [0,-0.2,-1.2,-1.1,0.1,1.5,2.8,3.8,2.8,1.5], preamp: -5),
        "Bass Boost": Profile(gains: [6.1,6.8,5.5,3,0.6,0.1,0,0,0,0], preamp: -8),
        "Treble Boost": Profile(gains: [0,0,0,0.1,0.3,1.5,2.9,4.3,5.4,4.9], preamp: -7),
        "Classical": Profile(gains: [1.2,1.2,0.2,-0.2,-1.2,-1.1,0.1,1.4,2.5,2.4], preamp: -4),
        "Electronic": Profile(gains: [4.8,5.1,2.9,0.4,-0.8,0.1,1.5,2.8,3.8,2.6], preamp: -7),
        "Rock": Profile(gains: [3.4,2.7,1.2,-1.1,-2,0.1,2.6,3.8,2.8,1.5], preamp: -6),
        "Vocal": Profile(gains: [-2.4,-2.5,-1.4,0,1.4,2.6,2.6,1.4,0.1,-0.9], preamp: -4)
    ]
}
