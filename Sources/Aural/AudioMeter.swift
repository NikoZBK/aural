import Combine

struct AudioMeterReading: Equatable {
    var peak: Float = 0
    var reductionDB: Float = 0
}

/// Metering changes only the meter, not the document, menus, or editor layout.
@MainActor final class AudioMeter: ObservableObject {
    @Published private(set) var reading = AudioMeterReading()
    var peak: Float { reading.peak }
    var reductionDB: Float { reading.reductionDB }

    func update(_ value: Float, reductionDB: Float = 0) {
        update(AudioMeterReading(peak: value, reductionDB: reductionDB))
    }
    func update(_ value: AudioMeterReading) {
        if reading != value { reading = value }
    }
}
