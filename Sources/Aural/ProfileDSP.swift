import DSP

extension Profile {
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
                return EQFilter(frequency: filter.frequency, gain: filter.gain, q: filter.q, type: type, disabled: !filter.enabled)
            }
        }
        let frequencies: [Double] = [31.5,63,125,250,500,1000,2000,4000,8000,16000]
        return zip(frequencies, gains).map { EQFilter(frequency: $0.0, gain: $0.1, q: 1.4, type: UInt32(EQFilterPeak), disabled: $0.0 >= rate * 0.49) }
    }
    func response(_ frequency: Double, rate: Double, preamp: Double? = nil) -> Double {
        let filters = dspFilters(rate: rate)
        return eq_response_filters(frequency, rate, filters, UInt32(filters.count), preamp ?? self.preamp)
    }
}
