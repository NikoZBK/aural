import Foundation

/// Serialize CPU analysis away from the UI. Superseded tasks skip queued work;
/// callers also check cancellation before publishing a result.
actor EQAnalysisWorker {
    static let shared = EQAnalysisWorker()

    func calculate<Value: Sendable>(_ work: @Sendable () -> Value) -> Value? {
        guard !Task.isCancelled else { return nil }
        return work()
    }
}
