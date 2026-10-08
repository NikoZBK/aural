import SwiftUI

/// The workspace animates the space notices take; each notice also eases in from
/// the toolbar edge so it reads as attached to the window rather than popping in.
struct SessionNotices: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: Model
    var body: some View {
        if model.startupNotice != nil || model.error != nil || model.importNotice != nil {
            VStack(alignment: .leading, spacing: 8 * interfaceScale) {
                if let notice = model.startupNotice {
                    HStack { AuralNotice(message: notice); Button("Cancel") { model.stop() }.buttonStyle(AuralButtonStyle()) }
                        .transition(.auralReveal(reduceMotion: reduceMotion))
                }
                if let message = model.error ?? model.importNotice {
                    HStack(alignment: .top, spacing: 4 * interfaceScale) {
                        AuralNotice(message: message, isError: model.error != nil)
                        Button { model.error = nil; model.importNotice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).auralPadding(8).accessibilityLabel("Dismiss notice")
                    }.transition(.auralReveal(reduceMotion: reduceMotion))
                }
            }.transition(.auralReveal(reduceMotion: reduceMotion))
        }
    }
}

struct PresetBrowser: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    var submissions: PrecisionSubmissionCoordinator? = nil
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    var comfortable = false
    private func matches(_ name: String) -> Bool { search.isEmpty || name.localizedCaseInsensitiveContains(search) }
    var body: some View {
        VStack(alignment: .leading, spacing: 15 * interfaceScale) {
            HStack {
                AuralSectionLabel(title: "Presets")
                Spacer()
                Button { openWindow.showAuralWindow("presets") } label: {
                    if comfortable { Label("Library", systemImage: "square.stack").auralFont(size: 13) }
                    else { Image(systemName: "square.stack") }
                }
                    .buttonStyle(.plain).foregroundStyle(AuralStyle.secondary).accessibilityLabel("Manage preset library")
                    .help("Search, organize, and back up presets (⇧⌘P)")
            }
            HStack(spacing: 6 * interfaceScale) {
                Image(systemName: "magnifyingglass").foregroundStyle(AuralStyle.secondary).accessibilityHidden(true)
                TextField("Find a preset", text: $search).textFieldStyle(.plain).accessibilityLabel("Find a preset")
            }.auralFont(size: comfortable ? 14 : 11).auralPadding(comfortable ? 11 : 8).background(AuralStyle.background, in: RoundedRectangle(cornerRadius: 5))
            ScrollView {
                VStack(alignment: .leading, spacing: 4 * interfaceScale) {
                    group("Favorites", names: model.favoritePresets.sorted())
                    group("My presets", names: model.customPresets.filter { !model.favoritePresets.contains($0) })
                    group("Factory", names: model.factory.keys.sorted().filter { !model.favoritePresets.contains($0) })
                    if (Array(model.factory.keys) + model.customPresets).filter(matches).isEmpty {
                        Text("No matching presets").auralFont(size: comfortable ? 14 : 11).foregroundStyle(AuralStyle.secondary).auralPadding(.vertical, 12)
                    }
                }
            }.auralFrame(maxHeight: .infinity)
        }
    }
    @ViewBuilder private func group(_ title: String, names: [String]) -> some View {
        let visible = names.filter(matches)
        if !visible.isEmpty {
            Text(title).auralFont(size: 11, weight: .medium)
                .foregroundStyle(AuralStyle.secondary).auralPadding(.top, 9).auralPadding(.bottom, 4)
            ForEach(visible, id: \.self) { name in
                Button {
                    switch submissions?.submitActive() ?? .unchanged {
                    case .rejected: return
                    case .submitted where model.error != nil: return
                    default: withAuralAnimation { model.apply(name) }
                    }
                } label: {
                    HStack(spacing: 7 * interfaceScale) {
                        RoundedRectangle(cornerRadius: 1).fill(model.selectedPresetName == name ? AuralStyle.accent : .clear)
                            .auralFrame(width: 2, height: 18)
                        Text(name).auralFont(size: comfortable ? 15 : 12, weight: model.selectedPresetName == name ? .semibold : .regular)
                            .lineLimit(1).auralFrame(maxWidth: .infinity, alignment: .leading)
                        if model.favoritePresets.contains(name) { Image(systemName: "star.fill").auralFont(size: 8) }
                    }.foregroundStyle(Color.primary)
                        .auralPadding(.horizontal, comfortable ? 11 : 7).auralFrame(height: comfortable ? 42 : 32)
                        .background(model.selectedPresetName == name ? AuralStyle.elevated.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(name).accessibilityLabel("Apply preset \(name)")
                    .accessibilityValue(model.selectedPresetName == name ? "Selected" : "")
                    .contextMenu {
                        Button(model.favoritePresets.contains(name) ? "Remove favorite" : "Add favorite") { model.toggleFavorite(name) }
                        Button("Duplicate") { model.duplicatePreset(name) }
                        Button("Manage…") { openWindow.showAuralWindow("presets") }
                    }
            }
        }
    }
}

struct PresetSelection: View {
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            group("Favorites", names: model.favoritePresets.sorted())
            group("My presets", names: model.customPresets.filter { !model.favoritePresets.contains($0) })
            group("Factory", names: model.factory.keys.sorted().filter { !model.favoritePresets.contains($0) })
            Divider()
            Button("Manage presets…") { openWindow.showAuralWindow("presets") }
        } label: {
            Text(model.selectedPresetName ?? "Custom EQ")
                .auralFont(size: 13, weight: .medium).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .tint(.primary)
        .auralPadding(.horizontal, 10)
        .auralFrame(minWidth: 200, idealWidth: 300, maxWidth: 360)
        .auralFrame(height: 34)
        .background(AuralStyle.surface, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(AuralStyle.secondary.opacity(0.4)).allowsHitTesting(false))
        .accessibilityLabel("Preset")
        .accessibilityValue(model.currentPresetTitle)
        .help("\(model.currentPresetTitle)\nChoose a preset, or manage your preset library")
    }

    @ViewBuilder private func group(_ title: String, names: [String]) -> some View {
        if !names.isEmpty {
            Section(title) {
                ForEach(names, id: \.self) { name in
                    Button {
                        switch submissions.submitActive() {
                        case .rejected: return
                        case .submitted where model.error != nil: return
                        default: withAuralAnimation { model.apply(name) }
                        }
                    } label: {
                        if model.selectedPresetName == name {
                            Label(name, systemImage: "checkmark")
                        } else { Text(name) }
                    }
                }
            }
        }
    }
}

struct EQFileMenu: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    let submissions: PrecisionSubmissionCoordinator
    var body: some View {
        Menu {
            Button("Search AutoEQ profiles…") { if submitPendingInput() { openWindow.showAuralWindow("autoeq") } }
            Button("Import AutoEQ text…") { if submitPendingInput() { model.importAutoEQ() } }
            Button("Copy EQ") { if submitPendingInput() { model.copyEQ() } }
            Button("Paste EQ") { if submitPendingInput() { withAuralAnimation { model.pasteEQ() } } }
            Button("Export EQ text…") { if submitPendingInput() { model.exportEQ() } }
            Divider()
            Button("Back up presets…") { model.backupPresets() }
            Button("Restore presets…") { if submitPendingInput() { model.restorePresets() } }
        } label: { Label("Files", systemImage: "folder") }.auralFont(size: 11)
            .menuStyle(.borderlessButton)
            .tint(.primary)
            .fixedSize(horizontal: true, vertical: false)
            .help("Import, export, and back up your EQ and presets")
    }
    private func submitPendingInput() -> Bool {
        switch submissions.submitActive() {
        case .rejected: return false
        case .submitted: return model.error == nil
        case .unchanged: return true
        }
    }
}

struct SavePresetButton: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    @State private var saving = false
    var body: some View {
        Button("Save…") {
            switch submissions.submitActive() {
            case .rejected: return
            case .submitted where model.error != nil: return
            default: saving = true
            }
        }.buttonStyle(AuralButtonStyle()).accessibilityLabel("Save preset")
            .popover(isPresented: $saving) {
                VStack(alignment: .leading, spacing: 12 * interfaceScale) {
                    Text("Save preset").auralFont(size: 13, weight: .semibold)
                    TextField("Preset name", text: $model.presetName).textFieldStyle(.roundedBorder)
                        .onSubmit { save() }
                    Button("Save") { save() }.buttonStyle(AuralButtonStyle(prominent: true))
                        .disabled(model.presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let error = model.error { AuralNotice(message: error, isError: true) }
                }.auralPadding(18).auralFrame(width: 280).auralZoom(model)
            }
    }
    private func save() { model.savePreset(); if model.error == nil { saving = false } }
}

struct MonitorPanel: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21 * interfaceScale) {
                OutputSelection(model: model, submissions: submissions)
                Divider().overlay(AuralStyle.border)
                PreampControls(model: model, submissions: submissions)
                Divider().overlay(AuralStyle.border)
                StudioMeter(meter: model.meter, running: model.running,
                            protectionEnabled: Binding(get: { model.peakProtectionEnabled }, set: model.setPeakProtection))
                Divider().overlay(AuralStyle.border)
                VStack(alignment: .leading, spacing: 9 * interfaceScale) {
                    AuralSectionLabel(title: "Audio processing")
                    stage("01", "Preamp & filters", detail: "\(model.profile.dspFilters(rate: model.responseRate).filter { !$0.disabled }.count) active bands")
                    stage("02", "Stereo & delay", detail: model.profile.stereoSettings == StereoSettings() ? "Neutral" : "Custom processing")
                    stage("03", "Peak protection", detail: model.peakProtectionEnabled ? "Both channels · on" : "Off")
                }
                Text("Bypass pauses EQ and stereo effects. Stop turns off audio processing.")
                    .auralFont(size: 10).foregroundStyle(AuralStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }.auralPadding(16)
        }.background(AuralStyle.surface)
            .onDisappear { model.endProfileGesture() }
    }
    private func stage(_ number: String, _ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10 * interfaceScale) {
            Text(number).auralFont(size: 9, design: .monospaced).foregroundStyle(AuralStyle.secondary).auralPadding(.top, 2)
            VStack(alignment: .leading, spacing: 3 * interfaceScale) {
                Text(title).auralFont(size: 11, weight: .medium)
                Text(detail).auralFont(size: 9).foregroundStyle(AuralStyle.secondary)
            }
        }.auralPadding(.vertical, 4)
    }

}

struct PreampControls: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    var compact = false
    @ViewBuilder var body: some View {
        if compact {
            HStack(spacing: 7 * interfaceScale) {
                Text("Preamp").auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
                PrecisionField(value: model.profile.preamp, range: model.profile.preampRange, label: "Exact preamp in decibels", revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model] value in
                    model.endProfileGesture(); model.setPreamp(value)
                }.auralFrame(width: 68)
                Text("dB").auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
                Button(model.calculatingHeadroom ? "Calculating…" : "Auto") { if submitPendingInput() { model.headroom() } }
                    .buttonStyle(AuralButtonStyle()).disabled(model.calculatingHeadroom)
                    .accessibilityLabel("Auto preamp").help("Estimate a preamp level that leaves room for EQ boosts and stereo adjustments.")
            }
        } else { expanded }
    }
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 12 * interfaceScale) {
            AuralSectionLabel(title: "Preamp")
            HStack(alignment: .firstTextBaseline, spacing: 5 * interfaceScale) {
                Text(String(format: "%+.2f", model.profile.preamp)).auralFont(size: 30, weight: .light, design: .monospaced).monospacedDigit()
                Text("dB").auralFont(size: 12).foregroundStyle(AuralStyle.secondary)
            }
            Slider(value: Binding(get: { model.profile.preamp }, set: { value in if submitPendingInput() { model.setPreamp(value) } }), in: model.profile.preampRange,
                   onEditingChanged: { active in active ? model.beginProfileGesture(label: "Preamp") : model.endProfileGesture() })
                .accessibilityLabel("Preamp").accessibilityValue(String(format: "%.2f decibels", model.profile.preamp))
            HStack {
                PrecisionField(value: model.profile.preamp, range: model.profile.preampRange, label: "Exact preamp in decibels", revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model] value in
                    model.endProfileGesture()
                    model.setPreamp(value)
                }
                Text("dB").auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
            }
            Button { if submitPendingInput() { model.headroom() } } label: { Label(model.calculatingHeadroom ? "Calculating…" : "Auto preamp", systemImage: "arrow.down.to.line").auralFrame(maxWidth: .infinity) }
                .disabled(model.calculatingHeadroom)
                .buttonStyle(AuralButtonStyle()).help("Estimate a preamp level that leaves room for EQ boosts and stereo adjustments.")
        }
    }
    private func submitPendingInput() -> Bool {
        switch submissions.submitActive() {
        case .rejected: return false
        case .submitted: return model.error == nil
        case .unchanged: return true
        }
    }
}

/// One control that brightens or darkens the whole EQ around 1 kHz.
struct TiltControls: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    var body: some View {
        HStack(spacing: 7 * interfaceScale) {
            Text("Tilt").auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
            PrecisionField(value: model.profile.tilt, range: Profile.tiltRange, label: "Tilt in decibels", decimals: 1, revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model] value in
                model.endProfileGesture(); model.setTilt(value)
            }.auralFrame(width: 56)
            Text("dB").auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
            Stepper("Tilt", onIncrement: { if submitPendingInput() { model.adjustTilt(0.5) } },
                    onDecrement: { if submitPendingInput() { model.adjustTilt(-0.5) } })
                .labelsHidden().accessibilityLabel("Tilt").accessibilityValue(AuralAccessibility.decibels(model.profile.tilt))
        }.help("Tilt the EQ around 1 kHz. Positive values raise the treble and lower the bass, each by up to the amount set; negative values do the reverse.")
    }
    private func submitPendingInput() -> Bool {
        switch submissions.submitActive() {
        case .rejected: return false
        case .submitted: return model.error == nil
        case .unchanged: return true
        }
    }
}

struct OutputSelection: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    @State private var selectionRevision = 0
    var comfortable = false
    var compact = false
    @ViewBuilder var body: some View {
        if compact {
            HStack(spacing: 7 * interfaceScale) {
                Text("Output").auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
                devicePicker
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").auralFrame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Refresh outputs").help("Refresh audio devices")
            }
        } else { expanded }
    }
    private var devicePicker: some View {
        Picker("Output device", selection: Binding(get: { model.selectedUID }, set: selectOutput)) {
            if model.selected == nil { Text("Select an output").tag(model.selectedUID) }
            ForEach(model.devices) { Text($0.name).tag($0.uid) }
        }.labelsHidden().auralFrame(maxWidth: compact ? nil : .infinity).auralControlSize(comfortable ? .large : .regular).id(selectionRevision)
            .help("Select the output used by your apps. Changing output stops EQ; it does not change the macOS default. Follow macOS output in Settings switches automatically.")
    }
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 12 * interfaceScale) {
            HStack {
                AuralSectionLabel(title: "Output", systemImage: "hifispeaker")
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").auralFrame(width: comfortable ? 30 : 16, height: comfortable ? 28 : 16) }
                    .buttonStyle(.plain).foregroundStyle(AuralStyle.secondary).accessibilityLabel("Refresh outputs").help("Refresh audio devices")
            }
            devicePicker
            Text(comfortable ? "Choose the output your apps are using. Changing output stops EQ; press Start EQ when you are ready." : (model.running ? String(format: "Stereo · %g kHz", model.responseRate / 1000) : "Select output, then Start EQ"))
                .auralFont(size: comfortable ? 13 : 10).foregroundStyle(AuralStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func selectOutput(_ uid: String) {
        guard uid != model.selectedUID else { return }
        switch submissions.submitActive() {
        case .rejected: selectionRevision += 1; return
        case .submitted where model.error != nil: selectionRevision += 1; return
        default: break
        }
        model.select(uid)
        if model.selectedUID != uid { selectionRevision += 1 }
    }
}

struct StudioMeter: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var meter: AudioMeter
    let running: Bool
    @Binding var protectionEnabled: Bool
    var compact = false
    /// Compact only: protection sits beside the meter instead of below it.
    var inline = false
    @State private var heldPeak: Float = 0
    private var peak: Float { meter.peak }
    private var db: Double { running && peak > 0 ? 20 * log10(Double(peak)) : -90 }
    private var heldDB: String { heldPeak > 0 ? String(format: "%.1f", 20 * log10(Double(heldPeak))) : "−∞" }
    /// The bar spans −60 to 0 dB.
    private var level: Double { min(1, max(0, (db + 60) / 60)) }
    private let levelHelp = "Loudest sample leaving Aural, in dB below full scale (dBFS). 0 dB is the most the output can carry, so readings are negative, and loud music often peaks within a few dB of 0. Your Mac's volume is applied afterwards and doesn't move this meter."
    var body: some View {
        Group {
            if compact {
                let layout = inline ? AnyLayout(HStackLayout(spacing: 14 * interfaceScale))
                                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 5 * interfaceScale))
                layout {
                    HStack(spacing: 8 * interfaceScale) {
                        // "Level", not "Output": the window's output is the device picker.
                        Text("Level").foregroundStyle(AuralStyle.secondary)
                        ZStack {
                            // A translucent track stays visible on every surface in both appearances.
                            RoundedRectangle(cornerRadius: 1).fill(AuralStyle.grid.opacity(0.14))
                            MeterFill(fraction: level, cornerRadius: 1).fill(db >= -1 ? AuralStyle.warning : AuralStyle.accent)
                        }.auralFrame(minWidth: 70, maxWidth: inline ? 200 : 70, minHeight: 5, maxHeight: 5)
                            .help(levelHelp)
                            .accessibilityRepresentation { peakAccessibility }
                        Text(db > -90 ? String(format: "%.1f dB", db) : "−∞ dB").monospacedDigit().auralFrame(width: 58, alignment: .trailing)
                            .accessibilityHidden(true)
                        Button { heldPeak = running ? peak : 0 } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.plain).accessibilityLabel("Reset peak hold")
                            .accessibilityValue(heldPeak > 0 ? AuralAccessibility.samplePeak(20 * log10(Double(heldPeak))) : "Silent")
                            .help("Peak hold: \(heldDB) dB. Click to reset.")
                    }
                    if inline { Divider().auralFrame(height: 18) }
                    protection
                }.auralFont(size: 11)
            } else { expanded }
        }.onChange(of: peak) { _, value in if running { heldPeak = max(heldPeak, value) } }
            .onChange(of: running) { _, value in if !value { heldPeak = 0 } }
    }
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 12 * interfaceScale) {
            HStack {
                AuralSectionLabel(title: "Output level")
                Spacer()
                Text(db > -90 ? String(format: "%.1f", db) : "−∞").auralFont(size: 13, weight: .medium, design: .monospaced)
                Text("dB").auralFont(size: 9).foregroundStyle(AuralStyle.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(AuralStyle.background)
                MeterFill(fraction: level, cornerRadius: 2).fill(db >= -1 ? AuralStyle.warning : AuralStyle.accent)
                HStack(spacing: 0) { ForEach(0..<24, id: \.self) { _ in Spacer(minLength: 0); Rectangle().fill(AuralStyle.surface).auralFrame(width: 2) } }
            }.auralFrame(height: 15).help(levelHelp).accessibilityRepresentation { peakAccessibility }
            HStack { Text("−60"); Spacer(); Text("−30"); Spacer(); Text("0 dB") }
                .auralFont(size: 9, design: .monospaced).foregroundStyle(AuralStyle.secondary)
            HStack {
                Text("Hold  \(heldDB) dB").auralFont(size: 10, design: .monospaced).foregroundStyle(AuralStyle.secondary)
                Spacer()
                Button { heldPeak = running ? peak : 0 } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).accessibilityLabel("Reset peak hold").help("Reset maximum output peak")
            }
            protection
        }
    }
    private var protection: some View {
        let reducing = protectionEnabled && running && meter.reductionDB >= 0.05
        return HStack(spacing: 6 * interfaceScale) {
            Toggle(isOn: $protectionEnabled) {
                HStack(spacing: 6 * interfaceScale) {
                    Text("Peak protection")
                    Text(protectionEnabled ? "On" : "Off").monospacedDigit()
                }
            }.toggleStyle(.checkbox).auralControlSize(.small)
                .accessibilityLabel("Peak protection")
                .help("Limits true peaks, including those between samples, in both channels together, including Bypass. It eases the level down over 1 ms before each peak. Off allows peaks above full scale.")
            if reducing {
                Text(String(format: "Reducing %.1f dB", meter.reductionDB)).monospacedDigit()
                    .accessibilityLabel(String(format: "Reducing peaks by %.1f decibels", meter.reductionDB))
            } else if protectionEnabled && !running {
                Text("Ready")
            }
            Spacer(minLength: 0)
        }.auralFont(size: 10)
            .foregroundStyle(reducing ? AuralStyle.warning : AuralStyle.secondary)
    }
    private var peakAccessibility: some View {
        ProgressView(value: level)
            .accessibilityLabel("Output sample peak")
            .accessibilityValue(AuralAccessibility.samplePeak(db))
    }
}

/// The filled part of a level bar. It is drawn within the track's own frame, which interface
/// zoom has already scaled, so the fill can never run past the track.
private struct MeterFill: Shape {
    var fraction: Double
    var cornerRadius: CGFloat?
    func path(in rect: CGRect) -> Path {
        let filled = CGRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height)
        return cornerRadius.map { RoundedRectangle(cornerRadius: $0).path(in: filled) } ?? Capsule().path(in: filled)
    }
}
