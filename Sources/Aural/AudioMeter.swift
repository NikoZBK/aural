import Combine

struct AudioMeterReading: Equatable {
    var peak: Float = 0
    var reductionDB: Float = 0
    var inputPeak: Float = 0
    var postEQPeak: Float = 0
}

/// Metering changes only the meter, not the document, menus, or editor layout.
@MainActor final class AudioMeter: ObservableObject {
    private struct State: Equatable {
        var reading = AudioMeterReading()
        var overloadPeak: Float = 0
        var heldReductionDB: Float = 0
    }
    @Published private var state = State()
    var reading: AudioMeterReading { state.reading }
    var peak: Float { reading.peak }
    var reductionDB: Float { reading.reductionDB }
    var overloadPeak: Float { state.overloadPeak }
    var heldReductionDB: Float { state.heldReductionDB }

    func update(_ value: Float, reductionDB: Float = 0) {
        update(AudioMeterReading(peak: value, reductionDB: reductionDB))
    }
    func update(_ value: AudioMeterReading) {
        var next = state
        next.reading = value
        if value.postEQPeak > 1 { next.overloadPeak = max(next.overloadPeak, value.postEQPeak) }
        next.heldReductionDB = max(next.heldReductionDB, value.reductionDB)
        publish(next)
    }

    func clearLiveReduction() {
        var next = state
        next.reading.reductionDB = 0
        publish(next)
    }

    func resetHolds() {
        var next = state
        next.overloadPeak = 0
        next.heldReductionDB = 0
        publish(next)
    }

    func clear() { publish(State()) }

    private func publish(_ next: State) {
        if state != next { state = next }
    }
}
