import Foundation

// A deterministic, quiet PCM source for routing isolation. One second contains
// an integral number of cycles, so looping introduces no discontinuity.
enum ReferenceTone {
    static func waveData() -> Data {
        let rate: UInt32 = 48000
        let dataBytes = rate * 2
        var data = Data()
        func littleEndian<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); littleEndian(dataBytes + 36)
        data.append(contentsOf: "WAVEfmt ".utf8); littleEndian(UInt32(16))
        littleEndian(UInt16(1)); littleEndian(UInt16(1)) // PCM, mono
        littleEndian(rate); littleEndian(rate * 2)
        littleEndian(UInt16(2)); littleEndian(UInt16(16))
        data.append(contentsOf: "data".utf8); littleEndian(dataBytes)
        for frame in 0..<rate {
            let sample = Int16((sin(2 * .pi * 440 * Double(frame) / Double(rate)) * 819).rounded())
            littleEndian(sample)
        }
        return data
    }
}

#if os(iOS)
import AVFoundation
import MediaPlayer
import SwiftUI
import os

@MainActor
final class ReferenceSource: ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var status = "Ready to start the reference tone"
    private let log = Logger(subsystem: "local.aural.route-probe", category: "reference-source")
    private var player: AVAudioPlayer?
    private var sessionActive = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
            Task { @MainActor in
                guard let self, self.playing, context?.source != .app else { return }
                self.sessionActive = false
                self.fail("Reference source interrupted. Restart the control explicitly.")
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fail("Audio services reset. Restart the reference control.") }
        })
    }

    func start() {
        guard !playing else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // Match Spotify's logged long-form audio policy, using a stock player
            // and a local unprotected file instead of Spotify or streaming media.
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try session.setActive(true)
            sessionActive = true
            let newPlayer = try AVAudioPlayer(data: ReferenceTone.waveData())
            newPlayer.numberOfLoops = -1
            player = newPlayer
            guard newPlayer.prepareToPlay(), newPlayer.play() else {
                fail("The reference audio player could not start."); return
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: "Aural routing control",
                MPMediaItemPropertyArtist: "Quiet 440 Hz reference tone",
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
                MPNowPlayingInfoPropertyPlaybackRate: 1.0
            ]
            playing = true
            status = "Reference source playing · 440 Hz · −32 dBFS peak"
            log.notice("Reference source started: AVAudioPlayer, playback/longFormAudio, 48000 Hz mono PCM, looped 440 Hz at -32 dBFS peak.")
        } catch {
            let error = error as NSError
            fail("Reference source failed: \(error.domain) \(error.code) — \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop(); player = nil
        if playing { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        playing = false
        if sessionActive {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                sessionActive = false
            } catch {
                status = "Reference source stopped; audio deactivation failed: \(error.localizedDescription)"
                log.error("\(self.status, privacy: .public)")
                return
            }
        }
        status = "Reference source stopped"
        log.notice("Reference source stopped.")
    }

    private func fail(_ message: String) {
        stop()
        status = message
        log.error("\(message, privacy: .public)")
    }
}

struct ReferenceSourceView: View {
    var externalReceiver = false
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var receiver = ProbeAudio(transportOnly: true)
    @StateObject private var source = ReferenceSource()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(externalReceiver
                         ? "This sends a quiet local tone through Aural to the diagnostic receiver on your Mac. The Mac counts and discards the packets. There is no receiver on this iPhone, EQ or returned playback. Selecting Aural should silence the tone."
                         : "This replaces Spotify with a quiet local test tone using Apple’s audio player. The receiver discards incoming frames, so selecting Aural should silence the tone while its frame count rises. There is no EQ or returned playback.")
                    Text(source.status)
                    Button(source.playing || receiver.running ? "Stop control" : "Start reference control") {
                        if source.playing || receiver.running {
                            source.stop(); receiver.stop()
                        } else if externalReceiver {
                            source.start()
                        } else {
                            receiver.prepare()
                            if receiver.running {
                                source.start()
                                if !source.playing { receiver.stop() }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } header: {
                    Text("Independent source control")
                } footer: {
                    Text("Use low volume. Start here, then open Control Center from this app. Select Aural, switch to Speaker, then select Aural again while the reference source keeps playing.")
                }
                if externalReceiver {
                    Section("Mac receiver") {
                        Text("The Mac records connection and frame counts in its diagnostic log. There are no local received-frame counters for this test.")
                    }
                } else {
                    Section("Transport receiver") {
                        Text(receiver.status)
                        Text(receiver.diagnostics).font(.caption.monospaced()).textSelection(.enabled)
                        ShareLink("Share control report", item: "Reference source: \(source.status)\n\nReceiver component:\n\(receiver.report)")
                    }
                }
                Section {
                    Text(externalReceiver
                         ? "Keep this app in the foreground. Silence while Aural is selected is expected; an Unable to Connect alert is a routing failure. This diagnostic provider sends to the Mac until it is replaced with the normal build."
                         : "Keep this app in the foreground. Silence while Aural is selected is expected; an Unable to Connect alert is a routing failure. Regular launch returns to the Spotify EQ test.")
                }
            }
            .navigationTitle(externalReceiver ? "Aural Network Control" : "Aural Source Control")
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { source.stop(); receiver.enteredBackground() }
            }
        }
    }
}
#endif
