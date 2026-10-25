import AppKit
import CoreAudio
import Foundation
import ProbeCore

struct Options {
    let command: String
    let values: [String: String]
    init() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let first = args.first, ["inventory", "devices", "inspect", "self-test", "handoff-test", "relaunch-test", "app-test", "recover-test", "guard-test", "tone"].contains(first), args.count % 2 == 1 else {
            throw ProbeFailure(message: "Usage: MixerProbe inventory|devices|inspect|self-test|handoff-test|relaunch-test|app-test|recover-test|guard-test|tone [--output UID] [--report PATH] [--pids PID,PID] [--playback monitor|owned|all] [--frequency HZ] [--duration SECONDS]")
        }
        var values: [String: String] = [:]
        let commandOptions: [String: Set<String>] = [
            "inventory": ["--output", "--report"], "devices": ["--report"],
            "recover-test": ["--output", "--bundle", "--gain", "--muted", "--duration", "--control", "--status", "--report", "--min-reconnects"],
            "guard-test": ["--output", "--bundle", "--reader", "--duration", "--report"],
            "app-test": ["--output", "--report", "--bundle", "--playback", "--phase-seconds"], "inspect": ["--output", "--report", "--pids", "--playback"],
            "self-test": ["--output", "--report", "--playback"], "handoff-test": ["--output", "--report", "--playback"],
            "relaunch-test": ["--output", "--report", "--playback", "--restore"],
            "tone": ["--output", "--frequency", "--duration", "--parent-pid"]]
        guard let allowed = commandOptions[first] else { throw ProbeFailure(message: "No options defined for command") }
        for index in stride(from: 1, to: args.count, by: 2) {
            guard allowed.contains(args[index]), values[args[index]] == nil else { throw ProbeFailure(message: "Unknown or repeated option: \(args[index])") }
            values[args[index]] = args[index + 1]
        }
        if ["self-test", "handoff-test", "relaunch-test", "app-test", "recover-test", "guard-test", "tone"].contains(first), values["--output"] == nil {
            throw ProbeFailure(message: "Choose an explicit --output builtin, default, or device UID for audio tests")
        }
        self.command = first; self.values = values
    }
    func number(_ key: String, default fallback: Double, range: ClosedRange<Double>) throws -> Double {
        guard let text = values[key] else { return fallback }
        guard let value = Double(text), value.isFinite, range.contains(value) else { throw ProbeFailure(message: "Invalid \(key): \(text)") }
        return value
    }
}

struct PhaseReport: Encodable {
    let name: String
    let capturedFrames: UInt32
    let toneAmplitudes: [[Double?]] // Each input lane, then the actual mixed output.
    let zeroLagUnityError: Double?
    let bestAlignedUnityError: Double?
    let bestLagFrames: Int
    let unityMismatchedFrames: UInt32
    let maximumUnityDifference: Double
}
struct Gate: Encodable {
    let name: String
    let passed: Bool
    let detail: String
}
struct BufferReport: Encodable {
    let channels: UInt32
    let bytes: UInt32
    let dataPresent: Bool
}
struct TransitionReport: Encodable { let name: String; let propertyUpdatesMilliseconds: Double }
struct RelaunchReport: Encodable { let strategy: String; let oldPID: pid_t; let newPID: pid_t; let oldObject: AudioObjectID; let newObject: AudioObjectID }
struct SessionReport: Encodable {
    let date: Date
    let os: String
    let playback: String
    let output: DeviceInfo
    let processes: [AudioProcessInfo]
    let inventoryIssues: [InventoryIssue]
    let lanes: [Lane]
    let phases: [PhaseReport]
    let transitions: [TransitionReport]
    let relaunch: RelaunchReport?
    let inputBuffers: [BufferReport]
    let outputBuffers: [BufferReport]
    let callbacks: UInt64
    let frames: UInt64
    let invalidBuffers: UInt64
    let nonfiniteSamples: UInt64
    let maximumCallbackMicroseconds: Double
    let gates: [Gate]
    let limitations: [String]
}

@MainActor final class ToneSource {
    let device: DeviceInfo
    private var context: OpaquePointer?
    private var callback: AudioDeviceIOProcID?
    init(device: DeviceInfo) { self.device = device }
    func start(frequency: Double) throws {
        guard let tone = probe_tone_create(device.rate, frequency, 0.005) else { throw ProbeFailure(message: "Cannot allocate quiet test source") }
        context = tone
        try HAL.check(AudioDeviceCreateIOProcID(device.id, probe_tone_callback, UnsafeMutableRawPointer(tone), &callback), "Create tone callback", device.id)
        guard let callback else { throw ProbeFailure(message: "HAL returned no tone callback") }
        try HAL.check(AudioDeviceStart(device.id, callback), "Start quiet tone", device.id)
    }
    func stop() throws {
        var failures: [String] = []
        if let callback {
            let stop = AudioDeviceStop(device.id, callback)
            if ![noErr, kAudioHardwareNotRunningError, kAudioHardwareBadDeviceError, kAudioHardwareBadObjectError].contains(stop) { failures.append("Stop source: \(stop)") }
            let remove = AudioDeviceDestroyIOProcID(device.id, callback)
            if [noErr, kAudioHardwareBadDeviceError, kAudioHardwareBadObjectError].contains(remove) { self.callback = nil }
            else { failures.append("Remove source callback: \(remove)") }
        }
        if callback == nil, let context { probe_tone_destroy(context); self.context = nil }
        if !failures.isEmpty { throw ProbeFailure(message: failures.joined(separator: "; ")) }
    }
}

@MainActor func sourceProcess(_ name: String, frequency: Double, device: DeviceInfo, duration: Double = 60) throws -> Process {
    let directory = Bundle.main.bundleURL.deletingLastPathComponent()
    let executable = directory.appendingPathComponent("AuralMixerSource\(name).app/Contents/MacOS/MixerProbe")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ProbeFailure(message: "Build the diagnostic source apps first: \(executable.path)") }
    let process = Process(); process.executableURL = executable
    process.arguments = ["tone", "--output", device.uid, "--frequency", "\(frequency)", "--duration", "\(duration)", "--parent-pid", "\(getpid())"]
    try process.run()
    do {
        let deadline = Date().addingTimeInterval(4)
        repeat {
            guard process.isRunning else { throw ProbeFailure(message: "Diagnostic source exited during startup") }
            if let object = try HAL.processIfPresent(process.processIdentifier),
               try HAL.scalar(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0 { return process }
            wait(0.02)
        } while Date() < deadline
        throw ProbeFailure(message: "Diagnostic source did not start audio within four seconds")
    } catch {
        if process.isRunning { process.terminate() }; process.waitUntilExit(); throw error
    }
}

@MainActor func session(_ options: Options, device: DeviceInfo) throws {
    guard let playback = Playback(rawValue: options.values["--playback"] ?? "monitor") else { throw ProbeFailure(message: "Invalid playback mode") }
    let restoreValue = options.values["--restore"] ?? "off"
    guard ["on", "off"].contains(restoreValue) else { throw ProbeFailure(message: "--restore must be on or off") }
    let restore = restoreValue == "on"
    if options.command == "relaunch-test", playback == .monitor { throw ProbeFailure(message: "relaunch-test requires --playback owned or all to test retained gain") }
    let existing = try playbackPreflight(device: device, playback: playback)

    let route = ProbeRoute(device: device)
    var children: [Process] = []
    var failure: Error?
    do {
        let objects: [AudioObjectID]
        if options.command != "inspect" {
            for (name, frequency) in zip(["A", "B", "C"], [431.0, 997.0, 1877.0]) {
                children.append(try sourceProcess(name, frequency: frequency, device: device))
            }
            objects = try children.prefix(2).map { try HAL.process($0.processIdentifier) }
        } else {
            guard let list = options.values["--pids"] else { throw ProbeFailure(message: "inspect requires --pids PID,PID") }
            let values = list.split(separator: ",", omittingEmptySubsequences: false)
            guard values.count == 2 else { throw ProbeFailure(message: "Supply exactly two PIDs") }
            objects = try values.map { text in
                guard let pid = pid_t(text), pid > 0 else { throw ProbeFailure(message: "Invalid PID: \(text)") }
                return try HAL.process(pid)
            }
        }
        try route.prepare(apps: objects.map { [$0] }, playback: playback, restore: restore)
        let topology = route.lanes
        if options.command == "inspect" {
            try writeJSON(topology, to: options.values["--report"])
        } else {
            let processes = try children.map { try AudioProcessInfo.read(HAL.process($0.processIdentifier)) }
            try route.start()
            guard let engine = route.engine else { throw ProbeFailure(message: "Missing prepared engine") }
            let steps: [(String, Float, Float)] = [("Unity", 1, 1), ("A at 50%", 0.5, 1), ("A muted", 0, 1), ("B at 50%", 1, 0.5), ("Unity restored", 1, 1)]
            for (phase, step) in steps.enumerated() {
                guard probe_set_gain(engine, 0, step.1), probe_set_gain(engine, 1, step.2), probe_set_phase(engine, UInt32(phase)) else {
                    throw ProbeFailure(message: "Engine rejected diagnostic controls")
                }
                fputs("Phase \(phase): \(step.0)\n", stderr)
                wait(1.6)
            }
            var phaseNames = steps.map { $0.0 }, transitions: [TransitionReport] = [], relaunch: RelaunchReport?
            if options.command == "handoff-test" {
                let third = try HAL.process(children[2].processIdentifier)
                for include in [true, false] {
                    let name = include ? "Remaining to app" : "App to remaining"
                    guard probe_set_phase_immediate(engine, UInt32(phaseNames.count)) else { throw ProbeFailure(message: "Cannot begin immediate handoff capture") }
                    phaseNames.append(name); wait(0.08)
                    transitions.append(TransitionReport(name: name, propertyUpdatesMilliseconds: try route.transferToFirstApp(third, include: include)))
                    wait(0.8)
                    guard probe_set_phase(engine, UInt32(phaseNames.count)) else { throw ProbeFailure(message: "Cannot begin settled handoff capture") }
                    phaseNames.append(name + " settled"); wait(1.1)
                }
            }
            if options.command == "relaunch-test" {
                guard probe_set_gain(engine, 0, 0.5), probe_set_phase(engine, 5) else { throw ProbeFailure(message: "Cannot prepare relaunch gain") }
                phaseNames.append("Before relaunch at 50%"); wait(1.1)
                let old = children[0]; old.terminate(); old.waitUntilExit(); wait(0.1)
                guard probe_set_phase_immediate(engine, 6) else { throw ProbeFailure(message: "Cannot begin relaunch capture") }
                phaseNames.append("Relaunch transition")
                let replacement = try sourceProcess("A", frequency: 431, device: device); children.append(replacement)
                let object = try HAL.process(replacement.processIdentifier)
                if !restore { try route.replaceFirstApp(object) }
                relaunch = RelaunchReport(strategy: restore ? "macOS 26 native restoration" : "explicit process replacement", oldPID: old.processIdentifier,
                                         newPID: replacement.processIdentifier, oldObject: objects[0], newObject: object)
                wait(0.8)
                guard probe_set_phase(engine, 7) else { throw ProbeFailure(message: "Cannot begin settled relaunch capture") }
                phaseNames.append("Relaunched at 50%"); wait(1.1)
            }
            try route.suspend()
            let counters = probe_counters(engine)
            let phases: [PhaseReport] = phaseNames.enumerated().map { index, name in
                let phase = UInt32(index)
                var best = Double.infinity, lag = 0
                for offset in -64...64 {
                    let value = probe_unity_error(engine, phase, 7, 3, Int32(offset))
                    if value < best { best = value; lag = offset }
                }
                let comparison = probe_compare(engine, phase, 7, 3, 0.000002)
                return PhaseReport(name: name, capturedFrames: probe_capture_count(engine, phase),
                    toneAmplitudes: (0...topology.count).map { source in
                        [431.0, 997.0, 1877.0].map { frequency in
                            let amplitude = probe_tone_amplitude(engine, phase, UInt32(source), 0, frequency)
                            return amplitude.isFinite ? amplitude : nil
                        }
                    }, zeroLagUnityError: finite(probe_unity_error(engine, phase, 7, 3, 0)), bestAlignedUnityError: finite(best), bestLagFrames: lag, unityMismatchedFrames: comparison.mismatchedFrames, maximumUnityDifference: comparison.maximumDifference)
            }
            var gates = [Gate(name: "Capture", passed: counters.frames > 0 && phases.allSatisfy { $0.capturedFrames >= 16000 }, detail: "Every phase must contain settled audio"),
                         Gate(name: "Callback buffers", passed: counters.invalidBuffers == 0 && counters.nonfiniteSamples == 0, detail: "No malformed buffers or non-finite samples"),
                         Gate(name: "Source identity", passed: Set(processes.map(\.bundleID)) == Set(["local.aural.mixer-sourcea", "local.aural.mixer-sourceb", "local.aural.mixer-sourcec"]) && processes.allSatisfy { $0.runningOutput && $0.outputDevices.contains(device.id) && $0.ownerBundleID == $0.bundleID }, detail: "Three expected diagnostic bundle identities actively playing on the selected output")]
            if let a = phases[0].toneAmplitudes[0][0], let b = phases[0].toneAmplitudes[1][1], let other = phases[0].toneAmplitudes[2][2] {
                let crossA = phases[0].toneAmplitudes[0][1] ?? .infinity, crossB = phases[0].toneAmplitudes[1][0] ?? .infinity
                gates.append(Gate(name: "Isolation", passed: a > 0.0001 && b > 0.0001 && other > 0.0001 && crossA < a * 0.001 && crossB < b * 0.001,
                                  detail: "A, B and the remaining source must be independently observable; cross-source leakage < -60 dB"))
            } else { gates.append(Gate(name: "Isolation", passed: false, detail: "Missing source measurements")) }
            let reference = probe_rms(engine, 0, 3, 0), error = phases[0].zeroLagUnityError ?? .infinity
            gates.append(Gate(name: "Unity reconstruction", passed: reference > 0.0001 && error / reference < 0.001,
                              detail: "Zero-lag source-sum error/reference RMS = \(error / max(reference, .leastNonzeroMagnitude)); tolerance < 0.001"))
            if playback != .monitor {
                let mixed = topology.count
                let baselineA = phases[0].toneAmplitudes[mixed][0] ?? 0, baselineB = phases[0].toneAmplitudes[mixed][1] ?? 0
                let halfA = phases[1].toneAmplitudes[mixed][0] ?? .infinity, muteA = phases[2].toneAmplitudes[mixed][0] ?? .infinity
                let unchangedB = phases[2].toneAmplitudes[mixed][1] ?? .infinity, halfB = phases[3].toneAmplitudes[mixed][1] ?? .infinity
                gates.append(Gate(name: "Independent volume", passed: baselineA > 0.0001 && baselineB > 0.0001 && abs(halfA / baselineA - 0.5) < 0.02 &&
                                  muteA < baselineA * 0.001 && abs(unchangedB / baselineB - 1) < 0.02 && abs(halfB / baselineB - 0.5) < 0.02 &&
                                  abs((phases[1].toneAmplitudes[mixed][1] ?? .infinity) / baselineB - 1) < 0.02 &&
                                  abs((phases[3].toneAmplitudes[mixed][0] ?? .infinity) / baselineA - 1) < 0.02 &&
                                  abs((phases[4].toneAmplitudes[mixed][0] ?? .infinity) / baselineA - 1) < 0.02 &&
                                  abs((phases[4].toneAmplitudes[mixed][1] ?? .infinity) / baselineB - 1) < 0.02,
                                  detail: "50% gain in each app, exact mute, and unaffected peer within 2%"))
                let remainingInput = phases[0].toneAmplitudes[2][2] ?? 0
                let remainingPass = remainingInput > 0.0001 && phases.prefix(5).allSatisfy { phase in
                    guard let amplitude = phase.toneAmplitudes[mixed][2] else { return false }
                    return playback == .all ? abs(amplitude / remainingInput - 1) < 0.02 : amplitude < remainingInput * 0.001
                }
                gates.append(Gate(name: "Remaining playback", passed: remainingPass,
                                  detail: playback == .all ? "Remaining source stays at unity through all gain/mute steps" : "Owned-only output does not replay the remaining source"))
            }
            if options.command == "handoff-test" {
                let transitionsPass = [5, 7].allSatisfy { phases[$0].unityMismatchedFrames == 0 && phases[$0].capturedFrames >= 16000 }
                gates.append(Gate(name: "Live ownership handoff", passed: transitionsPass,
                                  detail: "Immediate capture around both property updates; zero frames with sum/reference difference > 0.000002 required"))
                let added = phases[6].toneAmplitudes, removed = phases[8].toneAmplitudes
                gates.append(Gate(name: "Settled ownership", passed: (added[0][2] ?? 0) > 0.004 && (added[2][2] ?? .infinity) < 0.00001 &&
                                  (removed[0][2] ?? .infinity) < 0.00001 && (removed[2][2] ?? 0) > 0.004,
                                  detail: "The third source moves to App A and back to Remaining audio"))
            }
            if options.command == "relaunch-test" {
                let resumed = phases[7].toneAmplitudes
                let mixed = topology.count
                gates.append(Gate(name: "Relaunch identity", passed: relaunch.map { $0.oldPID != $0.newPID && $0.oldObject != $0.newObject } ?? false,
                                  detail: "A fresh diagnostic PID and HAL process replace the old source"))
                gates.append(Gate(name: "Relaunch routing and saved gain", passed: (resumed[0][0] ?? 0) > 0.004 && (resumed[2][0] ?? .infinity) < 0.00001 &&
                                  abs((resumed[mixed][0] ?? .infinity) / 0.005 - 0.5) < 0.02 &&
                                  abs((resumed[mixed][1] ?? .infinity) / 0.005 - 1) < 0.02,
                                  detail: "New source in its app lane, absent from Remaining, at the retained 50% gain; peer unchanged"))
            }
            let report = SessionReport(date: Date(), os: Foundation.ProcessInfo.processInfo.operatingSystemVersionString,
                playback: playback.rawValue, output: device, processes: processes, inventoryIssues: existing.issues, lanes: topology, phases: phases, transitions: transitions, relaunch: relaunch,
                inputBuffers: bufferReport(engine, input: true), outputBuffers: bufferReport(engine, input: false),
                callbacks: counters.callbacks, frames: counters.frames, invalidBuffers: counters.invalidBuffers,
                nonfiniteSamples: counters.nonfiniteSamples, maximumCallbackMicroseconds: Double(counters.maximumCallbackNanoseconds) / 1000,
                gates: gates, limitations: [relaunch == nil ? "App relaunch has not been exercised in this run" : "Relaunch covers a diagnostic app, not browser-helper churn or PID reuse", "No hardware loopback or end-to-end latency measurement", "Output statistics are the callback's rendered signal; they do not independently prove speaker playback", "Only this output and this run are represented"])
            try writeJSON(report, to: options.values["--report"])
            if gates.contains(where: { !$0.passed }) { throw ProbeFailure(message: "One or more routing gates failed; inspect the saved report") }
        }
    } catch { failure = error }
    do { try route.stop() } catch {
        failure = ProbeFailure(message: (failure.map { $0.localizedDescription + " Cleanup: " } ?? "") + error.localizedDescription)
    }
    for child in children where child.isRunning { child.terminate() }
    for child in children { child.waitUntilExit() }
    if let failure { throw failure }
}

func bufferReport(_ engine: OpaquePointer, input: Bool) -> [BufferReport] {
    (0..<min(probe_buffer_count(engine, input), 32)).map { index in
        let info = probe_buffer_info(engine, input, index)
        return BufferReport(channels: info.channels, bytes: info.bytes, dataPresent: info.dataPresent != 0)
    }
}

func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }

@main struct MixerProbe {
    @MainActor static func main() {
        do {
            let options = try Options()
            if options.command == "recover-test" { try recoverySession(options); return }
            let device = try DeviceInfo.selected(options.values["--output"], validateForCapture: !["inventory", "devices"].contains(options.command))
            switch options.command {
            case "inventory":
                struct Inventory: Encodable { let output: DeviceInfo; let processes: [AudioProcessInfo]; let issues: [InventoryIssue] }
                let catalog = try inventory()
                try writeJSON(Inventory(output: device, processes: catalog.processes, issues: catalog.issues), to: options.values["--report"])
            case "devices": try writeJSON(outputDevices(), to: options.values["--report"])
            case "app-test": try realAppSession(options, device: device)
            case "guard-test": try standaloneGuardSession(options, device: device)
            case "inspect", "self-test", "handoff-test", "relaunch-test": try session(options, device: device)
            case "tone":
                let frequency = try options.number("--frequency", default: 431, range: 40...10000)
                let duration = try options.number("--duration", default: 15, range: 1...900)
                var parent: pid_t?
                if let text = options.values["--parent-pid"] {
                    guard let value = pid_t(text), value > 0, value == getppid() else { throw ProbeFailure(message: "Invalid source parent PID") }
                    parent = value
                }
                let source = ToneSource(device: device)
                var failure: Error?
                do {
                    try source.start(frequency: frequency)
                    let deadline = Date().addingTimeInterval(duration)
                    while Date() < deadline {
                        if let parent, getppid() != parent { fputs("Diagnostic parent exited; stopping source\n", stderr); break }
                        wait(min(0.1, max(0, deadline.timeIntervalSinceNow)))
                    }
                } catch { failure = error }
                do { try source.stop() } catch { throw ProbeFailure(message: (failure.map { $0.localizedDescription + " Cleanup: " } ?? "") + error.localizedDescription) }
                if let failure { throw failure }
            default: throw ProbeFailure(message: "Unrecognized command")
            }
        } catch { fputs("MixerProbe: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}

@MainActor func playbackPreflight(device: DeviceInfo, playback: Playback) throws -> ProcessCatalog {
    if playback != .monitor {
        let transport = try HAL.scalar(device.id, kAudioDevicePropertyTransportType, UInt32(0))
        guard transport != kAudioDeviceTransportTypeVirtual && transport != kAudioDeviceTransportTypeAggregate else {
            throw ProbeFailure(message: "Playback diagnostics require a physical output; virtual and aggregate outputs are not validated")
        }
    }
    let existing = try inventory()
    // Another private aggregate may hide its physical subdevice from this
    // process. Conservatively reject an active Aural/probe on any output rather
    // than risk capturing two mixers into one another.
    guard existing.issues.isEmpty || playback == .monitor else {
        throw ProbeFailure(message: "Process inventory changed during preflight; retry after audio apps settle so conflicting mixers can be checked")
    }
    let conflicts = existing.processes.filter { process in
        let mixer = process.bundleID == "local.aural.equalizer" || process.bundleID == "local.aural.mixer-probe" ||
            process.bundleID.hasPrefix("local.aural.performance-preview")
        let eqMacOnOutput = process.bundleID == "com.bitgapp.eqmac" && process.outputDevices.contains(device.id)
        return process.pid != getpid() && process.runningOutput && (mixer || eqMacOnOutput)
    }
    guard conflicts.isEmpty || playback == .monitor else {
        throw ProbeFailure(message: "Another Aural/mixer is active, or eqMac is using this output. Use one diagnostic at a time after conflicting processing stops")
    }
    return existing
}
