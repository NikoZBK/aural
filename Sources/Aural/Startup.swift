import Foundation

struct StartupPlan {
    enum Decision: Equatable { case wait, start, unavailable, missingOutput }
    let outputUID: String
    /// nil keeps waiting until the output returns or the person cancels.
    let deadline: Date?
    /// Shown while waiting; the device may already be gone from the list.
    var outputName: String? = nil
    /// Lets Core Audio settle after wake or a route change before starting.
    var notBefore: Date? = nil
    var attempts = 0

    var resumes: Bool { deadline == nil }

    static func launch(outputUID: String, now: Date = Date()) -> StartupPlan {
        StartupPlan(outputUID: outputUID, deadline: now.addingTimeInterval(60))
    }

    /// Sleep, a disconnect, or a route change paused EQ that was running.
    static func resume(outputUID: String, outputName: String?, after delay: TimeInterval, now: Date = Date()) -> StartupPlan {
        StartupPlan(outputUID: outputUID, deadline: nil, outputName: outputName, notBefore: now.addingTimeInterval(delay))
    }

    func decision(availableUIDs: [String], now: Date) -> Decision {
        guard !outputUID.isEmpty else { return .missingOutput }
        // Never send a saved headphone correction to a different device.
        if availableUIDs.contains(outputUID) { return now >= (notBefore ?? now) ? .start : .wait }
        guard let deadline else { return .wait }
        return now >= deadline ? .unavailable : .wait
    }

    /// Core Audio can list a device before it accepts a new route. A resumed
    /// start retries briefly instead of giving up on the first failure.
    func retry(now: Date = Date()) -> StartupPlan? {
        guard resumes, attempts < 3 else { return nil }
        var next = self
        next.attempts += 1
        next.notBefore = now.addingTimeInterval(2)
        return next
    }
}

/// Following reacts to macOS output changes. Choosing another output in Aural
/// stays in effect until macOS switches again.
struct SystemOutputFollower {
    private(set) var lastUID: String?

    init(current: String? = nil) { lastUID = current }

    /// Returns the new output when macOS switched; nil when nothing changed or
    /// the default output could not be read.
    mutating func change(to uid: String?) -> String? {
        guard let uid, uid != lastUID else { return nil }
        lastUID = uid
        return uid
    }
}

/// Restarts after a format change or reconnection, but at most once per window,
/// so a route that keeps failing stops with its error instead of looping.
struct RouteRecovery {
    private(set) var lastRestart: Date?
    static let window: TimeInterval = 30

    mutating func allowRestart(now: Date = Date()) -> Bool {
        if let lastRestart, now.timeIntervalSince(lastRestart) < Self.window { return false }
        lastRestart = now
        return true
    }
}
