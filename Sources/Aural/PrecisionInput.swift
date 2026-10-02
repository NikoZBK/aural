import Foundation
import Combine

/// Separates user edits from display rounding and rejects drafts from a replaced EQ.
struct PrecisionInput {
    enum Submission: Equatable {
        case unchanged, stale, invalid
        case value(Double)
    }
    private(set) var text = ""
    private var edited = false
    private var revision = 0

    mutating func restore(value: Double, decimals: Int, revision: Int) {
        text = String(format: "%.*f", decimals, value)
        edited = false
        self.revision = revision
    }
    mutating func edit(_ text: String) { self.text = text; edited = true }
    mutating func accept() { edited = false }
    func submission(in range: ClosedRange<Double>, revision: Int) -> Submission {
        guard edited else { return .unchanged }
        guard self.revision == revision else { return .stale }
        guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              number.isFinite, range.contains(number) else { return .invalid }
        return .value(number)
    }
}

/// Pop-up menus can leave an NSTextField focused. Submit its draft explicitly
/// before a discrete edit instead of depending on focus-loss callback ordering.
@MainActor final class PrecisionSubmissionCoordinator: ObservableObject {
    enum Result: Equatable { case unchanged, submitted, rejected }
    private var active: (id: UUID, submit: () -> Result)?

    func activate(_ id: UUID, submit: @escaping () -> Result) {
        active = (id, submit)
    }
    func deactivate(_ id: UUID) {
        if active?.id == id { active = nil }
    }
    func submitActive() -> Result { active?.submit() ?? .unchanged }
}
