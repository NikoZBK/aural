import AppKit
import Foundation
import ProbeCore

enum OwnershipPolicy: String, Codable {
    case enclosingApp = "enclosing-app"
    case experimentalResponsibility = "experimental-responsibility"
}

struct ProcessInstance: Codable, Equatable {
    let pid: Int32
    let uid: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func read(_ pid: pid_t) -> (identity: Self?, error: Int32) {
        var value = ProbeProcessIdentity()
        let result = probe_process_identity(pid, &value)
        guard result == 0 else { return (nil, result) }
        return (Self(pid: value.pid, uid: value.uid, startSeconds: value.startSeconds,
                     startMicroseconds: value.startMicroseconds), 0)
    }
}

// Validate both lifetimes around the OS query. PID equality alone would accept
// a terminated helper or owner whose numeric PID was reused during discovery.
func responsibleLifetimesMatch(helper: ProcessInstance, helperAfter: ProcessInstance?,
                               owner: ProcessInstance, ownerAfter: ProcessInstance?) -> Bool {
    helper == helperAfter && owner == ownerAfter && helper.uid == owner.uid && helper.pid != owner.pid
}

struct ResponsibleOwner {
    let bundleID: String?
    let owner: ProcessInstance?
    let note: String?
}

@MainActor func experimentalWebKitOwner(pid: pid_t, helper: ProcessInstance) -> ResponsibleOwner {
    var ownerPID: pid_t = 0
    let result = probe_experimental_responsible_pid(pid, &ownerPID)
    guard result == 0 else {
        return ResponsibleOwner(bundleID: nil, owner: nil, note: "Experimental responsibility query unavailable (errno \(result)); helper remains unattributed")
    }
    guard ownerPID != pid else {
        return ResponsibleOwner(bundleID: nil, owner: nil, note: "No separate responsible application; helper remains unattributed")
    }
    let before = ProcessInstance.read(ownerPID)
    guard let owner = before.identity else {
        return ResponsibleOwner(bundleID: nil, owner: nil, note: "Responsible process identity unavailable (errno \(before.error))")
    }
    guard let application = NSRunningApplication(processIdentifier: ownerPID),
          let url = application.bundleURL?.standardizedFileURL, url.pathExtension == "app",
          let bundle = Bundle(url: url)?.bundleIdentifier, !bundle.isEmpty,
          application.bundleIdentifier == bundle else {
        return ResponsibleOwner(bundleID: nil, owner: nil, note: "Responsible process has no matching application bundle metadata")
    }
    guard responsibleLifetimesMatch(helper: helper, helperAfter: ProcessInstance.read(pid).identity,
                                    owner: owner, ownerAfter: ProcessInstance.read(ownerPID).identity) else {
        return ResponsibleOwner(bundleID: nil, owner: nil, note: "Helper or responsible process changed identity during attribution")
    }
    return ResponsibleOwner(bundleID: bundle, owner: owner, note: nil)
}

let sharedWebKitBundleIDs: Set<String> = ["com.apple.WebKit.GPU", "com.apple.WebKit.WebContent", "com.apple.WebKit.Networking"]

func appProcesses(_ catalog: ProcessCatalog, bundleID: String) -> [AudioProcessInfo] {
    catalog.processes.filter { $0.bundleID == bundleID || $0.ownerBundleID == bundleID }
}

func sameAppProcessIdentities(_ expected: [AudioProcessInfo], _ observed: [AudioProcessInfo]) -> Bool {
    guard !expected.isEmpty, expected.count == observed.count,
          Set(expected.map(\.object)).count == expected.count,
          Set(observed.map(\.object)).count == observed.count else { return false }
    let current = Dictionary(uniqueKeysWithValues: observed.map { ($0.object, $0) })
    return expected.allSatisfy { old in
        guard let now = current[old.object], old.identityNote == nil, now.identityNote == nil,
              old.instance != nil, now.instance != nil else { return false }
        return old.pid == now.pid && old.bundleID == now.bundleID && old.ownerBundleID == now.ownerBundleID
            && old.instance == now.instance && old.responsibleInstance == now.responsibleInstance
            && old.ownershipSource == now.ownershipSource
    }
}
