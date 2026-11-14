// Host-only control boundary. PCM is separately tested through the actual C renderer.
import Foundation
import Combine
import DSP

@MainActor
final class ProbeAudio: ObservableObject {
    struct Configuration {
        var filters: [EQFilter]
        var preamp: Double
        var stereo: EQStereo
        var bypassGain: Double
        var peakProtection: Bool
    }
    @Published var failure: String?
    var bypass = false
    var running = false
    var starts = 0
    var stops = 0
    var configuration: Configuration?
    var rejectNext = false
    init(idleTimeout: TimeInterval?, routeName: String) {}
    func configure(_ next: Configuration) throws {
        if rejectNext { rejectNext = false; throw AudioFailure(message: "Test engine rejection") }
        configuration = next
    }
    func prepare() { starts += 1; running = true }
    func stop() { stops += 1; running = false }
}
