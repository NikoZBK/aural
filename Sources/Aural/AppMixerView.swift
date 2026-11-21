import SwiftUI

private struct AppMixerAppearanceKey: Equatable { let theme: AuralTheme; let zoom: AuralInterfaceZoom }

struct AppMixerWindow: View {
    @ObservedObject var model: Model
    var body: some View {
        AuralEquatableContent(key: AppMixerAppearanceKey(theme: model.theme, zoom: model.interfaceZoom)) {
            AppMixerView(store: model.appMixer, toggleProcessing: { model.toggleProcessing() })
                .auralZoom(model).auralAppearance(model.theme)
        }.equatable()
    }
}

struct AppMixerView: View {
    @ObservedObject var store: AppMixerStore
    let toggleProcessing: () -> Void
    @Environment(\.auralInterfaceScale) private var scale
    @StateObject private var submissions = PrecisionSubmissionCoordinator()
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16 * scale) {
                HStack(spacing: 16 * scale) {
                    VStack(alignment: .leading, spacing: 5 * scale) {
                        Label("App mixer", systemImage: "slider.horizontal.3").auralFont(size: 23, weight: .bold, design: .rounded)
                        Text(store.outputName).auralFont(size: 12).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8 * scale)
                    Button(store.active || store.waiting || store.starting ? "Stop EQ" : "Start EQ") {
                        if submit() { toggleProcessing() }
                    }.buttonStyle(AuralButtonStyle(prominent: !store.active && !store.waiting && !store.starting))
                        .help(AuralHelp.processing(store.active || store.waiting || store.starting))
                }
                Label(status, systemImage: store.active ? "waveform" : "info.circle")
                    .auralFont(size: 12).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("app-mixer-status")
                if let error = store.lifecycleError { AuralNotice(message: error, isError: true) }
                if let error = store.error, error != store.lifecycleError { AuralNotice(message: error, isError: true) }
                if let notice = store.capacityNotice { AuralNotice(message: notice, isError: true) }
                if let processor = store.competingProcessor {
                    AuralNotice(message: "\(processor) is processing this output. Quit it before starting Aural.", isError: false)
                }
                ScrollView {
                    LazyVStack(spacing: 12 * scale) {
                        if store.rows.isEmpty {
                            VStack(spacing: 12 * scale) {
                                Image(systemName: "app.badge.play").auralFont(size: 32).foregroundStyle(.secondary)
                                Text("Play something to see its app here.").auralFont(size: 15, weight: .medium)
                                Text("Aural remembers each app’s volume and mute. Opening this window does not start processing.")
                                    .auralFont(size: 12).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }.auralPadding(28).auralFrame(maxWidth: .infinity).auralPanel()
                        }
                        ForEach(store.rows) { row in
                            AppMixerStrip(row: row, store: store, submissions: submissions,
                                          compact: geometry.size.width < 600 * scale, active: store.active)
                        }
                    }.auralPadding(2)
                }
                VStack(alignment: .leading, spacing: 5 * scale) {
                    Text("Bypass keeps app levels and mute. Stop releases app control to macOS.")
                    Text("Safari support is experimental. Unidentified audio cannot be adjusted as an app.")
                    if store.unavailableCount > 0 {
                        Text("\(store.unavailableCount) audio source(s) could not be identified as an app. Their controls are unavailable.")
                    }
                    Text("Up to eight apps can be controlled at once. Levels apply only to this output.")
                }.auralFont(size: 11).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.auralPadding(20)
        }
        .frame(minWidth: 480 * scale, minHeight: 440 * scale)
        .focusedSceneValue(\.precisionSubmissions, submissions)
        // SwiftUI can keep a closed window's views alive without ever sending
        // onDisappear, so discovery follows the window itself.
        .background(WindowVisibility { store.setVisible($0) }).onDisappear { store.setVisible(false) }
        .auralAnnouncement(store.lifecycleError ?? store.error ?? store.capacityNotice)
    }
    private var status: String {
        if store.active { return store.bypassed ? "App levels active · EQ bypassed" : "App levels and EQ active" }
        if store.starting { return "Preparing audio. Saved levels will apply before playback starts." }
        if store.waiting { return "Waiting for the saved output. Levels and mute are remembered." }
        if store.globalOnly { return "This virtual output supports global EQ only. Select a physical output to apply app levels." }
        return "EQ stopped · values are saved, and app controls are inactive"
    }
    private func submit() -> Bool {
        switch submissions.submitActive() { case .rejected: return false; case .submitted, .unchanged: return true }
    }
}

private struct AppMixerStrip: View {
    @ObservedObject var row: AppMixerRow
    let store: AppMixerStore
    let submissions: PrecisionSubmissionCoordinator
    let compact: Bool
    let active: Bool
    @Environment(\.auralInterfaceScale) private var scale
    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12 * scale)) : AnyLayout(HStackLayout(spacing: 18 * scale))
        return layout {
            HStack(spacing: 10 * scale) {
                Color.clear.auralFrame(width: 34, height: 34).overlay {
                    if let icon = row.icon { Image(nsImage: icon).resizable() }
                }.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3 * scale) {
                    Text(row.state.name).auralFont(size: 14, weight: .semibold).lineLimit(2)
                    Text(row.state.experimental ? "\(activity) · Experimental" : activity).auralFont(size: 11).foregroundStyle(.secondary)
                    ProgressView(value: min(Double(row.peak), 1)).progressViewStyle(.linear)
                        .auralFrame(width: 54).accessibilityLabel("\(row.state.name) input activity")
                }
                if compact { Spacer(minLength: 0) }
            }.auralFrame(width: compact ? nil : 170, alignment: .leading)
            HStack(spacing: 10 * scale) {
                Slider(value: Binding(get: { row.setting.volume * 100 }, set: { store.setVolume(row.id, percent: $0) }), in: 0...100,
                       onEditingChanged: { editing in if !editing { store.setVolume(row.id, percent: row.setting.volume * 100, final: true) } })
                    .accessibilityLabel("\(row.state.name) volume")
                    .accessibilityValue("\(Int((row.setting.volume * 100).rounded())) percent\(row.setting.muted ? ", muted" : "")")
                    .auralFrame(minWidth: 90)
                    .help("Adjust \(row.state.name)'s volume from 0 to 100 percent on this output. Mute remembers the chosen volume.")
                PrecisionField(value: row.setting.volume * 100, range: 0...100, label: "\(row.state.name) exact volume in percent", decimals: 1,
                               currentRevision: { 0 }, submissions: submissions) { store.setVolume(row.id, percent: $0, final: true) }
                    .auralFrame(width: 58)
                Text("%").auralFont(size: 11).foregroundStyle(.secondary).accessibilityHidden(true)
                Button {
                    if submit() { store.setMuted(row.id, !row.setting.muted) }
                } label: {
                    Image(systemName: row.setting.muted ? "speaker.slash.fill" : "speaker.wave.2").auralFrame(width: 16)
                }
                    .buttonStyle(AuralButtonStyle(prominent: row.setting.muted))
                    .accessibilityLabel("\(row.setting.muted ? "Unmute" : "Mute") \(row.state.name)")
                    .accessibilityValue(row.setting.muted ? "Muted" : "Not muted")
                    .help("\(row.setting.muted ? "Unmute" : "Mute") \(row.state.name). The chosen volume is remembered.")
                Button { if submit() { store.reset(row.id) } } label: { Image(systemName: "arrow.counterclockwise").auralFrame(width: 16) }
                    .buttonStyle(AuralButtonStyle()).accessibilityLabel("Reset \(row.state.name) to 100 percent, unmute, and forget it")
                    .help("Reset \(row.state.name) to 100 percent volume and unmute it on this output. Aural then forgets the app until you adjust it again.")
            }.disabled(!row.state.controllable)
        }.auralPadding(14).auralPanel(padding: 0)
        .accessibilityElement(children: .contain)
    }
    private var activity: String {
        if AppAudioCatalog.competingProcessors.contains(row.id) { return "Other audio processor" }
        if !active { return "Saved · inactive" }
        if row.state.held { return "Silent · eight-app limit" }
        if row.state.playing { return row.state.applied ? (row.setting.muted ? "Muted" : "Playing") : (row.setting.neutral ? "Playing at 100%" : "Applying…") }
        return row.state.available ? "Quiet" : "Remembered"
    }
    private func submit() -> Bool {
        switch submissions.submitActive() { case .rejected: return false; case .submitted, .unchanged: return true }
    }
}

/// Reports whether the hosting window is actually on screen: false once it is
/// closed, minimized, or fully covered.
private struct WindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.onChange = onChange; return view }
    func updateNSView(_ view: Probe, context: Context) { view.onChange = onChange }
    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { onChange?(false); return }
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(closing), name: NSWindow.willCloseNotification, object: window)
            changed()
        }
        @objc private func changed() { onChange?(window?.occlusionState.contains(.visible) == true) }
        @objc private func closing() { onChange?(false) }
    }
}
