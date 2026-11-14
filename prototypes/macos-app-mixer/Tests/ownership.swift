import Foundation
import Darwin

private func birth(_ pid: Int32, _ start: UInt64, uid: UInt32 = 501) -> ProcessInstance {
    ProcessInstance(pid: pid, uid: uid, startSeconds: start, startMicroseconds: 42)
}
private func helper(object: UInt32 = 10, pid: Int32 = 100, start: UInt64 = 1,
                    owner: String? = "com.apple.Safari", responsible: ProcessInstance? = nil,
                    source: String = "experimental-responsibility", note: String? = nil) -> AudioProcessInfo {
    AudioProcessInfo(object: object, pid: pid, bundleID: "com.apple.WebKit.GPU", ownerBundleID: owner,
        name: "Untrusted display name", identityNote: note, outputDevices: [55], runningOutput: true,
        instance: birth(pid, start), ownershipSource: source, responsibleInstance: responsible)
}

@main struct OwnershipChecks {
    static func main() throws {
        let original = ProcessInstance.read(getpid())
        precondition(original.error == 0 && original.identity?.pid == getpid())
        precondition(original.identity?.uid == getuid() && original.identity == ProcessInstance.read(getpid()).identity)
        precondition(ProcessInstance.read(-1).identity == nil)
        let gpu = birth(100, 1), safari = birth(200, 2)
        precondition(responsibleLifetimesMatch(helper: gpu, helperAfter: gpu, owner: safari, ownerAfter: safari))
        precondition(!responsibleLifetimesMatch(helper: gpu, helperAfter: birth(100, 3), owner: safari, ownerAfter: safari))
        precondition(!responsibleLifetimesMatch(helper: gpu, helperAfter: gpu, owner: safari, ownerAfter: birth(200, 3)))
        precondition(!responsibleLifetimesMatch(helper: gpu, helperAfter: nil, owner: safari, ownerAfter: safari))
        precondition(!responsibleLifetimesMatch(helper: gpu, helperAfter: gpu, owner: safari, ownerAfter: nil))
        precondition(!responsibleLifetimesMatch(helper: gpu, helperAfter: gpu, owner: birth(200, 2, uid: 502), ownerAfter: birth(200, 2, uid: 502)))
        precondition(!responsibleLifetimesMatch(helper: gpu, helperAfter: gpu, owner: gpu, ownerAfter: gpu))

        let owned = helper(responsible: safari)
        let peer = helper(object: 11, pid: 101, owner: "com.bitgapp.eqmac", responsible: birth(201, 2))
        let unknown = helper(object: 12, pid: 102, owner: nil, source: "unattributed", note: "No owner")
        let catalog = ProcessCatalog(processes: [owned, peer, unknown], issues: [])
        precondition(appProcesses(catalog, bundleID: "com.apple.Safari").map(\.object) == [10])
        precondition(appProcesses(catalog, bundleID: "com.bitgapp.eqmac").map(\.object) == [11])
        precondition(appProcesses(ProcessCatalog(processes: [unknown], issues: []), bundleID: "com.apple.Safari").isEmpty)
        precondition(!sameAppProcessIdentities([unknown], [unknown]))
        precondition(sameAppProcessIdentities([owned], [owned]))
        precondition(!sameAppProcessIdentities([owned], []))
        precondition(!sameAppProcessIdentities([owned], [helper(object: 13, responsible: safari)]))
        precondition(!sameAppProcessIdentities([owned], [helper(start: 3, responsible: safari)]))
        precondition(!sameAppProcessIdentities([owned], [helper(responsible: birth(200, 3))]))
        precondition(!sameAppProcessIdentities([owned], [peer]))
        precondition(!sameAppProcessIdentities([owned, owned], [owned, owned]))
        precondition(OwnershipPolicy(rawValue: "guess-from-name") == nil)
        let partition = try BrowserPartition(catalog: catalog, bundleID: "com.apple.Safari", excluding: [])
        precondition(partition.app.map(\.object) == [10])
        precondition(partition.passthrough.map(\.object) == [11])
        precondition(partition.pending.map(\.object) == [12])
        let absent = try BrowserPartition(catalog: ProcessCatalog(processes: [peer, unknown], issues: []), bundleID: "com.apple.Safari", excluding: [])
        precondition(absent.app.isEmpty && absent.passthrough.map(\.object) == [11])
        let replacement = helper(object: 10, pid: 102, start: 5, responsible: safari)
        let returned = try BrowserPartition(catalog: ProcessCatalog(processes: [replacement, peer], issues: []), bundleID: "com.apple.Safari", excluding: [11])
        precondition(returned.app.map(\.object) == [10] && returned.passthrough.isEmpty)
        precondition(!sameBrowserBindings(partition.app, returned.app))
        precondition(sameBrowserBindings(partition.app, partition.app))
        precondition(sameBrowserBindings([], []))
        let savedMute = MixerControls(volume: 0.25, muted: true)
        precondition(savedMute.gain == 0 && savedMute.volume == 0.25)
        precondition(MixerControls(volume: savedMute.volume, muted: false).gain == 0.25)
        print("PASS process birth identity, helper/owner PID reuse and exit, same-user attribution, shared WebKit separation, unattributed helpers, duplicates and fail-closed churn detection")
        print("PASS browser newcomer quarantine, unaffected peers, empty/replacement helper groups, object reuse and retained mute/volume")
    }
}
