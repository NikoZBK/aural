// Simulator-only UI harness. Never included in the iOS 27 audio application.
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
    @Published var bypass = false
    let running = false, preparing = false, connected = false
    let route = "UI preview"
    let status = "Offline interface preview"
    let report = "This simulator build previews the interface. It does not receive or play audio. Validate audio on an iOS 27 device using the Aural target."
    init(idleTimeout: TimeInterval?, routeName: String) {}
    func configure(_ next: Configuration) throws {}
    func prepare() { failure = "This is the offline UI preview. Audio routing is available in the Aural build on your iPhone." }
    func stop() {}
}
