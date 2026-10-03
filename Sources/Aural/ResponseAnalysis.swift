import Foundation
import DSP

enum ResponseChannel: String, CaseIterable {
    case both, left, right
    var label: String {
        switch self {
        case .both: return "L + R"
        case .left: return "L"
        case .right: return "R"
        }
    }
    func includes(_ channel: ImportedFilter.Channel) -> Bool {
        self == .both || channel == .stereo || (self == .left && channel == .left) || (self == .right && channel == .right)
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
    let left: [Double]
    let right: [Double]
    let combined: [Double]
    let filters: [FilterTrace]
    let comparisonLeft: [Double]?
    let comparisonRight: [Double]?
    let comparison: [Double]?
    let hasChannelFilters: Bool
    let peak: Double
    let maximumFrequency: Double

    init(profile: Profile, rate: Double, bypass: Bool, comparisonProfile: Profile? = nil) {
        let activeFilters = profile.dspFilters(rate: rate)
        let referenceFilters = comparisonProfile?.dspFilters(rate: rate) ?? []
        let maximumFrequency = min(20000, rate * 0.49)
        self.maximumFrequency = maximumFrequency
        let span = log10(maximumFrequency / 20)
        var frequencies = (0...768).map { 20 * pow(10, Double($0) / 768 * span) }
        // Include exact centers so narrow peaks/notches cannot disappear between log samples.
        frequencies += (activeFilters + referenceFilters).filter {
            !$0.disabled && (20...maximumFrequency).contains($0.frequency)
        }.map(\.frequency)
        let sampledFrequencies = Array(Set(frequencies)).sorted()
        self.frequencies = sampledFrequencies
        hasChannelFilters = (activeFilters + referenceFilters).contains { !$0.disabled && $0.channel != UInt32(EQChannelStereo) }

        func sample(_ filters: [EQFilter], preamp: Double, channel: UInt32) -> [Double] {
            sampledResponse(sampledFrequencies, rate: rate, filters: filters, preamp: preamp, channel: channel)
        }
        let unity = Array(repeating: 0.0, count: sampledFrequencies.count)
        left = bypass ? unity : sample(activeFilters, preamp: profile.preamp, channel: UInt32(EQChannelLeft))
        right = bypass ? unity : sample(activeFilters, preamp: profile.preamp, channel: UInt32(EQChannelRight))
        // The envelope is only for peak/headroom calculations. The graph draws L/R separately.
        combined = zip(left, right).map { max($0.0, $0.1) }
        filters = bypass ? [] : activeFilters.enumerated().compactMap { index, filter in
            guard !filter.disabled else { return nil }
            let channel: ImportedFilter.Channel = filter.channel == UInt32(EQChannelLeft) ? .left
                : filter.channel == UInt32(EQChannelRight) ? .right : .stereo
            let sampleChannel = filter.channel == UInt32(EQChannelRight) ? UInt32(EQChannelRight) : UInt32(EQChannelLeft)
            return FilterTrace(index: index, channel: channel, values: sample([filter], preamp: 0, channel: sampleChannel))
        }
        comparisonLeft = comparisonProfile.map { sample(referenceFilters, preamp: $0.preamp, channel: UInt32(EQChannelLeft)) }
        comparisonRight = comparisonProfile.map { sample(referenceFilters, preamp: $0.preamp, channel: UInt32(EQChannelRight)) }
        if let comparisonLeft, let comparisonRight {
            comparison = zip(comparisonLeft, comparisonRight).map { max($0.0, $0.1) }
        } else { comparison = nil }
        peak = combined.max() ?? 0
    }

    func displayedChannels(channel: ResponseChannel) -> [ImportedFilter.Channel] {
        guard hasChannelFilters else { return [.stereo] }
        switch channel {
        case .both: return [.left, .right]
        case .left: return [.left]
        case .right: return [.right]
        }
    }

    func visibleFilters(channel: ResponseChannel) -> [FilterTrace] {
        filters.filter { channel.includes($0.channel) }
    }

    func scale(showFilters: Bool, channel: ResponseChannel = .both) -> ResponseScale {
        var visibleValues: [Double] = []
        if channel != .right { visibleValues += left + (comparisonLeft ?? []) }
        if channel != .left { visibleValues += right + (comparisonRight ?? []) }
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
