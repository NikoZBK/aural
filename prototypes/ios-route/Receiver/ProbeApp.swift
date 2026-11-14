import SwiftUI

@main
struct AuralProbeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @StateObject private var audio = ProbeAudio(transportOnly: ProcessInfo.processInfo.arguments.contains("--transport-only-diagnostic"))
    #else
    @StateObject private var audio = ProbeAudio()
    #endif

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--network-source-diagnostic") {
                ReferenceSourceView(externalReceiver: true)
            } else if ProcessInfo.processInfo.arguments.contains("--reference-source-diagnostic") {
                ReferenceSourceView()
            } else {
                receiverView
            }
            #else
            receiverView
            #endif
        }
    }

    private var receiverView: some View {
        NavigationStack {
            Form {
                if audio.transportOnly {
                    Section("Silent diagnostic") {
                        Text("This test receives and discards audio without activating an audio session. Silence is expected when Aural is selected. Keep this app in the foreground and open Control Center from here.")
                    }
                }
                Section {
                    Label(audio.status, systemImage: audio.connected ? "waveform" : "antenna.radiowaves.left.and.right")
                    LabeledContent("Output", value: audio.route)
                    Button(audio.running || audio.preparing ? "Stop test" : "Prepare receiver") {
                        if audio.running || audio.preparing { audio.stop() } else { audio.prepare() }
                    }
                    .buttonStyle(.borderedProminent)
                } footer: {
                    Text(audio.transportOnly
                         ? "Play Spotify first, return here and prepare. Open Control Center and select Aural without pausing Spotify. Waiting without frames times out after 90 seconds."
                         : "At low volume, prepare here, play Spotify, then select Aural Route Probe in Control Center. Waiting without audio frames times out after 90 seconds.")
                }
                if !audio.transportOnly {
                    Section("Audible processing test") {
                        Toggle("Bypass EQ", isOn: $audio.bypass)
                        LabeledContent("Low-pass cutoff", value: "\(Int(audio.cutoff)) Hz")
                        Slider(value: $audio.cutoff, in: 100...18000, step: 100)
                            .accessibilityLabel("Low-pass cutoff")
                            .accessibilityValue("\(Int(audio.cutoff)) hertz")
                        Button("Set 1 kHz test filter") { audio.cutoff = 1000; audio.bypass = false }
                        Text("At 1 kHz the sound should become noticeably muffled. Bypass should restore the treble. Peak protection stays enabled in both states.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Signal") {
                        LabeledContent("Input", value: "\(audio.inputLevel) dBFS")
                        LabeledContent("Output", value: "\(audio.outputLevel) dBFS")
                    }
                }
                Section("Diagnostics") {
                    ShareLink("Share test report", item: audio.report)
                    Text(audio.diagnostics).font(.caption.monospaced()).textSelection(.enabled)
                    Text(audio.transportOnly
                         ? "Keep Spotify playing. Switch to iPhone Speaker and back to Aural. Check whether the route stays selected and received frames keep rising. No EQ or playback is active in this diagnostic."
                         : "Reconnect validation: keep Spotify playing, switch to iPhone Speaker, then select Aural Route Probe again. Check that received frames rise and Bypass EQ changes the sound. Save the report if it fails.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text(audio.transportOnly
                         ? "This diagnostic isolates routing from same-phone playback. It does not request microphone permission, play sound or store audio. Launch normally to return to the EQ test."
                         : "This is an audio-route experiment. Install Aural Route Provider separately. The receiver uses a microphone-capable session to keep playback separate, but never connects to the microphone or stores audio.")
                }
            }
            .navigationTitle("Aural Route Test")
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { audio.enteredBackground() }
            }
        }
    }
}
