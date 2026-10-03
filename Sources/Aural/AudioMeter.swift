import Combine

/// Metering changes only the meter, not the document, menus, or editor layout.
@MainActor final class AudioMeter: ObservableObject {
    @Published private(set) var peak: Float = 0

    func update(_ value: Float) {
        if peak != value { peak = value }
    }
}
