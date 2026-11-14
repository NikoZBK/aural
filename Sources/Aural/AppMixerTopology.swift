import CoreAudio
import Foundation
import Mixer

struct AppMixerLayout: Sendable {
    let inputStreams: [UInt32]
    let tapStreams: [UInt32]
    let offsets: [UInt32]
    let gains: [Float]
}

/// HAL and identity work is serialized off the UI/audio threads. Stop drains this
/// queue before releasing any callback context. Gain edits enqueue tiny updates;
/// they never construct taps, publish the EQ model, or calculate EQ response.
// Core Audio descriptions/raw handles are not Sendable. They remain private to
// this serial queue; callback setters and synchronous lifecycle boundaries also
// enter that queue. Only immutable values cross to MainActor.
final class AppMixerTopology: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.aural.app-mixer", qos: .userInitiated)
    private var generation: UInt64 = 0
    private var taps: [UInt32] = []
    private var descriptions: [CATapDescription] = []
    private var guards: [AppMixerGuard] = []
    private var engine: OpaquePointer?
    private var aggregate: UInt32 = 0
    private var inputStreams: [UInt32] = []
    private var output: OutputDevice?
    private var plan: AppMixerPlan?
    private var catalog = AppAudioCatalog(processes: [], incomplete: false)
    private var preferences = AppMixerPreferences()
    private var pendingSince: Date?
    /// When each unidentified source (HAL object and pid) was first heard on this output.
    private var unidentifiedSince: [UInt64: Date] = [:]
    static let unidentifiedGrace: TimeInterval = 1
    private var incompleteSince: Date?
    private var ownProcess: UInt32 = 0
    /// Meters and the stray-input check run on their own steady clock, so
    /// neither depends on how often discovery or a slider edit reconciles.
    private var meterTimer: DispatchSourceTimer?
    private var vacantSince = [Date?](repeating: nil, count: AppMixerPlan.capacity)
    private var lastPeaks = [Float](repeating: 0, count: AppMixerPlan.capacity)
    private var preparing: UInt64 = 0
    // The lock covers only what the main thread reads or writes without
    // entering the queue, so the UI never waits behind HAL work for it.
    private let lock = NSLock()
    private var stateCallback: (@MainActor @Sendable (UInt64, [String?], [Float]) -> Void)?
    private var failureCallback: (@MainActor @Sendable (UInt64, Error) -> Void)?
    private var resources = false
    private var abortSerial: UInt64 = 0
    private var pendingControls: AppMixerPreferences?
    var onState: (@MainActor @Sendable (UInt64, [String?], [Float]) -> Void)? {
        get { lock.withLock { stateCallback } }
        set { lock.withLock { stateCallback = newValue } }
    }
    var onFailure: (@MainActor @Sendable (UInt64, Error) -> Void)? {
        get { lock.withLock { failureCallback } }
        set { lock.withLock { failureCallback = newValue } }
    }

    var hasResources: Bool { lock.withLock { resources } }
    private func publishResources() {
        let value = !taps.isEmpty || guards.contains(where: \.hasResources)
        lock.withLock { resources = value }
    }
    /// Stop must not wait seconds behind a start that is still settling HAL
    /// state: preparation checks this between steps and unwinds.
    private func checkAbort() throws {
        guard lock.withLock({ abortSerial }) == preparing else { throw CancellationError() }
    }
    func prepare(aggregate: UInt32, output: OutputDevice, preferences: AppMixerPreferences) async throws -> AppMixerLayout {
        let serial = lock.withLock { abortSerial }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                preparing = serial
                defer { publishResources() }
                do { continuation.resume(returning: try prepareNow(aggregate: aggregate, output: output, preferences: preferences)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func prepareNow(aggregate: UInt32, output: OutputDevice, preferences: AppMixerPreferences) throws -> AppMixerLayout {
        guard #available(macOS 14.2, *), taps.isEmpty else { throw AudioFailure(message: "A previous app mixer route still needs cleanup.") }
        try checkAbort()
        generation &+= 1; self.aggregate = aggregate; self.output = output; self.preferences = try preferences.validated()
        var ownPID = getpid(), own: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        var property = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, UInt32(MemoryLayout<pid_t>.size), &ownPID, &size, &own), "Identify mixer process")
        guard own != 0 else { throw AudioFailure(message: "Aural's mixer process could not be identified.") }
        ownProcess = own
        let discoveryDeadline = Date().addingTimeInterval(1)
        repeat {
            catalog = try AppAudioCatalog.read()
            if !catalog.incomplete { break }
            try checkAbort()
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < discoveryDeadline
        try validateConflicts(catalog, output: output)
        let first = try AppMixerPlan(catalog: catalog, previous: [], preferences: preferences, ownPID: ownPID, outputObject: output.id)
        try ensureProtection(output: output)
        guard let protection = guards.last else { throw AudioFailure(message: "The mixer protection reader is missing.") }
        try protection.verify()
        plan = first
        inputStreams = try ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var tapStreams: [UInt32] = []
        for processes in first.groups.map({ $0.map(\.object) }) + [first.others.map(\.object)] {
            try checkAbort()
            let description = CATapDescription(processes: processes, deviceUID: output.uid, stream: 0)
            description.name = "Aural app mixer lane \(taps.count + 1)"; description.isPrivate = true; description.muteBehavior = .mutedWhenTapped
            if #available(macOS 26, *) { description.isProcessRestoreEnabled = false }
            var tap: UInt32 = 0
            try check(AudioHardwareCreateProcessTap(description, &tap), "Create app mixer tap")
            taps.append(tap); descriptions.append(description)
            tapStreams.append(try appendTap(tap))
        }
        tapStreams.append(try appendTap(protection.tap))
        // HAL publishes the stream list before its callback configuration has
        // necessarily caught up. Wait for agreement off the UI/audio threads;
        // never calculate offsets from a partially published configuration.
        var channels = [UInt32](repeating: 0, count: 32), count: UInt32 = 0
        let configurationDeadline = Date().addingTimeInterval(2)
        repeat {
            try check(am_stream_channels(aggregate, &channels, UInt32(channels.count), &count), "Read mixer stream configuration")
            guard try ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput) == inputStreams else {
                throw AudioFailure(message: "Mixer input identities changed while mapping the callback.")
            }
            if count == inputStreams.count { break }
            try checkAbort()
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < configurationDeadline
        guard count == inputStreams.count else {
            throw AudioFailure(message: "Mixer stream configuration did not settle (\(inputStreams.count) streams, \(count) buffers).")
        }
        var offsets: [UInt32: UInt32] = [:], offset: UInt32 = 0
        for (index, stream) in inputStreams.enumerated() {
            let format = try scalar(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
            guard format.mChannelsPerFrame == channels[index] else { throw AudioFailure(message: "Mixer stream channel counts changed.") }
            offsets[stream] = offset; offset += channels[index]
        }
        let sourceOffsets = try tapStreams.dropLast().map { stream -> UInt32 in
            guard let value = offsets[stream] else { throw AudioFailure(message: "An app mixer stream disappeared.") }
            return value
        }
        guard Set(sourceOffsets.flatMap { [$0, $0 + 1] }).count == sourceOffsets.count * 2 else { throw AudioFailure(message: "App mixer inputs overlap.") }
        let gains = first.slots.map { $0.flatMap { preferences.apps[$0]?.gain } ?? 1 } + [1]
        return AppMixerLayout(inputStreams: inputStreams, tapStreams: tapStreams, offsets: sourceOffsets, gains: gains)
    }
    private func ensureProtection(output: OutputDevice) throws {
        if guards.count != 1 || guards.first?.output != output {
            let next = AppMixerGuard(output: output); guards.append(next)
            try next.start(ownProcess: ownProcess)
            var remaining: [AppMixerGuard] = [], failures: [String] = []
            for old in guards.dropLast() {
                do { try old.stop(cleanup: .live) } catch { failures.append(error.localizedDescription) }
                if old.hasResources { remaining.append(old) }
            }
            guards = remaining + [next]
            if !failures.isEmpty { throw AudioFailure(message: failures.joined(separator: " ")) }
        }
    }
    private func appendTap(_ tap: UInt32) throws -> UInt32 {
        var tapUIDs = try taps.map { try audioString($0, kAudioTapPropertyUID) }
        if !taps.contains(tap) { tapUIDs.append(try audioString(tap, kAudioTapPropertyUID)) }
        let before = inputStreams
        try check(am_set_taps(aggregate, tapUIDs as CFArray), "Attach app mixer input")
        let deadline = Date().addingTimeInterval(2)
        repeat {
            inputStreams = try ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            if inputStreams.count == before.count + 1 { break }
            try checkAbort()
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        let added = inputStreams.filter { !before.contains($0) }
        guard inputStreams.count == before.count + 1, added.count == 1, before.allSatisfy(inputStreams.contains) else {
            throw AudioFailure(message: "Could not prove app mixer input ownership.")
        }
        return added[0]
    }
    func install(_ engine: OpaquePointer) throws -> UInt64 {
        try queue.sync {
            self.engine = engine
            vacantSince = [Date?](repeating: nil, count: AppMixerPlan.capacity)
            lastPeaks = [Float](repeating: 0, count: AppMixerPlan.capacity)
            try reconcile(catalog)
            // Controls may have changed while asynchronous HAL preparation ran.
            // Apply the latest values before the first physical callback.
            for (slot, id) in (plan?.slots ?? []).enumerated() {
                guard am_reset_gain(engine, UInt32(slot), id.flatMap { preferences.apps[$0]?.gain } ?? 1) else {
                    throw AudioFailure(message: "Could not prime the latest app volume.")
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.meter() }
            meterTimer?.cancel(); meterTimer = timer; timer.resume()
            return generation
        }
    }
    private func stopMeter() { meterTimer?.cancel(); meterTimer = nil }
    private func meter() {
        guard let engine, let plan else { return }
        let now = Date(), slots = plan.slots
        let peaks = slots.indices.map { am_read_peak(engine, UInt32($0)) }
        for slot in slots.indices {
            guard slots[slot] == nil else { vacantSince[slot] = nil; continue }
            guard let since = vacantSince[slot] else { vacantSince[slot] = now; continue }
            // A lane emptied a moment ago may still carry its tail.
            if peaks[slot] > 0.00001, now.timeIntervalSince(since) >= 0.25 {
                stopMeter()
                report(AudioFailure(message: "An unassigned mixer input received audio. Processing stopped to prevent duplicate playback."))
                return
            }
        }
        lastPeaks = peaks
        let token = generation, callback = lock.withLock { stateCallback }
        DispatchQueue.main.async { callback?(token, slots, peaks) }
    }
    /// A drag sends one edit per tick. Only the newest value matters, so a
    /// burst collapses into one pass, and a pass that cannot move any app
    /// between lanes sets gains without touching HAL.
    func controls(_ preferences: AppMixerPreferences) {
        let scheduled = lock.withLock { () -> Bool in
            defer { pendingControls = preferences }
            return pendingControls != nil
        }
        guard !scheduled else { return }
        queue.async { [self] in
            guard let latest = lock.withLock({ () -> AppMixerPreferences? in
                defer { pendingControls = nil }
                return pendingControls
            }) else { return }
            do {
                let next = try latest.validated(), previous = self.preferences
                self.preferences = next
                guard let engine, let plan else { return }
                guard Self.sameRouting(previous, next) else { try reconcile(catalog); return }
                for (slot, id) in plan.slots.enumerated() {
                    guard am_set_gain(engine, UInt32(slot), id.flatMap { next.apps[$0]?.gain } ?? 1) else {
                        throw AudioFailure(message: "The app mixer rejected a volume setting.")
                    }
                }
            } catch { report(error) }
        }
    }
    /// Lanes depend only on which apps are remembered and which are away from
    /// 100% and unmuted, never on the level itself.
    static func sameRouting(_ lhs: AppMixerPreferences, _ rhs: AppMixerPreferences) -> Bool {
        lhs.apps.count == rhs.apps.count && lhs.apps.allSatisfy { rhs.apps[$0.key]?.neutral == $0.value.neutral }
    }
    func discover(_ catalog: AppAudioCatalog) {
        queue.async { [self] in
            guard engine != nil else { return }
            do { try reconcile(catalog) } catch { report(error) }
        }
    }
    private func reconcile(_ nextCatalog: AppAudioCatalog) throws {
        guard let output, let engine, let previous = plan else { return }
        try guards.last?.verify()
        try validateConflicts(nextCatalog, output: output)
        if nextCatalog.incomplete {
            if incompleteSince == nil { incompleteSince = Date() }
            guard Date().timeIntervalSince(incompleteSince ?? .distantPast) < 2 else { throw AudioFailure(message: "App audio discovery remained incomplete. Processing stopped.") }
            return
        }
        incompleteSince = nil
        // A helper can be heard before its ownership is readable, so an
        // unidentified source waits briefly in case it belongs to a muted app.
        // A command-line player never gains an owner; it must not stay silent
        // or stop processing for everyone, so it then joins Other audio.
        let now = Date()
        let heard = nextCatalog.processes.filter { AppMixerPlan.unidentified($0) && $0.pid != getpid() && $0.playing && $0.outputs.contains(output.id) }
        let keys = Dictionary(heard.map { (UInt64($0.object) << 32 | UInt64(UInt32(bitPattern: $0.pid)), $0.object) }, uniquingKeysWith: { first, _ in first })
        unidentifiedSince = unidentifiedSince.filter { keys[$0.key] != nil }
        for key in keys.keys where unidentifiedSince[key] == nil { unidentifiedSince[key] = now }
        let released = Set(keys.filter { now.timeIntervalSince(unidentifiedSince[$0.key] ?? now) >= Self.unidentifiedGrace }.values)
        let next = try AppMixerPlan(catalog: nextCatalog, previous: previous.slots, preferences: preferences, ownPID: getpid(), outputObject: output.id,
                                    released: released)
        let changed = next.groups.indices.filter { previous.slots[$0] != next.slots[$0] || !sameBindings(previous.groups[$0], next.groups[$0]) }
        // Empty every affected lane before moving any source to another lane.
        for slot in changed { vacantSince[slot] = nil; try update(slot, processes: []) }
        if !sameBindings(previous.others, next.others) { try update(8, processes: next.others.map(\.object)) }
        for slot in next.slots.indices {
            let gain = next.slots[slot].flatMap { preferences.apps[$0]?.gain } ?? 1
            let accepted = changed.contains(slot) ? am_reset_gain(engine, UInt32(slot), gain) : am_set_gain(engine, UInt32(slot), gain)
            guard accepted else { throw AudioFailure(message: "The app mixer rejected a volume setting.") }
            if changed.contains(slot) { try update(slot, processes: next.groups[slot].map(\.object)) }
        }
        guard try ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput) == inputStreams else {
            throw AudioFailure(message: "The app mixer stream map changed. Processing stopped before using stale inputs.")
        }
        let unresolved = next.pending.contains { $0.playing && $0.outputs.contains(output.id) }
        if unresolved {
            if pendingSince == nil { pendingSince = Date() }
            guard Date().timeIntervalSince(pendingSince ?? .distantPast) < 5 else { throw AudioFailure(message: "Aural could not verify a playing app's ownership. Saved app mute/volume cannot be applied safely.") }
        } else { pendingSince = nil }
        catalog = nextCatalog; plan = next
        let slots = next.slots, peaks = lastPeaks, token = generation
        let callback = lock.withLock { stateCallback }
        DispatchQueue.main.async { callback?(token, slots, peaks) }
    }
    private func sameBindings(_ lhs: [AppAudioProcess], _ rhs: [AppAudioProcess]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.allSatisfy { old in rhs.contains { $0.object == old.object && $0.pid == old.pid && $0.birth == old.birth && $0.ownerID == old.ownerID && $0.responsibleBirth == old.responsibleBirth } }
    }
    private func update(_ index: Int, processes: [UInt32]) throws {
        descriptions[index].processes = processes
        try check(am_update_tap(taps[index], UnsafeRawPointer(Unmanaged.passUnretained(descriptions[index]).toOpaque())), "Update app mixer ownership", objectID: taps[index])
    }
    private func validateConflicts(_ catalog: AppAudioCatalog, output: OutputDevice) throws {
        let conflict = catalog.processes.contains { process in
            process.pid != getpid() && process.playing &&
                (process.bundleID == "local.aural.equalizer" || process.bundleID == "local.aural.mixer-probe" ||
                 process.bundleID.hasPrefix("local.aural.performance-preview") ||
                 (AppAudioCatalog.competingProcessors.contains(process.bundleID) && process.outputs.contains(output.id)))
        }
        if conflict { throw AudioFailure(message: "Another audio processor is using this output. Stop it before starting Aural's app mixer.") }
    }
    private func report(_ error: Error) {
        AuralLog.audio.error("App mixer failed: \(AuralLog.describe(error), privacy: .public)")
        let token = generation, callback = lock.withLock { failureCallback }
        DispatchQueue.main.async { callback?(token, error) }
    }
    func invalidate() {
        lock.withLock { abortSerial &+= 1 }
        queue.sync { generation &+= 1; engine = nil; stopMeter() }
    }
    func beginWaiting() -> UInt64 {
        queue.sync {
            let token = generation
            if let uid = guards.last?.output.uid { pollWaiting(uid: uid, token: token) }
            return token
        }
    }
    private func pollWaiting(uid: String, token: UInt64) {
        queue.asyncAfter(deadline: .now() + 0.1) { [self] in
            guard generation == token, engine == nil, !guards.isEmpty else { return }
            defer { publishResources() }
            do {
                let candidates = try ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
                for id in candidates where try audioString(id, kAudioDevicePropertyDeviceUID) == uid {
                    if try scalar(id, kAudioDevicePropertyDeviceIsAlive, UInt32(0)) != 0 {
                        try ensureProtection(output: OutputDevice(id: id, uid: uid, name: try audioString(id, kAudioObjectPropertyName)))
                    }
                }
            } catch let error as CoreAudioFailure where error.isUnavailableObject || error.status == kAudioHardwareUnknownPropertyError {
                // An unplugged device can stay listed for a moment and answer
                // either way. Both mean "not back yet", not "give up".
                AuralLog.audio.notice("Saved-output mixer guard is waiting for HAL: \(error.diagnosticDescription, privacy: .public)")
            } catch { report(error); return }
            pollWaiting(uid: uid, token: token)
        }
    }
    func release(keepingGuard: Bool, cleanup: AudioRouteCleanup) throws {
        try queue.sync {
            defer { publishResources() }
            stopMeter()
            generation &+= 1; engine = nil; aggregate = 0; inputStreams = []; plan = nil; pendingSince = nil; unidentifiedSince = [:]; incompleteSince = nil
            var remaining: [UInt32] = [], failures: [String] = []
            for tap in taps {
                let status = cleanup.destroyTap(tap)
                if status != noErr && status != kAudioHardwareBadObjectError && status != kAudioHardwareBadDeviceError {
                    remaining.append(tap); failures.append(CoreAudioFailure(status: status, action: "Release app mixer tap", objectID: tap).localizedDescription)
                }
            }
            taps = remaining
            if taps.isEmpty { descriptions = [] }
            if !keepingGuard {
                var pending: [AppMixerGuard] = []
                for guardReader in guards {
                    do { try guardReader.stop(cleanup: cleanup) } catch { failures.append(error.localizedDescription) }
                    if guardReader.hasResources { pending.append(guardReader) }
                }
                guards = pending
            }
            if !failures.isEmpty { throw AudioFailure(message: failures.joined(separator: " ")) }
        }
    }
    #if AURAL_TESTING
    func adoptForTesting(taps: [UInt32], protection: AppMixerGuard) {
        queue.sync { self.taps = taps; guards = [protection]; publishResources() }
    }
    #endif
}
