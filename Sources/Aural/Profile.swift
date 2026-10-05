import Foundation

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct ImportedFilter: Codable, Equatable, Sendable {
    enum Channel: String, Codable, CaseIterable, Sendable {
        case stereo = "ALL", left = "L", right = "R"
        var label: String {
            switch self {
            case .stereo: return "Stereo"
            case .left: return "Left"
            case .right: return "Right"
            }
        }
    }
    enum Kind: String, Codable, CaseIterable, Sendable {
        case peak = "PK", lowShelf = "LSC", highShelf = "HSC"
        case lowPass = "LPQ", highPass = "HPQ", bandPass = "BP", notch = "NO", allPass = "AP"
        var usesGain: Bool { self == .peak || self == .lowShelf || self == .highShelf }
        var label: String {
            switch self {
            case .peak: return "Peak · PK"
            case .lowShelf: return "Low shelf · LSC"
            case .highShelf: return "High shelf · HSC"
            case .lowPass: return "Low pass · LPQ"
            case .highPass: return "High pass · HPQ"
            case .bandPass: return "Band pass · BP"
            case .notch: return "Notch · NO"
            case .allPass: return "All pass · AP"
            }
        }
    }
    var kind: Kind
    var frequency: Double
    var gain: Double
    var q: Double
    var enabled: Bool
    var channel: Channel?
    var effectiveChannel: Channel { channel ?? .stereo }
    static func == (lhs: ImportedFilter, rhs: ImportedFilter) -> Bool {
        lhs.kind == rhs.kind && lhs.frequency == rhs.frequency && lhs.gain == rhs.gain &&
        lhs.q == rhs.q && lhs.enabled == rhs.enabled && lhs.effectiveChannel == rhs.effectiveChannel
    }
    func validate() throws {
        guard frequency.isFinite, (10...22000).contains(frequency), gain.isFinite, abs(gain) <= 30,
              q.isFinite, (0.05...50).contains(q) else {
            throw AudioFailure(message: "Filter values must be 10–22000 Hz, −30 to +30 dB, and Q 0.05–50.")
        }
        guard kind.usesGain || gain == 0 else {
            throw AudioFailure(message: "Pass and notch filters do not have a gain parameter. Use preamp to adjust overall level.")
        }
    }
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
    var gains = Array(repeating: 0.0, count: 10)
    var preamp = 0.0
    var filters: [ImportedFilter]?
    var sourceName: String?
    var stereo: StereoSettings?
    var autoEQSource: AutoEQSource?
    var stereoSettings: StereoSettings { stereo ?? StereoSettings() }
    var preampRange: ClosedRange<Double> { filters == nil ? -24...0 : -60...24 }
    func hasSameEQ(as other: Profile) -> Bool {
        // Parametric filters replace the graphic bands. Their retained slider
        // values are inactive and need not survive an APO text round trip.
        let sameBands = filters != nil || gains == other.gains
        return sameBands && preamp == other.preamp && filters == other.filters && stereoSettings == other.stereoSettings
    }
    func validated() throws -> Profile {
        guard gains.count == 10, gains.allSatisfy({ $0.isFinite && abs($0) <= 12 }),
              preamp.isFinite, preampRange.contains(preamp) else {
            throw AudioFailure(message: "The profile contains invalid gain or preamp values.")
        }
        if let filters {
            guard (1...32).contains(filters.count) else {
                throw AudioFailure(message: "A profile must contain 1–32 filters. Disabled filters are retained but do not affect the sound.")
            }
            for filter in filters { try filter.validate() }
        }
        try stereoSettings.validate()
        try autoEQSource?.validate()
        return self
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

enum AuralInterfaceStyle: String, Codable, CaseIterable {
    case standard, liquidGlass
    var label: String {
        switch self {
        case .standard: return "Standard"
        case .liquidGlass: return "Liquid Glass"
        }
    }
    static var liquidGlassSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
    func usesLiquidGlass(supported: Bool = liquidGlassSupported, reduceTransparency: Bool, increasedContrast: Bool) -> Bool {
        self == .liquidGlass && supported && !reduceTransparency && !increasedContrast
    }
}

enum AuralInterfaceZoom: Int, Codable, CaseIterable, Sendable {
    case smallest = 80, small = 90, actualSize = 100, large = 110, larger = 120, extraLarge = 130, largest = 140

    var scale: CGFloat { CGFloat(rawValue) / 100 }
    var increased: Self { Self(rawValue: rawValue + 10) ?? self }
    var decreased: Self { Self(rawValue: rawValue - 10) ?? self }
}

struct Settings: Codable {
    var devices: [String: Profile] = [:]
    var presets: [String: Profile] = [:]
    var selectedUID = ""
    var startEQAutomatically: Bool?
    var favoritePresets: Set<String>?
    var selectedPresets: [String: String]?
    var interfaceMode: InterfaceMode = .easy
    var theme: AuralTheme = .dark
    var interfaceStyle: AuralInterfaceStyle = .standard
    var interfaceZoom: AuralInterfaceZoom = .actualSize

    private enum CodingKeys: String, CodingKey {
        case devices, presets, selectedUID, startEQAutomatically, favoritePresets, selectedPresets, interfaceMode, theme, interfaceStyle, interfaceZoom
    }
}

extension Settings {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        devices = try values.decode([String: Profile].self, forKey: .devices)
        presets = try values.decode([String: Profile].self, forKey: .presets)
        selectedUID = try values.decode(String.self, forKey: .selectedUID)
        startEQAutomatically = try values.decodeIfPresent(Bool.self, forKey: .startEQAutomatically)
        favoritePresets = try values.decodeIfPresent(Set<String>.self, forKey: .favoritePresets)
        selectedPresets = try values.decodeIfPresent([String: String].self, forKey: .selectedPresets)
        // Keep the full controls visible for people upgrading an existing install.
        interfaceMode = try values.decodeIfPresent(InterfaceMode.self, forKey: .interfaceMode) ?? .professional
        // Preserve Aural's original appearance until a theme is explicitly chosen.
        theme = try values.decodeIfPresent(AuralTheme.self, forKey: .theme) ?? .dark
        interfaceStyle = try values.decodeIfPresent(AuralInterfaceStyle.self, forKey: .interfaceStyle) ?? .standard
        interfaceZoom = try values.decodeIfPresent(AuralInterfaceZoom.self, forKey: .interfaceZoom) ?? .actualSize
    }
}

// Broad listening curves, ordered from 31.5 Hz to 16 kHz.
// These are creative starting points, not headphone correction profiles.
extension Profile {
    static let builtInPresets: [String: Profile] = [
        "Flat": Profile(),
        "Warm": Profile(gains: [2,3,2,1,0,0,-1,-1,0,0], preamp: -5),
        "Voice": Profile(gains: [-4,-3,-2,0,1,2,3,2,0,-1], preamp: -5),
        "Detail": Profile(gains: [0,0,-1,-1,0,1,2,3,2,1], preamp: -5),
        "Bass Boost": Profile(gains: [5,5,4,2,0,0,0,0,0,0], preamp: -8),
        "Treble Boost": Profile(gains: [0,0,0,0,0,1,2,3,4,4], preamp: -7),
        "Classical": Profile(gains: [1,1,0,0,-1,-1,0,1,2,2], preamp: -4),
        "Electronic": Profile(gains: [4,4,2,0,-1,0,1,2,3,2], preamp: -7),
        "Rock": Profile(gains: [3,2,1,-1,-2,0,2,3,2,1], preamp: -6),
        "Vocal": Profile(gains: [-2,-2,-1,0,1,2,2,1,0,-1], preamp: -4)
    ]
}
