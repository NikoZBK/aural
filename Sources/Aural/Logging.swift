import OSLog
import Foundation

/// Local diagnostics only. Never log from the real-time audio callback.
enum AuralLog {
    static let audio = Logger(subsystem: "local.aural.equalizer", category: "AudioRoute")
    static let lifecycle = Logger(subsystem: "local.aural.equalizer", category: "AudioLifecycle")

    static func describe(_ failure: Error) -> String {
        (failure as? CoreAudioFailure)?.diagnosticDescription ?? failure.localizedDescription
    }
}
