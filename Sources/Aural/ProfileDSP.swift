import DSP

/// Profiles and sample rates are validated before reaching UI analysis.
/// The C sampler shares the engine's coefficients and avoids rebuilding them per point.
func sampledResponse(_ frequencies: [Double], rate: Double, filters: [EQFilter], preamp: Double, channel: UInt32) -> [Double] {
    var values = [Double](repeating: 0, count: frequencies.count)
    let accepted = eq_response_filters_channel_samples(frequencies, UInt32(frequencies.count), rate,
                                                       filters, UInt32(filters.count), preamp, channel, &values)
    precondition(accepted, "Response sampling requires a valid rate/channel/preamp and at most \(Profile.maxFilters) filters.")
    return values
}

extension Profile {
    var dspStereo: EQStereo {
        let settings = stereoSettings
        return EQStereo(leftTrimDB: settings.leftTrimDB, rightTrimDB: settings.rightTrimDB,
                        balance: settings.balance, width: settings.width, crossfeed: settings.crossfeed,
                        leftDelayMS: settings.leftDelayMS, rightDelayMS: settings.rightDelayMS,
                        invertLeft: settings.invertLeft, invertRight: settings.invertRight, mono: settings.mono,
                        swapChannels: settings.swapChannels)
    }

    func dspFilters(rate: Double) -> [EQFilter] {
        if let filters {
            return filters.map { filter in
                let type: UInt32
                switch filter.kind {
                case .peak: type = UInt32(EQFilterPeak)
                case .lowShelf: type = UInt32(EQFilterLowShelf)
                case .highShelf: type = UInt32(EQFilterHighShelf)
                case .lowPass: type = UInt32(EQFilterLowPass)
                case .highPass: type = UInt32(EQFilterHighPass)
                case .bandPass: type = UInt32(EQFilterBandPass)
                case .notch: type = UInt32(EQFilterNotch)
                case .allPass: type = UInt32(EQFilterAllPass)
                }
                let channel: UInt32
                switch filter.effectiveChannel {
                case .stereo: channel = UInt32(EQChannelStereo)
                case .left: channel = UInt32(EQChannelLeft)
                case .right: channel = UInt32(EQChannelRight)
                }
                return EQFilter(frequency: filter.frequency, gain: filter.gain, q: filter.q, type: type, disabled: !filter.enabled, channel: channel)
            }
        }
        // Solve against the engine's own response, so each slider is exact at this rate.
        func band(_ index: Int, gain: Double) -> EQFilter {
            EQFilter(frequency: GraphicEQ.frequencies[index], gain: gain, q: GraphicEQ.q, type: UInt32(EQFilterPeak),
                     disabled: GraphicEQ.frequencies[index] >= rate * 0.49, channel: UInt32(EQChannelStereo))
        }
        let bandGains = GraphicEQ.bandGains(for: gains, rate: rate) { index, gain, frequency in
            var filter = band(index, gain: gain)
            return eq_response_filters(frequency, rate, &filter, 1, 0)
        }
        return bandGains.indices.map { band($0, gain: bandGains[$0]) }
    }
    // This is the EQ/preamp response, before stereo processing. The default
    // returns the louder channel so automatic headroom covers both channels.
    func response(_ frequency: Double, rate: Double, preamp: Double? = nil, channel: ImportedFilter.Channel = .stereo) -> Double {
        let filters = dspFilters(rate: rate)
        let target: UInt32
        switch channel {
        case .stereo: target = UInt32(EQChannelStereo)
        case .left: target = UInt32(EQChannelLeft)
        case .right: target = UInt32(EQChannelRight)
        }
        return eq_response_filters_channel(frequency, rate, filters, UInt32(filters.count), preamp ?? self.preamp, target)
    }
}
