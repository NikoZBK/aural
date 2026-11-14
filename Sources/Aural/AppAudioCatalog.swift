import Foundation
import CoreAudio
import Mixer

struct AppProcessBirth: Codable, Equatable, Sendable {
    let pid: Int32
    let uid: UInt32
    let seconds: UInt64
    let microseconds: UInt64
    static func read(_ pid: Int32) -> Self? {
        var value = AMProcessIdentity()
        guard am_process_identity(pid, &value) == 0 else { return nil }
        return Self(pid: value.pid, uid: value.uid, seconds: value.seconds, microseconds: value.microseconds)
    }
}

struct AppAudioProcess: Equatable, Sendable {
    let object: UInt32
    let pid: Int32
    let bundleID: String
    let ownerID: String?
    let name: String
    let appPath: String?
    let birth: AppProcessBirth?
    let responsibleBirth: AppProcessBirth?
    let outputs: [UInt32]
    let playing: Bool
    let experimental: Bool
    let issue: String?
}

struct AppAudioCatalog: Equatable, Sendable {
    let processes: [AppAudioProcess]
    let incomplete: Bool
    static let sharedWebKit: Set<String> = ["com.apple.WebKit.GPU", "com.apple.WebKit.WebContent", "com.apple.WebKit.Networking"]

    /// Other system-wide audio processors. One playing on the selected output
    /// blocks Aural's mixer, and its row is shown but never controlled.
    static let competingProcessors: Set<String> = ["com.bitgapp.eqmac"]

    // Foundation/C metadata only: discovery runs off the UI and audio threads.
    static func read() throws -> Self {
        var processes: [AppAudioProcess] = [], incomplete = false
        for object in try ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            do { processes.append(try readProcess(object)) }
            catch let failure as CoreAudioFailure where failure.isUnavailableObject {
                incomplete = true
                AuralLog.audio.notice("Audio process expired during discovery: \(failure.diagnosticDescription, privacy: .public)")
            }
        }
        return Self(processes: processes, incomplete: incomplete)
    }

    private static func enclosingApp(pid: Int32) -> URL? {
        var path = [CChar](repeating: 0, count: 4096)
        guard am_process_path(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return enclosingApp(of: URL(fileURLWithPath: String(cString: path)))
    }
    /// The app an executable belongs to. A helper bundled inside an app counts
    /// as that app, so the search climbs outward. It stops at an app kept in an
    /// "Applications" folder: that is an app in its own right even inside
    /// another bundle, as Simulator is inside Xcode.
    static func enclosingApp(of executable: URL) -> URL? {
        var candidate = executable.standardizedFileURL
        var app: URL?
        while candidate.path != "/" {
            if candidate.pathExtension == "app", Bundle(url: candidate)?.bundleIdentifier != nil {
                app = candidate
                if candidate.deletingLastPathComponent().lastPathComponent == "Applications" { break }
            }
            candidate.deleteLastPathComponent()
        }
        return app
    }

    private static func readProcess(_ object: UInt32) throws -> AppAudioProcess {
        let pid = try scalar(object, kAudioProcessPropertyPID, Int32(0)), birth = AppProcessBirth.read(pid)
        let bundleID = try audioString(object, kAudioProcessPropertyBundleID)
        var appURL = enclosingApp(pid: pid), responsible: AppProcessBirth?, experimental = false, issue: String?
        if appURL == nil, sharedWebKit.contains(bundleID), let birth {
            // Explicitly experimental support approved for Aural's mixer. Never
            // use this shared bundle ID for native process restoration.
            var ownerPID: Int32 = 0
            let status = am_responsible_pid(pid, &ownerPID)
            if status == 0, ownerPID != pid, let owner = AppProcessBirth.read(ownerPID), owner.uid == birth.uid,
               let ownerURL = enclosingApp(pid: ownerPID),
               AppProcessBirth.read(pid) == birth, AppProcessBirth.read(ownerPID) == owner {
                appURL = ownerURL; responsible = owner; experimental = true
            } else { issue = "Shared WebKit helper ownership could not be verified." }
        }
        if birth == nil { appURL = nil; issue = "Process lifetime could not be verified." }
        let bundle = appURL.flatMap(Bundle.init(url:)), ownerID = bundle?.bundleIdentifier
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL?.deletingPathExtension().lastPathComponent ?? (bundleID.isEmpty ? "Unidentified audio" : bundleID)
        let outputs = try ids(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
        let playing = try scalar(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0
        guard try scalar(object, kAudioProcessPropertyPID, Int32(0)) == pid, AppProcessBirth.read(pid) == birth else {
            throw CoreAudioFailure(status: kAudioHardwareBadObjectError, action: "Verify process lifetime", objectID: object)
        }
        return AppAudioProcess(object: object, pid: pid, bundleID: bundleID, ownerID: ownerID, name: name,
            appPath: appURL?.path, birth: birth, responsibleBirth: responsible, outputs: outputs,
            playing: playing, experimental: experimental, issue: issue)
    }
}

/// Core Audio says when the set of audio processes changes, and when one starts
/// or stops playing or moves output. Discovery reads on those events instead
/// of polling quickly for them; a slow poll remains as the safety net.
final class AppAudioWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.aural.app-audio-watcher", qos: .utility)
    private let onChange: @Sendable () -> Void
    private var block: AudioObjectPropertyListenerBlock?
    private var watched: Set<UInt32> = []
    private static let perProcess = [address(kAudioProcessPropertyIsRunningOutput),
                                     address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)]
    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    func start() {
        queue.async { [self] in
            guard block == nil else { return }
            let listener: AudioObjectPropertyListenerBlock = { [onChange] _, _ in onChange() }
            var list = address(kAudioHardwarePropertyProcessObjectList)
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &list, queue, listener)
            if status == noErr { block = listener }
            else { AuralLog.audio.error("App audio change notices are unavailable (\(status, privacy: .public)); discovery falls back to its slow poll") }
        }
    }
    /// Follow exactly the processes in the latest catalog.
    func watch(_ objects: [UInt32]) {
        queue.async { [self] in
            guard let block else { return }
            let next = Set(objects)
            for object in watched.subtracting(next) { remove(object, block) }
            for object in next.subtracting(watched) {
                var added = true
                for var property in Self.perProcess where AudioObjectAddPropertyListenerBlock(object, &property, queue, block) != noErr { added = false }
                // A process that left mid-read is simply retried from the next catalog.
                if added { watched.insert(object) } else { remove(object, block) }
            }
        }
    }
    func stop() {
        queue.async { [self] in
            guard let block else { return }
            for object in watched { remove(object, block) }
            var list = address(kAudioHardwarePropertyProcessObjectList)
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &list, queue, block)
            self.block = nil
        }
    }
    private func remove(_ object: UInt32, _ block: @escaping AudioObjectPropertyListenerBlock) {
        // The object may already be gone, which removes its listeners too.
        for var property in Self.perProcess { _ = AudioObjectRemovePropertyListenerBlock(object, &property, queue, block) }
        watched.remove(object)
    }
}

struct AppVolumeSetting: Codable, Equatable, Sendable {
    var volume: Double = 1
    var muted = false
    var name: String
    var gain: Float { muted ? 0 : Float(volume) }
    var neutral: Bool { !muted && volume == 1 }
    func validated() throws -> Self {
        guard volume.isFinite, (0...1).contains(volume), !name.isEmpty, name.count <= 512 else {
            throw AudioFailure(message: "An app mixer setting is invalid. Restore a valid app-mixer.json backup.")
        }
        return self
    }
}

struct AppMixerPreferences: Codable, Equatable, Sendable {
    var version = 1
    var apps: [String: AppVolumeSetting] = [:]
    func validated() throws -> Self {
        guard version == 1, apps.count <= 256 else { throw AudioFailure(message: "This app mixer settings format is unsupported.") }
        for (id, setting) in apps {
            guard !id.isEmpty, id.count <= 255, id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_" )).contains($0) }) else {
                throw AudioFailure(message: "An app mixer identity is invalid.")
            }
            _ = try setting.validated()
        }
        return self
    }
}

struct AppMixerPlan: Equatable, Sendable {
    static let capacity = 8
    let slots: [String?]
    let groups: [[AppAudioProcess]]
    let others: [AppAudioProcess]
    let pending: [AppAudioProcess]
    /// Apps with a saved level or mute that are playing but found every lane
    /// taken by another such app. They stay silent, never at 100%, until a
    /// lane frees up.
    let waiting: [String]

    /// Nothing ties such a source to any app: no owning bundle and no bundle ID.
    static func unidentified(_ process: AppAudioProcess) -> Bool { process.ownerID == nil && process.bundleID.isEmpty }

    /// `released` lists unidentified sources whose ownership grace has ended.
    /// They play at 100% in Other audio instead of staying silent.
    init(catalog: AppAudioCatalog, previous: [String?], preferences: AppMixerPreferences, ownPID: Int32, outputObject: UInt32,
         released: Set<UInt32> = []) throws {
        guard !catalog.incomplete, Set(catalog.processes.map(\.object)).count == catalog.processes.count else {
            throw AudioFailure(message: "The app audio catalog changed while reading. Waiting for a complete snapshot.")
        }
        let processes = catalog.processes.filter { $0.pid != ownPID }
        let verified = processes.reduce(into: [String: [AppAudioProcess]]()) { result, process in
            if let id = process.ownerID, process.birth != nil, process.issue == nil { result[id, default: []].append(process) }
        }
        func playingHere(_ id: String) -> Bool { verified[id]?.contains { $0.playing && $0.outputs.contains(outputObject) } == true }
        let required = verified.keys.filter { preferences.apps[$0]?.neutral == false && playingHere($0) }.sorted()
        var slots = previous.count == Self.capacity ? previous : Array(repeating: nil, count: Self.capacity)
        for index in slots.indices where slots[index].map({ verified[$0] == nil }) == true { slots[index] = nil }
        // Saved attenuation/mute must never silently fall into the unity lane.
        for id in required where !slots.contains(id) {
            if !slots.contains(nil), let index = slots.firstIndex(where: { $0.map { !required.contains($0) } ?? false }) { slots[index] = nil }
            if let index = slots.firstIndex(of: nil) { slots[index] = id }
        }
        let candidates = verified.keys.filter { playingHere($0) || preferences.apps[$0] != nil }.sorted { first, second in
            let a = playingHere(first), b = playingHere(second)
            return a != b ? a : first < second
        }
        for id in candidates where !slots.contains(id) {
            if let index = slots.firstIndex(of: nil) { slots[index] = id }
        }
        let controlled = Set(slots.compactMap { $0 })
        let groups = slots.map { $0.flatMap { verified[$0] } ?? [] }
        let safariNonneutral = preferences.apps["com.apple.Safari"]?.neutral == false
        let pending = processes.filter { process in
            (process.ownerID == nil && safariNonneutral && AppAudioCatalog.sharedWebKit.contains(process.bundleID)) ||
            (process.ownerID == nil && preferences.apps.contains { id, setting in
                !setting.neutral && (process.bundleID.isEmpty ? !released.contains(process.object)
                                     : process.bundleID == id || process.bundleID.hasPrefix(id + "."))
            }) ||
            (process.ownerID.map { !controlled.contains($0) && preferences.apps[$0]?.neutral == false } == true)
        }
        let pendingObjects = Set(pending.map(\.object))
        self.slots = slots; self.groups = groups; self.pending = pending
        waiting = required.filter { !controlled.contains($0) }
        others = processes.filter { !controlled.contains($0.ownerID ?? "") && !pendingObjects.contains($0.object) }
    }
}
