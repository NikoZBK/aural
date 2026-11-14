import AppKit
import CoreAudio
import ProbeCore

struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct UnsupportedProbeFormat: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct HALFailure: LocalizedError {
    let status: OSStatus
    let action: String
    let object: AudioObjectID
    var errorDescription: String? {
        let code = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 255) }
        let fourCC = bytes.allSatisfy { (32...126).contains($0) } ? String(bytes: bytes, encoding: .ascii) : nil
        return "\(action): status=\(status)\(fourCC.map { " ('\($0)')" } ?? ""), object=\(object)"
    }
}

// Kept standalone deliberately: importing Aural's Audio.swift would also pull in
// its document, presets, and live route. Promotion should reuse the app's wrappers.
enum HAL {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func check(_ status: OSStatus, _ action: String, _ object: AudioObjectID = 0) throws {
        guard status == noErr else {
            throw HALFailure(status: status, action: action, object: object)
        }
    }
    static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var value = initial, size = UInt32(MemoryLayout<T>.size), property = address(selector, scope)
        try withUnsafeMutablePointer(to: &value) { try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0), "Read \(selector)", id) }
        guard size == MemoryLayout<T>.size else { throw ProbeFailure(message: "Wrong scalar size for property \(selector) on \(id)") }
        return value
    }
    static func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var size: UInt32 = 0, property = address(selector, scope)
        try check(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size), "Read list size \(selector)", id)
        guard size % 4 == 0 else { throw ProbeFailure(message: "Invalid object-list size on \(id)") }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        if size > 0 {
            try values.withUnsafeMutableBytes {
                guard let pointer = $0.baseAddress else { throw ProbeFailure(message: "Cannot allocate object list on \(id)") }
                try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, pointer), "Read list \(selector)", id)
            }
        }
        return Array(values.prefix(Int(size) / 4))
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size), property = address(selector)
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value), "Read string \(selector)", id)
        guard let value else { throw ProbeFailure(message: "Missing string \(selector) on \(id)") }
        return value.takeRetainedValue() as String
    }
    static func processIfPresent(_ pid: pid_t) throws -> AudioObjectID? {
        var pid = pid, value: AudioObjectID = 0, size: UInt32 = 4, property = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &value), "Resolve audio process")
        return value == kAudioObjectUnknown ? nil : value
    }
    static func process(_ pid: pid_t) throws -> AudioObjectID {
        guard let value = try processIfPresent(pid) else { throw ProbeFailure(message: "PID \(pid) has no Core Audio process object") }
        return value
    }
    static func validate(_ format: AudioStreamBasicDescription, rate: Double? = nil) throws {
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == kAudioFormatFlagsNativeEndian,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2, format.mFramesPerPacket == 1,
              format.mBytesPerFrame == (planar ? 4 : 8), format.mBytesPerPacket == format.mBytesPerFrame,
              format.mSampleRate.isFinite, (32000...192000).contains(format.mSampleRate), rate == nil || rate == format.mSampleRate else {
            throw UnsupportedProbeFormat(message: "Unsupported stream: rate=\(format.mSampleRate), channels=\(format.mChannelsPerFrame), flags=\(format.mFormatFlags)")
        }
    }
    static func format(_ stream: AudioObjectID) throws -> AudioStreamBasicDescription {
        try scalar(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
    }
}

struct DeviceInfo: Codable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let rate: Double
    let inputChannels: UInt32
    let transport: UInt32
    static func read(_ id: AudioObjectID, validateForCapture: Bool = true) throws -> Self {
        let outputs = try HAL.ids(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard let first = outputs.first else { throw ProbeFailure(message: "Output \(id) has no output stream") }
        let format = try HAL.format(first)
        if validateForCapture {
            guard outputs.count == 1 else { throw ProbeFailure(message: "Output \(id) does not have one stereo stream") }
            try HAL.validate(format)
        }
        let inputs = try HAL.ids(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        let inputChannels = try inputs.reduce(UInt32(0)) { try $0 + HAL.format($1).mChannelsPerFrame }
        return Self(id: id, uid: try HAL.string(id, kAudioDevicePropertyDeviceUID), name: try HAL.string(id, kAudioObjectPropertyName), rate: format.mSampleRate, inputChannels: inputChannels, transport: try HAL.scalar(id, kAudioDevicePropertyTransportType, UInt32(0)))
    }
    static func selected(_ uid: String?, validateForCapture: Bool = true) throws -> Self {
        if uid == "builtin" {
            for id in try HAL.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) {
                let transport = try HAL.scalar(id, kAudioDevicePropertyTransportType, UInt32(0))
                let outputs = try HAL.ids(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
                if transport == kAudioDeviceTransportTypeBuiltIn && !outputs.isEmpty { return try read(id, validateForCapture: validateForCapture) }
            }
            throw ProbeFailure(message: "No eligible built-in output is available")
        }
        if let uid, uid != "default" {
            for id in try HAL.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) {
                if try HAL.string(id, kAudioDevicePropertyDeviceUID) == uid { return try read(id, validateForCapture: validateForCapture) }
            }
            throw ProbeFailure(message: "Requested output UID is unavailable")
        }
        return try read(HAL.scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)), validateForCapture: validateForCapture)
    }
}

struct AudioProcessInfo: Codable {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let ownerBundleID: String?
    let name: String
    let identityNote: String?
    let outputDevices: [AudioObjectID]
    let runningOutput: Bool
    let instance: ProcessInstance?
    let ownershipSource: String
    let responsibleInstance: ProcessInstance?
    @MainActor static func read(_ object: AudioObjectID, ownership: OwnershipPolicy = .enclosingApp) throws -> Self {
        let pid = try HAL.scalar(object, kAudioProcessPropertyPID, pid_t(0))
        let initial = ProcessInstance.read(pid)
        let bundleID = try HAL.string(object, kAudioProcessPropertyBundleID)
        let app = NSRunningApplication(processIdentifier: pid)
        var ownerURL = app?.bundleURL, identityNote: String?
        if ownerURL == nil {
            var path = [CChar](repeating: 0, count: 4096)
            let result = probe_process_path(pid, &path, UInt32(path.count))
            if result > 0 { ownerURL = URL(fileURLWithPath: String(cString: path)) }
            else { identityNote = "Executable path unavailable (errno \(-result)); owner remains unattributed" }
        }
        var candidate = ownerURL
        // Resolve only the verified enclosing application path, never name substrings.
        while let url = candidate, url.path != "/" {
            if url.pathExtension == "app", Bundle(url: url)?.bundleIdentifier != nil { ownerURL = url }
            candidate = url.deletingLastPathComponent()
        }
        if ownerURL?.pathExtension != "app" { ownerURL = nil }
        var ownerBundleID = ownerURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        var ownershipSource = ownerBundleID == nil ? "unattributed" : "enclosing-app"
        var responsibleInstance: ProcessInstance?
        if initial.identity == nil {
            ownerBundleID = nil; ownershipSource = "unattributed"
            identityNote = "Process birth identity unavailable (errno \(initial.error)); owner remains unattributed"
        } else if ownerBundleID == nil, ownership == .experimentalResponsibility,
                  sharedWebKitBundleIDs.contains(bundleID), let helper = initial.identity {
            let resolved = experimentalWebKitOwner(pid: pid, helper: helper)
            ownerBundleID = resolved.bundleID; responsibleInstance = resolved.owner
            identityNote = resolved.note
            if ownerBundleID != nil { ownershipSource = "experimental-responsibility" }
        }
        if ownerBundleID == nil, identityNote == nil {
            identityNote = "No verified enclosing application; helper remains unattributed"
        }
        let outputDevices = try HAL.ids(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
        let runningOutput = try HAL.scalar(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0
        guard try HAL.scalar(object, kAudioProcessPropertyPID, pid_t(0)) == pid,
              initial.identity == ProcessInstance.read(pid).identity else {
            throw ProbeFailure(message: "Process identity changed while reading Core Audio object \(object)")
        }
        return Self(object: object, pid: pid, bundleID: bundleID, ownerBundleID: ownerBundleID,
                    name: app?.localizedName ?? (bundleID.isEmpty ? "Unattributed process \(pid)" : bundleID),
                    identityNote: identityNote, outputDevices: outputDevices, runningOutput: runningOutput,
                    instance: initial.identity, ownershipSource: ownershipSource, responsibleInstance: responsibleInstance)
    }
}

struct InventoryIssue: Codable {
    let object: AudioObjectID
    let status: OSStatus
    let detail: String
}
struct ProcessCatalog {
    let processes: [AudioProcessInfo]
    let issues: [InventoryIssue]
}

@MainActor func inventory(ownership: OwnershipPolicy = .enclosingApp) throws -> ProcessCatalog {
    var processes: [AudioProcessInfo] = [], issues: [InventoryIssue] = []
    for object in try HAL.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
        do { processes.append(try AudioProcessInfo.read(object, ownership: ownership)) }
        catch let failure as HALFailure where failure.status == kAudioHardwareBadObjectError && failure.object == object {
            // Process termination can invalidate a catalog entry between the
            // list read and its metadata read. Preserve that fact in the report;
            // all other errors still propagate. Playback requires a complete
            // preflight catalog so an unknown active mixer cannot be overlooked.
            let detail = "Process object became unavailable during inventory: " + failure.localizedDescription
            issues.append(InventoryIssue(object: object, status: failure.status, detail: detail))
            fputs(detail + "\n", stderr)
        }
    }
    return ProcessCatalog(processes: processes, issues: issues)
}

func writeJSON<T: Encodable>(_ value: T, to path: String?) throws {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    if let path { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
    else { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8)) }
}

func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

func outputDevices() throws -> [DeviceInfo] {
    var devices: [DeviceInfo] = []
    for id in try HAL.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) {
        if try !HAL.ids(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).isEmpty {
            devices.append(try DeviceInfo.read(id, validateForCapture: false))
        }
    }
    return devices
}

enum OutputReadiness {
    case waiting(String)
    case ready(DeviceInfo)
}

func readOutputReadiness(uid: String) throws -> OutputReadiness {
    var id: AudioObjectID = 0
    try HAL.check(probe_device_for_uid(uid as CFString, &id), "Resolve saved output UID")
    guard id != kAudioObjectUnknown else { return .waiting("The saved output is disconnected") }
    do {
        guard try HAL.scalar(id, kAudioDevicePropertyDeviceIsAlive, UInt32(0)) != 0 else {
            return .waiting("The saved output is disconnected")
        }
        let streams = try HAL.ids(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard !streams.isEmpty else { return .waiting("The saved output has no active output stream yet") }
        return .ready(try DeviceInfo.read(id))
    } catch let failure as HALFailure where isTransientOutputRead(failure.status) {
        return .waiting("The saved output is settling: " + failure.localizedDescription)
    } catch let failure as UnsupportedProbeFormat {
        return .waiting("Waiting for a supported stereo format: " + failure.localizedDescription)
    }
}
