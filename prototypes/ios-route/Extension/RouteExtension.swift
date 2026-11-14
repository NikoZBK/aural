import Foundation
import ExtensionFoundation
import MediaDevice
import Network
import UniformTypeIdentifiers
import os

@main
@MainActor
final class AuralRouteExtension: MediaDeviceExtension, RealtimeSampleHandling {
    // Must match the entitlements and exported type in Configuration/Extension.plist.
    var protocolType: UTType { UTType(exportedAs: "media-device-protocol.local.aural.route-probe") }
    var supportsSimultaneousSessions: Bool { false }
    lazy var routingManager: MediaDeviceRoutingManager = .routingManager(for: self)
    private let log = Logger(subsystem: "local.aural.route-probe", category: "extension")
    private var reportTimer: Timer?
    private var deliveryToken: UUID?
    private var activationTimer: Timer?
    private var activationToken: UUID?
    private var sessionID: String?

    // Stable across discovery, activation and app updates; also the HAL device UID.
    // Product branding must not replace an existing endpoint's identity.
    // Both targets retain the original UUID; iOS persists endpoint descriptors.
    private static let deviceID = (Bundle.main.object(forInfoDictionaryKey: "AuralRouteDeviceIdentifier") as? String)
        .flatMap { UUID(uuidString: $0) }
    private lazy var device: MediaOutputDevice? = {
        guard let deviceID = Self.deviceID else {
            log.error("Invalid route identity configuration.")
            return nil
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(ARPort)),
              let host = IPv4Address(ARRouteDriver.shared.receiverIPv4),
              ARRouteDriver.shared.transportStats.error == 0 else {
            log.error("Invalid receiver endpoint configuration.")
            return nil
        }
        return MediaOutputDevice(
            id: deviceID, displayName: ARRouteDriver.shared.deviceDisplayName,
            capabilities: [.realtimeAudioStreaming],
            canGroupWithCurrentlyActivatedDevices: false, deviceType: .hifiSpeaker,
            volumeControl: .none, canMute: false,
            requiredNetworkEndpoints: [.hostPort(host: .ipv4(host), port: port)],
            txtRecords: [], supportsSimultaneousSessions: false
        )
    }()

    required init() {
        log.notice("Extension started: pid=\(ProcessInfo.processInfo.processIdentifier) build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown", privacy: .public) route=\(Self.deviceID?.uuidString ?? "invalid", privacy: .public)")
    }

    func startDeviceDiscovery() {
        log.notice("Discovery started: active=\(self.sessionID ?? "none", privacy: .public)")
        guard let device else {
            log.error("Could not create the audio route.")
            routingManager.discoveryFailed(MediaDeviceError(.discoveryFailed))
            return
        }
        routingManager.foundDevice(device)
    }
    func stopDeviceDiscovery() {
        // This callback means the picker closed, not that the endpoint vanished.
        // There is no network scan to stop for this fixed test endpoint. Keep
        // the system's discovered-device cache until the device is actually lost.
        log.notice("Discovery stopped; fixed device remains available: active=\(self.sessionID ?? "none", privacy: .public)")
    }
    func activateDevice(_ device: MediaOutputDevice, session: MediaOutputSession,
                        for deviceFeatures: MediaOutputDevice.Capabilities) {
        log.notice("Activation requested: session=\(session.id, privacy: .public) features=\(deviceFeatures.rawValue)")
        guard device.id == Self.deviceID, sessionID == nil || sessionID == session.id else {
            log.error("Unsupported device or simultaneous session.")
            routingManager.failedToActivateDevice(device, session: session, error: MediaDeviceError(.connectionFailed))
            return
        }
        guard activationToken == nil else {
            log.notice("Duplicate activation while receiver connection is pending; preserving the original request.")
            return
        }
        sessionID = session.id
        let result = ARRouteDriver.shared.prepareTransport()
        guard result == 0 else {
            failActivation(device, session: session, reason: "Could not start receiver connection", code: result)
            return
        }
        let token = UUID()
        activationToken = token
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        log.notice("Waiting for receiver connection before activation: session=\(session.id, privacy: .public)")
        activationTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkActivation(device, session: session, token: token, deadline: deadline)
            }
        }
        checkActivation(device, session: session, token: token, deadline: deadline)
    }
    private func checkActivation(_ device: MediaOutputDevice, session: MediaOutputSession,
                                 token: UUID, deadline: ContinuousClock.Instant) {
        guard activationToken == token, sessionID == session.id else {
            log.debug("Ignoring a canceled receiver-readiness check.")
            return
        }
        let transport = ARRouteDriver.shared.transportStats
        guard transport.active else {
            failActivation(device, session: session, reason: "Receiver transport stopped", code: ENOTCONN)
            return
        }
        guard transport.error == 0 else {
            failActivation(device, session: session, reason: "Receiver connection failed", code: transport.error)
            return
        }
        guard transport.connected else {
            if ContinuousClock.now >= deadline {
                failActivation(device, session: session, reason: "Receiver connection timed out", code: ETIMEDOUT)
            }
            return
        }
        activationTimer?.invalidate(); activationTimer = nil; activationToken = nil
        log.notice("Receiver connected; reporting activation: session=\(session.id, privacy: .public)")
        routingManager.activatedDevice(device, session: session)
        log.notice("Activation report returned: session=\(session.id, privacy: .public)")
    }
    private func failActivation(_ device: MediaOutputDevice, session: MediaOutputSession,
                                reason: String, code: Int32) {
        log.error("\(reason, privacy: .public): errno=\(code) session=\(session.id, privacy: .public)")
        stopCapture()
        sessionID = nil
        routingManager.failedToActivateDevice(device, session: session, error: MediaDeviceError(.connectionFailed))
    }
    func deactivateDevice(_ device: MediaOutputDevice, session: MediaOutputSession) {
        log.notice("Deactivation requested: session=\(session.id, privacy: .public) active=\(self.sessionID ?? "none", privacy: .public)")
        guard sessionID == session.id else { log.error("Deactivation for an unknown session."); return }
        stopCapture()
        sessionID = nil
        log.notice("Route deactivated; sample transport stopped.")
    }
    func startRealtimeSampleDelivery(session: MediaOutputSession) {
        log.notice("Sample delivery requested: session=\(session.id, privacy: .public) active=\(self.sessionID ?? "none", privacy: .public)")
        guard let deviceID = Self.deviceID, sessionID == session.id else {
            log.error("Sample delivery for an inactive session.")
            routingManager.sessionFailed(session, error: MediaDeviceError(.sessionFailed))
            return
        }
        guard activationToken == nil else {
            log.error("Sample delivery requested before receiver readiness.")
            stopCapture()
            sessionID = nil
            routingManager.sessionFailed(session, error: MediaDeviceError(.sessionFailed))
            return
        }
        // Apple's real-time streaming contract publishes the driver here,
        // after activation, rather than from activateDevice(_:session:for:).
        let publication = ARRouteDriver.shared.publish(withDeviceUID: deviceID.uuidString)
        guard publication == 0 else {
            log.error("Driver publication failed: OSStatus=\(publication)")
            stopCapture()
            routingManager.sessionFailed(session, error: MediaDeviceError(.sessionFailed))
            return
        }
        let result = ARRouteDriver.shared.startCapture()
        guard result == 0 else {
            log.error("Could not start the transport: errno=\(result)")
            stopCapture()
            routingManager.sessionFailed(session, error: MediaDeviceError(.sessionFailed))
            return
        }
        log.notice("Sample delivery started: session=\(session.id, privacy: .public)")
        reportTimer?.invalidate()
        let delivery = UUID()
        deliveryToken = delivery
        reportTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.deliveryToken == delivery else {
                    self.log.debug("Ignoring a report from stopped sample delivery.")
                    return
                }
                let driver = ARRouteDriver.shared
                let stats = driver.transportStats
                self.log.notice("Captured=\(driver.framesDelivered) sent=\(stats.transferredFrames) connected=\(stats.connected) dropped=\(stats.droppedFrames) errno=\(stats.error)")
                if !driver.registered {
                    self.stopCapture()
                    self.routingManager.sessionFailed(session, error: MediaDeviceError(.sessionFailed))
                }
            }
        }
    }
    func stopRealtimeSampleDelivery(session: MediaOutputSession) {
        log.notice("Sample delivery stop requested: session=\(session.id, privacy: .public) active=\(self.sessionID ?? "none", privacy: .public)")
        stopCapture()
    }
    private func stopCapture() {
        if activationToken != nil { log.notice("Canceled pending receiver activation.") }
        activationTimer?.invalidate(); activationTimer = nil; activationToken = nil
        reportTimer?.invalidate(); reportTimer = nil; deliveryToken = nil
        ARRouteDriver.shared.stopCapture()
    }

    // These capabilities are deliberately not advertised by this probe.
    func connectUsingPairingCode(_ pairingCode: String?, to device: MediaOutputDevice, session: MediaOutputSession) {
        log.error("Pairing requested for a route without pairing support.")
        routingManager.failedToActivateDevice(device, session: session, error: MediaDeviceError(.connectionFailed))
    }
    func setVolume(_ volume: Float, for device: MediaOutputDevice) { log.notice("Volume is managed by the physical output.") }
    func volume(for device: MediaOutputDevice) -> Float { 1 }
    func changeVolume(by increments: Int, for device: MediaOutputDevice) { log.notice("Volume is managed by the physical output.") }
    func muteDevice(_ device: MediaOutputDevice) { log.notice("Mute is not advertised by this route.") }
    func isDeviceMuted(_ device: MediaOutputDevice) -> Bool { false }
    func startSession(_ session: MediaOutputSession, identifier: String?, url: URL) {
        log.error("URL playback is unsupported; this probe accepts real-time audio only.")
        routingManager.sessionFailed(session, error: MediaDeviceError(.sessionFailed))
    }
    func stopSession(_ session: MediaOutputSession) {
        log.notice("Playback stop requested: session=\(session.id, privacy: .public) active=\(self.sessionID ?? "none", privacy: .public)")
        stopCapture()
    }
    func sendData(_ data: Data, toApplication applicationIdentifier: String, session: MediaOutputSession) {
        log.error("Application messaging is unsupported.")
        routingManager.sessionFailed(session, error: MediaDeviceError(.sessionFailed))
    }
}
