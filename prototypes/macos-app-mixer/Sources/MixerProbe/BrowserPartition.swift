import Foundation

// Pure partition policy. A helper bundle ID alone never establishes Safari
// ownership. Unresolved possible browser helpers cannot enter the unity lane.
struct BrowserPartition {
    let app: [AudioProcessInfo]
    let passthrough: [AudioProcessInfo]
    let pending: [AudioProcessInfo]

    init(catalog: ProcessCatalog, bundleID: String, excluding: Set<UInt32>) throws {
        guard ["com.apple.Safari", "com.google.Chrome"].contains(bundleID), catalog.issues.isEmpty,
              Set(catalog.processes.map(\.object)).count == catalog.processes.count else {
            throw ProbeFailure(message: "Browser handoff requires a complete, unique process catalog and a supported browser")
        }
        var app: [AudioProcessInfo] = [], passthrough: [AudioProcessInfo] = [], pending: [AudioProcessInfo] = []
        for process in catalog.processes where !excluding.contains(process.object) {
            if process.ownerBundleID == bundleID, process.identityNote == nil, process.instance != nil {
                app.append(process)
            } else if process.bundleID.isEmpty || process.bundleID == bundleID ||
                        (bundleID == "com.apple.Safari" && sharedWebKitBundleIDs.contains(process.bundleID) && process.ownerBundleID == nil) ||
                        (bundleID == "com.google.Chrome" && process.bundleID.hasPrefix(bundleID + ".") && process.ownerBundleID == nil) {
                pending.append(process)
            } else {
                passthrough.append(process)
            }
        }
        self.app = app; self.passthrough = passthrough; self.pending = pending
    }
}

func sameBrowserBindings(_ first: [AudioProcessInfo], _ second: [AudioProcessInfo]) -> Bool {
    guard first.count == second.count, Set(first.map(\.object)).count == first.count,
          Set(second.map(\.object)).count == second.count else { return false }
    return first.allSatisfy { old in
        second.contains { next in
            old.object == next.object && old.pid == next.pid && old.instance == next.instance &&
            old.bundleID == next.bundleID && old.ownerBundleID == next.ownerBundleID &&
            old.responsibleInstance == next.responsibleInstance && old.identityNote == next.identityNote &&
            old.ownershipSource == next.ownershipSource
        }
    }
}
