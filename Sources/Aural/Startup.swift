import Foundation

struct StartupPlan {
    enum Decision: Equatable { case wait, start, unavailable, missingOutput }
    let outputUID: String
    let deadline: Date

    func decision(availableUIDs: [String], now: Date) -> Decision {
        guard !outputUID.isEmpty else { return .missingOutput }
        // Never send a saved headphone correction to a different device.
        if availableUIDs.contains(outputUID) { return .start }
        return now >= deadline ? .unavailable : .wait
    }
}
