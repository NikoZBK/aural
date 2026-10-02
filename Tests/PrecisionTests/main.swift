import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
@main struct PrecisionTests {
    @MainActor static func main() {
        var draft = PrecisionInput()
        draft.restore(value: 1.41421356237, decimals: 3, revision: 1)
        require(draft.text == "1.414" && draft.submission(in: 0.05...50, revision: 1) == .unchanged,
                "Focusing and leaving an untouched field must not quantize an imported value")
        draft.edit("1.414")
        require(draft.submission(in: 0.05...50, revision: 1) == .value(1.414),
                "Explicitly entering the displayed rounded value must commit that exact value")
        draft.accept()
        require(draft.submission(in: 0.05...50, revision: 1) == .unchanged, "Return followed by focus loss must not commit twice")
        require(draft.submission(in: 0.05...50, revision: 2) == .unchanged,
                "A completed edit must not block the next action while its view catches up to a new revision")
        draft.edit(" 1.41421356237 \n")
        require(draft.submission(in: 0.05...50, revision: 1) == .value(1.41421356237), "Typed precision must survive parsing")
        require(draft.submission(in: 0.05...50, revision: 2) == .stale, "A replaced EQ must reject the previous field draft")
        for text in ["", "-", "nan", "inf", "1e999", "0.049", "50.01"] {
            draft.edit(text)
            require(draft.submission(in: 0.05...50, revision: 1) == .invalid, "Invalid, incomplete, and out-of-range numbers must not reach the model")
        }
        draft.restore(value: -3.14159265359, decimals: 2, revision: 2)
        require(draft.text == "-3.14" && draft.submission(in: -30...30, revision: 2) == .unchanged, "Cancel or external changes must clear edit intent")
        print("PASS untouched imported precision, explicit rounded edits, duplicate commit suppression, stale drafts, and invalid numeric input")

        let coordinator = PrecisionSubmissionCoordinator()
        let firstID = UUID(), nextID = UUID()
        var activeDraft = PrecisionInput()
        var modelRevision = 7
        var gain = -2.0
        var channel = "L+R"
        var operations: [String] = []
        activeDraft.restore(value: gain, decimals: 2, revision: modelRevision)
        activeDraft.edit("-3")
        coordinator.activate(firstID) {
            switch activeDraft.submission(in: -30...30, revision: modelRevision) {
            case .unchanged: return .unchanged
            case .invalid, .stale: return .rejected
            case .value(let value):
                activeDraft.accept()
                gain = value
                modelRevision += 1
                operations.append("gain")
                return .submitted
            }
        }
        // A macOS popup need not resign the field before delivering its selection.
        let firstSubmission = coordinator.submitActive()
        if firstSubmission != .rejected { channel = "L"; operations.append("channel") }
        require(gain == -3 && channel == "L" && operations == ["gain", "channel"],
                "A popup action must apply pending numeric input before its discrete edit")
        activeDraft.restore(value: gain, decimals: 2, revision: modelRevision)
        require(coordinator.submitActive() == .unchanged && operations.count == 2,
                "An already-submitted focused field must not produce a duplicate edit")
        activeDraft.edit("-")
        require(coordinator.submitActive() == .rejected && gain == -3,
                "Invalid pending input must block the discrete action without changing the model")
        activeDraft.edit("-4")
        modelRevision += 1
        require(coordinator.submitActive() == .rejected && gain == -3,
                "A pending field from the previous preset must still be rejected")
        var nextCalls = 0
        coordinator.activate(nextID) { nextCalls += 1; return .unchanged }
        coordinator.deactivate(firstID)
        _ = coordinator.submitActive()
        require(nextCalls == 1, "A late focus-loss event must not unregister the newly focused field")
        coordinator.deactivate(nextID)
        require(coordinator.submitActive() == .unchanged && nextCalls == 1,
                "Removing the active field must release its submission callback")
        print("PASS synchronous numeric-before-popup ordering, invalid/stale rejection, focus handoff, and submission cleanup")
    }
}
