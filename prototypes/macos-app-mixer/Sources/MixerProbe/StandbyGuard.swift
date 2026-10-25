import CoreAudio
import Foundation
import ProbeCore

struct StandbyGuardMeasurements: Encodable {
    let binding: StandbyMuteBinding
    let readerEnabled: Bool
    let callbacks: UInt64
    let frames: UInt64
    let invalidBuffers: UInt64
    let maximumCallbackMicroseconds: Double
}

// The reader contains only this device-specific tap. It has no hardware
// subdevices, microphones, or output streams, and never replays captured audio.
// Keep it alive while the separate physical playback route is reconstructed.
final class StandbyMuteGuard {
    let binding: StandbyMuteBinding
    private(set) var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var callback: AudioDeviceIOProcID?
    private var drain: OpaquePointer?
    private var readerEnabled = false
    var hasResources: Bool { tap != 0 || aggregate != 0 || callback != nil || drain != nil }
    var measurements: StandbyGuardMeasurements {
        let counters = drain.map(probe_drain_counters)
        return StandbyGuardMeasurements(binding: binding, readerEnabled: readerEnabled,
            callbacks: counters?.callbacks ?? 0, frames: counters?.frames ?? 0,
            invalidBuffers: counters?.invalidBuffers ?? 0,
            maximumCallbackMicroseconds: Double(counters?.maximumCallbackNanoseconds ?? 0) / 1000)
    }

    init(binding: StandbyMuteBinding) { self.binding = binding }

    func start(device: DeviceInfo, read: Bool = true) throws {
        guard !hasResources, binding.outputUID == device.uid, binding.outputObject == device.id,
              !binding.processes.isEmpty else { throw ProbeFailure(message: "Invalid standby guard binding or lifecycle") }
        let description = CATapDescription(processes: binding.processes, deviceUID: binding.outputUID, stream: 0)
        description.name = "Aural selected-output standby guard"
        description.isPrivate = true; description.muteBehavior = .muted
        if #available(macOS 26, *) { description.isProcessRestoreEnabled = true }
        try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "Create selected-output standby tap")
        let tapUID = try HAL.string(tap, kAudioTapPropertyUID)
        guard tapUID == description.uuid.uuidString, description.deviceUID == binding.outputUID else {
            throw ProbeFailure(message: "Standby tap identity or selected-output scope changed")
        }
        try HAL.validate(HAL.scalar(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription()), rate: device.rate)
        guard read else { return } // Explicit passive-tap diagnostic, never the recovery default.
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Aural Selected-Output Guard Reader",
            kAudioAggregateDeviceUIDKey: "local.aural.guard-reader.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]
        ]
        try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Create input-only standby reader")
        let inputs = try HAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        let outputs = try HAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard inputs.count == 1, outputs.isEmpty else {
            throw ProbeFailure(message: "Standby reader must contain exactly one tap input and no output streams")
        }
        try HAL.validate(HAL.format(inputs[0]), rate: device.rate)
        guard let context = probe_drain_create() else { throw ProbeFailure(message: "Cannot allocate standby reader counters") }
        drain = context
        try HAL.check(AudioDeviceCreateIOProcID(aggregate, probe_drain_callback, UnsafeMutableRawPointer(context), &callback), "Create standby reader callback", aggregate)
        guard let callback else { throw ProbeFailure(message: "HAL returned no standby callback") }
        try HAL.check(AudioDeviceStart(aggregate, callback), "Start input-only standby reader", aggregate)
        readerEnabled = true
        // With tap auto-start, a quiet app legitimately has no callbacks yet.
        // Keep the reader armed; do not regress paused-app route preparation.
    }

    func waitForFrames() throws {
        guard let drain, readerEnabled else { throw ProbeFailure(message: "Standby reader is not armed") }
        let deadline = Date().addingTimeInterval(2)
        repeat {
            let count = probe_drain_counters(drain)
            guard count.invalidBuffers == 0 else { throw ProbeFailure(message: "Standby reader received an unexpected buffer layout") }
            if count.frames > 0 { return }
            wait(0.01)
        } while Date() < deadline
        throw ProbeFailure(message: "An actively playing selected-output app did not deliver standby input frames")
    }

    func validate() throws {
        guard tap != 0 else { throw ProbeFailure(message: "Standby tap is no longer owned") }
        _ = try HAL.string(tap, kAudioTapPropertyUID)
        guard let drain, readerEnabled, probe_drain_counters(drain).invalidBuffers == 0 else {
            throw ProbeFailure(message: "Standby reader is inactive or has invalid buffers")
        }
    }

    func stop() throws {
        var failures: [String] = []
        if let callback {
            let stop = AudioDeviceStop(aggregate, callback)
            if ![noErr, kAudioHardwareNotRunningError, kAudioHardwareBadDeviceError, kAudioHardwareBadObjectError].contains(stop) {
                failures.append("Stop standby reader: \(stop)")
            }
            let remove = AudioDeviceDestroyIOProcID(aggregate, callback)
            if [noErr, kAudioHardwareBadDeviceError, kAudioHardwareBadObjectError].contains(remove) { self.callback = nil }
            else { failures.append("Remove standby callback: \(remove)") }
        }
        if aggregate != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregate)
            if [noErr, kAudioHardwareBadDeviceError, kAudioHardwareBadObjectError].contains(status) { aggregate = 0; callback = nil }
            else { failures.append("Destroy standby aggregate: \(status)") }
        }
        if tap != 0 {
            let status = AudioHardwareDestroyProcessTap(tap)
            if [noErr, kAudioHardwareBadDeviceError, kAudioHardwareBadObjectError].contains(status) { tap = 0 }
            else { failures.append("Release standby tap: \(status)") }
        }
        // Retain callback memory unless removal or aggregate destruction proves
        // that HAL cannot call it again, including partial-start failures.
        if callback == nil, let drain { probe_drain_destroy(drain); self.drain = nil; readerEnabled = false }
        if !failures.isEmpty { throw ProbeFailure(message: failures.joined(separator: "; ")) }
    }
}

@MainActor func standaloneGuardSession(_ options: Options, device: DeviceInfo) throws {
    guard let bundleID = options.values["--bundle"], !bundleID.isEmpty,
          bundleID != Bundle.main.bundleIdentifier else { throw ProbeFailure(message: "guard-test requires an exact app bundle identifier") }
    let read = options.values["--reader"] ?? "on"
    guard ["on", "off"].contains(read) else { throw ProbeFailure(message: "--reader must be on or off") }
    let duration = try options.number("--duration", default: 15, range: 3...60)
    guard case .ready(let readyDevice) = try readOutputReadiness(uid: device.uid),
          readyDevice.id == device.id, readyDevice.rate == device.rate else {
        throw ProbeFailure(message: "The selected output is not ready for the standalone guard check")
    }
    let group = appProcesses(try playbackPreflight(device: device, playback: .all), bundleID: bundleID)
    guard !group.isEmpty, group.allSatisfy({ $0.identityNote == nil }) else { throw ProbeFailure(message: "Cannot verify the guard's app processes") }
    guard group.contains(where: { $0.runningOutput && $0.outputDevices.contains(device.id) }) else {
        throw ProbeFailure(message: "Play the requested app directly through the selected output before testing the standalone guard")
    }
    let owner = StandbyMuteGuard(binding: StandbyMuteBinding(generation: 1, outputObject: device.id, outputUID: device.uid, processes: group.map(\.object)))
    var failure: Error?, measurements: StandbyGuardMeasurements?
    do {
        try owner.start(device: device, read: read == "on")
        if read == "on" { try owner.waitForFrames() }
        fputs("guard-only: reader=\(read), selected output only; no playback route or reference tone\n", stderr)
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            let current = try DeviceInfo.selected(device.uid)
            guard current.id == device.id, current.rate == device.rate else { throw ProbeFailure(message: "Output changed during standalone guard test") }
            if read == "on" { try owner.validate() }
            wait(0.1)
        } while Date() < deadline
    } catch { failure = error }
    measurements = owner.measurements
    do { try owner.stop() } catch { failure = ProbeFailure(message: (failure.map { $0.localizedDescription + " Cleanup: " } ?? "") + error.localizedDescription) }
    struct Report: Encodable {
        let outcome: String
        let error: String?
        let measurements: StandbyGuardMeasurements?
        let resourcesReleased: Bool
        let limitation = "Reader activity and device scope only; listening or independent loopback must establish direct-output suppression"
    }
    try writeJSON(Report(outcome: failure == nil ? "completed" : "failed", error: failure?.localizedDescription,
                         measurements: measurements, resourcesReleased: !owner.hasResources), to: options.values["--report"])
    if let failure { throw failure }
}
