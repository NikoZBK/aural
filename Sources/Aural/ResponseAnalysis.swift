import Foundation
import DSP

/// Both traces, or the first or second alone: left and right, or mid and side
/// once the EQ has Mid/Side filters.
enum ResponseChannel: String, CaseIterable {
    case both, left, right
    func label(midSide: Bool) -> String {
        switch self {
        case .both: return midSide ? "M + S" : "L + R"
        case .left: return midSide ? "M" : "L"
        case .right: return midSide ? "S" : "R"
        }
    }
    func includes(_ channel: ImportedFilter.Channel) -> Bool {
        switch channel {
        case .stereo: return true
        case .left, .mid: return self != .right
        case .right, .side: return self != .left
        }
    }
}

/// A cached EQ transfer function, using the same filter coefficients as the audio engine.
/// Stereo effects and peak protection are signal-dependent and are deliberately excluded.
struct ResponseAnalysis: Sendable {
    struct FilterTrace: Sendable {
        let index: Int
        let channel: ImportedFilter.Channel
        let values: [Double]
    }

    let frequencies: [Double]
    /// Positions of the fixed logarithmic samples in `frequencies`. They line up
    /// between analyses at the same rate, so one trace can morph into the next.
    let gridIndices: [Int]
    let left: [Double]
    let right: [Double]
    let combined: [Double]
    let filters: [FilterTrace]
    let comparisonLeft: [Double]?
    let comparisonRight: [Double]?
    let comparison: [Double]?
    let hasChannelFilters: Bool
    /// Mid/Side filters are present: the graph draws mid and side instead of left and right.
    let midSide: Bool
    /// Empty without Mid/Side filters.
    let mid: [Double]
    let side: [Double]
    let comparisonMid: [Double]?
    let comparisonSide: [Double]?
    let peak: Double
    let maximumFrequency: Double

    init(profile: Profile, rate: Double, bypass: Bool, comparisonProfile: Profile? = nil) {
        let activeFilters = profile.dspFilters(rate: rate)
        let referenceFilters = comparisonProfile?.dspFilters(rate: rate) ?? []
        let maximumFrequency = min(20000, rate * 0.49)
        self.maximumFrequency = maximumFrequency
        let span = log10(maximumFrequency / 20)
        let grid = (0...768).map { 20 * pow(10, Double($0) / 768 * span) }
        // Include exact centers so narrow peaks/notches cannot disappear between log samples.
        let frequencies = grid + (activeFilters + referenceFilters).filter {
            !$0.disabled && (20...maximumFrequency).contains($0.frequency)
        }.map(\.frequency)
        let sampledFrequencies = Array(Set(frequencies)).sorted()
        self.frequencies = sampledFrequencies
        let positions = Dictionary(sampledFrequencies.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        gridIndices = grid.compactMap { positions[$0] }
        hasChannelFilters = (activeFilters + referenceFilters).contains { !$0.disabled && $0.channel != UInt32(EQChannelStereo) }
        let midSide = (activeFilters + referenceFilters).contains { !$0.disabled && $0.channel >= UInt32(EQChannelMid) }
        self.midSide = midSide

        func sample(_ filters: [EQFilter], preamp: Double, channel: UInt32) -> [Double] {
            sampledResponse(sampledFrequencies, rate: rate, filters: filters, preamp: preamp, channel: channel)
        }
        let unity = Array(repeating: 0.0, count: sampledFrequencies.count)
        left = bypass ? unity : sample(activeFilters, preamp: profile.preamp, channel: UInt32(EQChannelLeft))
        right = bypass ? unity : sample(activeFilters, preamp: profile.preamp, channel: UInt32(EQChannelRight))
        mid = !midSide ? [] : bypass ? unity : sample(activeFilters, preamp: profile.preamp, channel: UInt32(EQChannelMid))
        side = !midSide ? [] : bypass ? unity : sample(activeFilters, preamp: profile.preamp, channel: UInt32(EQChannelSide))
        // The envelope is only for peak/headroom calculations. The graph draws L/R separately.
        // Mid and side can add up in one output, so with them it is the engine's stereo bound.
        combined = midSide && !bypass ? sample(activeFilters, preamp: profile.preamp, channel: UInt32(EQChannelStereo))
            : zip(left, right).map { max($0.0, $0.1) }
        // Tilt is not a band; it shows in the curve only.
        filters = bypass ? [] : activeFilters.dropLast(profile.tiltFilters.count).enumerated().compactMap { index, filter in
            guard !filter.disabled else { return nil }
            let channel: ImportedFilter.Channel
            switch Int(filter.channel) {
            case EQChannelLeft: channel = .left
            case EQChannelRight: channel = .right
            case EQChannelMid: channel = .mid
            case EQChannelSide: channel = .side
            default: channel = .stereo
            }
            // Alone, each filter's response is its own channel's.
            let sampleChannel = filter.channel == UInt32(EQChannelStereo) ? UInt32(EQChannelLeft) : filter.channel
            return FilterTrace(index: index, channel: channel, values: sample([filter], preamp: 0, channel: sampleChannel))
        }
        comparisonLeft = comparisonProfile.map { sample(referenceFilters, preamp: $0.preamp, channel: UInt32(EQChannelLeft)) }
        comparisonRight = comparisonProfile.map { sample(referenceFilters, preamp: $0.preamp, channel: UInt32(EQChannelRight)) }
        comparisonMid = midSide ? comparisonProfile.map { sample(referenceFilters, preamp: $0.preamp, channel: UInt32(EQChannelMid)) } : nil
        comparisonSide = midSide ? comparisonProfile.map { sample(referenceFilters, preamp: $0.preamp, channel: UInt32(EQChannelSide)) } : nil
        if let comparisonProfile, midSide {
            comparison = sample(referenceFilters, preamp: comparisonProfile.preamp, channel: UInt32(EQChannelStereo))
        } else if let comparisonLeft, let comparisonRight {
            comparison = zip(comparisonLeft, comparisonRight).map { max($0.0, $0.1) }
        } else { comparison = nil }
        peak = combined.max() ?? 0
    }

    /// The channels of the first and second traces.
    var lanes: (first: ImportedFilter.Channel, second: ImportedFilter.Channel) { midSide ? (.mid, .side) : (.left, .right) }

    func displayedChannels(channel: ResponseChannel) -> [ImportedFilter.Channel] {
        guard hasChannelFilters else { return [.stereo] }
        switch channel {
        case .both: return [lanes.first, lanes.second]
        case .left: return [lanes.first]
        case .right: return [lanes.second]
        }
    }

    /// One displayed channel's trace; Stereo is the shared trace without channel filters.
    func values(for channel: ImportedFilter.Channel) -> [Double] {
        switch channel {
        case .stereo, .left: return left
        case .right: return right
        case .mid: return mid
        case .side: return side
        }
    }

    func comparisonValues(for channel: ImportedFilter.Channel) -> [Double]? {
        switch channel {
        case .stereo, .left: return comparisonLeft
        case .right: return comparisonRight
        case .mid: return comparisonMid
        case .side: return comparisonSide
        }
    }

    func visibleFilters(channel: ResponseChannel) -> [FilterTrace] {
        filters.filter { channel.includes($0.channel) }
    }

    func scale(showFilters: Bool, channel: ResponseChannel = .both, referenceValues: [Double] = []) -> ResponseScale {
        var visibleValues = referenceValues
        if channel != .right { visibleValues += values(for: lanes.first) + (comparisonValues(for: lanes.first) ?? []) }
        if channel != .left { visibleValues += values(for: lanes.second) + (comparisonValues(for: lanes.second) ?? []) }
        if showFilters { visibleValues += visibleFilters(channel: channel).flatMap(\.values) }
        return ResponseScale(minimum: visibleValues.min() ?? 0, maximum: visibleValues.max() ?? 0)
    }
}

/// Readable dB intervals, with enough space for every visible trace and a fixed zero reference.
struct ResponseScale {
    let lower: Double
    let upper: Double
    let interval: Double

    init(minimum: Double, maximum: Double) {
        let lower = min(-12, floor((minimum - 1) / 3) * 3)
        let upper = max(12, ceil((maximum + 1) / 3) * 3)
        let magnitude = pow(10, floor(log10((upper - lower) / 6)))
        let step = [1.0, 2, 3, 6, 10].first { $0 * magnitude >= (upper - lower) / 6 } ?? 10
        interval = step * magnitude
        self.lower = floor(lower / interval) * interval
        self.upper = ceil(upper / interval) * interval
    }

    var ticks: [Double] { Array(stride(from: lower, through: upper, by: interval)) }
    func fraction(_ decibels: Double) -> Double { (upper - decibels) / (upper - lower) }
}
