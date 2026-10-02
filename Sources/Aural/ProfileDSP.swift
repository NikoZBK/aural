import DSP

extension Profile {
    var dspStereo: EQStereo {
        let settings = stereoSettings
        return EQStereo(leftTrimDB: settings.leftTrimDB, rightTrimDB: settings.rightTrimDB,
                        balance: settings.balance, width: settings.width, crossfeed: settings.crossfeed,
                        leftDelayMS: settings.leftDelayMS, rightDelayMS: settings.rightDelayMS,
                        invertLeft: settings.invertLeft, invertRight: settings.invertRight, mono: settings.mono)
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
        let frequencies: [Double] = [31.5,63,125,250,500,1000,2000,4000,8000,16000]
        return zip(frequencies, gains).map { EQFilter(frequency: $0.0, gain: $0.1, q: 1.4, type: UInt32(EQFilterPeak), disabled: $0.0 >= rate * 0.49, channel: UInt32(EQChannelStereo)) }
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
