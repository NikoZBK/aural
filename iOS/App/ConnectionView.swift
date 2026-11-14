import SwiftUI

struct ConnectionBar: View {
    @EnvironmentObject private var model: AuralModel
    @EnvironmentObject private var audio: ProbeAudio
    @State private var guide = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                AuralIcon(symbol: audio.connected ? "waveform" : "hifispeaker", color: audio.connected ? .auralAccent : .auralViolet)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if audio.connected { Circle().fill(Color.auralAccent).frame(width: 6, height: 6).accessibilityHidden(true) }
                        Text(audio.connected ? "Connected" : audio.preparing ? "Starting receiver…" : audio.running ? "Ready to connect" : "EQ stopped")
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                    }
                    Text(audio.running ? (audio.connected ? audio.route : "Choose Aural in Control Center") : "Start to listen through Aural")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Button("Connection help", systemImage: "questionmark.circle") { guide = true }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Button {
                    if audio.running || audio.preparing { model.stop() } else { model.play() }
                } label: {
                    Label(audio.preparing ? "Cancel" : audio.running ? "Stop" : "Start EQ", systemImage: audio.running || audio.preparing ? "stop.fill" : "play.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.glassProminent).controlSize(.large)
                Toggle("Bypass EQ", isOn: Binding(get: { model.state.bypass }, set: model.setBypass))
                    .toggleStyle(.button).buttonStyle(.glass).controlSize(.large)
                    .accessibilityHint("Keeps the route connected. Peak protection follows its separate setting.")
            }
        }.padding(14).modifier(GlassSurface())
            .sheet(isPresented: $guide) { ConnectionGuide() }
    }
}

struct ConnectionGuide: View {
    @EnvironmentObject private var model: AuralModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    AuralIcon(symbol: "waveform.path")
                    Text("Your music.\nYour sound.").font(.system(.largeTitle, design: .rounded).weight(.bold))
                    Text("Aural shapes audio from the app you already listen with. Your music app remains in charge of playback.").foregroundStyle(.secondary)
                    step("1", "Start Aural", "Use a low listening volume, then tap Start EQ. Allow the audio-session permission when asked. Aural never reads or records your microphone.")
                    step("2", "Choose the Aural output", "Play music. Swipe down from the top-right corner to open Control Center. Expand the playback control, tap its audio-output icon, and select Aural.")
                    step("3", "Make it yours", "Return here to adjust your EQ or choose a preset. Keep Aural running when switching outputs; you can reconnect while music keeps playing.")
                    ContentCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Keep Aural Route installed", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
                            Text("The small companion makes Aural available in the output picker. You only need to open Aural for everyday listening.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Text("To finish, choose your normal output in Control Center, then tap Stop in Aural. If headphones disconnect, Aural stops and asks you to reconnect.").font(.footnote).foregroundStyle(.secondary)
                    Button("Got it") { model.finishSetup(); dismiss() }.buttonStyle(.glassProminent).controlSize(.large).frame(maxWidth: .infinity)
                }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.background { AuralBackground() }.navigationTitle("Connect your music").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number).font(.headline.monospacedDigit()).frame(width: 32, height: 32).background(Color.auralAccent.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(detail).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AuralModel
    @State private var guide = false
    @State private var disableProtection = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Toggle("Peak protection", isOn: Binding(get: { model.state.library.peakProtectionEnabled }, set: { value in
                        if value { model.preference { $0.peakProtectionEnabled = true } } else { disableProtection = true }
                    }))
                    Toggle("Match comparison levels", isOn: Binding(get: { model.state.library.matchLevels }, set: { value in model.preference { $0.matchLevels = value } }))
                    Text("Peak protection limits excessive peaks, including in Bypass. Level matching estimates loudness for Bypass and A/B; it does not alter saved profiles.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Appearance") {
                    Picker("Theme", selection: Binding(get: { model.state.library.theme }, set: { value in model.preference { $0.theme = value } })) {
                        ForEach(AuralTheme.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Filter panel", selection: Binding(get: { model.state.library.filterPanelPosition }, set: { value in model.preference { $0.filterPanelPosition = value } })) {
                        ForEach(FilterPanelPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Text("The side panel appears when there is enough room. Smaller windows and large text sizes keep controls below the graph.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Support") {
                    Button("Connection guide", systemImage: "questionmark.circle") { guide = true }
                    NavigationLink("Audio diagnostics") { DiagnosticsView() }
                    if let problem = model.storageProblem {
                        Text(problem).foregroundStyle(.orange)
                        Button("Retry saved settings") { model.retryLoad() }
                    }
                }
                Section("About") {
                    LabeledContent("Aural for iOS", value: "0.2 · Development")
                    Text("The same EQ engine and profile format as Aural for Mac.").foregroundStyle(.secondary)
                    Link("AutoEQ project & license", destination: URL(string: "https://github.com/jaakkopasanen/AutoEq")!)
                    NavigationLink("Open-source notices") { NoticesView() }
                    Text("Profiles and audio diagnostics stay on this device unless you share them. AutoEQ searches download its public catalog from GitHub. Aural does not record audio.").font(.footnote).foregroundStyle(.secondary)
                }
            }.scrollContentBackground(.hidden).background { AuralBackground() }.navigationTitle("Settings")
                .sheet(isPresented: $guide) { ConnectionGuide() }
                .confirmationDialog("Turn off peak protection?", isPresented: $disableProtection, titleVisibility: .visible) {
                    Button("Turn off", role: .destructive) { model.preference { $0.peakProtectionEnabled = false } }
                } message: { Text("Boosted EQ can clip without protection. Lower the preamp to leave headroom.") }
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var audio: ProbeAudio
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(audio.status, systemImage: "waveform.path").font(.headline)
                ShareLink(item: audio.report) { Label("Share diagnostics", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
                Text(audio.report).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(20)
        }.navigationTitle("Audio diagnostics").navigationBarTitleDisplayMode(.inline)
    }
}

struct NoticesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Media-device driver reference").font(.headline)
                Text("Portions of the route driver are adapted from ios27-media-device-passthrough. Copyright © 2026 nemut.ai. Licensed under MIT No Attribution.")
                Text("Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so.")
                Text("THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.")
                Link("AutoEQ source and licensing", destination: URL(string: "https://github.com/jaakkopasanen/AutoEq/blob/master/LICENSE")!)
            }.font(.footnote).padding(20)
        }.navigationTitle("Notices")
    }
}
