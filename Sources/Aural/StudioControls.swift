import SwiftUI

struct SessionNotices: View {
    @ObservedObject var model: Model
    var body: some View {
        if model.startupNotice != nil || model.error != nil || model.importNotice != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let notice = model.startupNotice {
                    HStack { AuralNotice(message: notice); Button("Cancel") { model.stop() }.buttonStyle(AuralButtonStyle()) }
                }
                if let message = model.error ?? model.importNotice {
                    HStack(alignment: .top, spacing: 4) {
                        AuralNotice(message: message, isError: model.error != nil)
                        Button { model.error = nil; model.importNotice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).padding(8).accessibilityLabel("Dismiss notice")
                    }
                }
            }
        }
    }
}

struct PresetBrowser: View {
    @ObservedObject var model: Model
    var submissions: PrecisionSubmissionCoordinator? = nil
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    var comfortable = false
    private func matches(_ name: String) -> Bool { search.isEmpty || name.localizedCaseInsensitiveContains(search) }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
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
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(AuralStyle.secondary).accessibilityHidden(true)
                TextField("Find a preset", text: $search).textFieldStyle(.plain).accessibilityLabel("Find a preset")
            }.auralFont(size: comfortable ? 14 : 11).padding(comfortable ? 11 : 8).background(AuralStyle.background, in: RoundedRectangle(cornerRadius: 5))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    group("Favorites", names: model.favoritePresets.sorted())
                    group("My presets", names: model.customPresets.filter { !model.favoritePresets.contains($0) })
                    group("Factory", names: model.factory.keys.sorted().filter { !model.favoritePresets.contains($0) })
                    if (Array(model.factory.keys) + model.customPresets).filter(matches).isEmpty {
                        Text("No matching presets").auralFont(size: comfortable ? 14 : 11).foregroundStyle(AuralStyle.secondary).padding(.vertical, 12)
                    }
                }
            }.auralFrame(maxHeight: .infinity)
        }
    }
    @ViewBuilder private func group(_ title: String, names: [String]) -> some View {
        let visible = names.filter(matches)
        if !visible.isEmpty {
            Text(title).auralFont(size: 11, weight: .medium)
                .foregroundStyle(AuralStyle.secondary).padding(.top, 9).padding(.bottom, 4)
            ForEach(visible, id: \.self) { name in
                Button {
                    switch submissions?.submitActive() ?? .unchanged {
                    case .rejected: return
                    case .submitted where model.error != nil: return
                    default: model.apply(name)
                    }
                } label: {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 1).fill(model.selectedPresetName == name ? AuralStyle.accent : .clear)
                            .auralFrame(width: 2, height: 18)
                        Text(name).auralFont(size: comfortable ? 15 : 12, weight: model.selectedPresetName == name ? .semibold : .regular)
                            .lineLimit(1).auralFrame(maxWidth: .infinity, alignment: .leading)
                        if model.favoritePresets.contains(name) { Image(systemName: "star.fill").auralFont(size: 8) }
                    }.foregroundStyle(Color.primary)
                        .padding(.horizontal, comfortable ? 11 : 7).auralFrame(height: comfortable ? 42 : 32)
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
        .padding(.horizontal, 10)
        .auralFrame(minWidth: 200, idealWidth: 300, maxWidth: 360)
        .auralFrame(height: 34)
        .background(AuralStyle.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AuralStyle.secondary.opacity(0.4)).allowsHitTesting(false))
        .accessibilityLabel("Preset")
        .accessibilityValue(model.currentPresetTitle)
        .help("Choose a preset, or manage your preset library")
    }

    @ViewBuilder private func group(_ title: String, names: [String]) -> some View {
        if !names.isEmpty {
            Section(title) {
                ForEach(names, id: \.self) { name in
                    Button {
                        switch submissions.submitActive() {
                        case .rejected: return
                        case .submitted where model.error != nil: return
                        default: model.apply(name)
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
            Button("Paste EQ") { if submitPendingInput() { model.pasteEQ() } }
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
                VStack(alignment: .leading, spacing: 12) {
                    Text("Save preset").auralFont(size: 13, weight: .semibold)
                    TextField("Preset name", text: $model.presetName).textFieldStyle(.roundedBorder)
                        .onSubmit { save() }
                    Button("Save") { save() }.buttonStyle(AuralButtonStyle(prominent: true))
                        .disabled(model.presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let error = model.error { AuralNotice(message: error, isError: true) }
                }.padding(18).auralFrame(width: 280).auralZoom(model)
            }
    }
    private func save() { model.savePreset(); if model.error == nil { saving = false } }
}

struct MonitorPanel: View {
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                OutputSelection(model: model, submissions: submissions)
                Divider().overlay(AuralStyle.border)
                PreampControls(model: model, submissions: submissions)
                Divider().overlay(AuralStyle.border)
                StudioMeter(meter: model.meter, running: model.running)
                Divider().overlay(AuralStyle.border)
                VStack(alignment: .leading, spacing: 9) {
                    AuralSectionLabel(title: "Audio processing")
                    stage("01", "Preamp & filters", detail: "\(model.profile.dspFilters(rate: model.responseRate).filter { !$0.disabled }.count) active bands")
                    stage("02", "Stereo & delay", detail: model.profile.stereoSettings == StereoSettings() ? "Neutral" : "Custom processing")
                    stage("03", "Peak protection", detail: "Both channels · always on")
                }
                Text("Bypass pauses EQ and stereo effects. Stop turns off audio processing.")
                    .auralFont(size: 10).foregroundStyle(AuralStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(16)
        }.background(AuralStyle.surface)
            .onDisappear { model.endProfileGesture() }
    }
    private func stage(_ number: String, _ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).auralFont(size: 9, design: .monospaced).foregroundStyle(AuralStyle.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).auralFont(size: 11, weight: .medium)
                Text(detail).auralFont(size: 9).foregroundStyle(AuralStyle.secondary)
            }
        }.padding(.vertical, 4)
    }

}

struct PreampControls: View {
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    var compact = false
    @ViewBuilder var body: some View {
        if compact {
            HStack(spacing: 7) {
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
        VStack(alignment: .leading, spacing: 12) {
            AuralSectionLabel(title: "Preamp")
            HStack(alignment: .firstTextBaseline, spacing: 5) {
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

struct OutputSelection: View {
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    @State private var selectionRevision = 0
    var comfortable = false
    var compact = false
    @ViewBuilder var body: some View {
        if compact {
            HStack(spacing: 7) {
                Image(systemName: "headphones").foregroundStyle(AuralStyle.secondary).accessibilityHidden(true)
                devicePicker
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).accessibilityLabel("Refresh outputs")
            }
        } else { expanded }
    }
    private var devicePicker: some View {
        Picker("Output device", selection: Binding(get: { model.selectedUID }, set: selectOutput)) {
            if model.selected == nil { Text("Select an output").tag(model.selectedUID) }
            ForEach(model.devices) { Text($0.name).tag($0.uid) }
        }.labelsHidden().auralFrame(maxWidth: compact ? nil : .infinity).auralControlSize(comfortable ? .large : .regular).id(selectionRevision)
            .help("Select the output used by your apps. Changing output stops EQ; it does not change the macOS default.")
    }
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 12) {
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
    @ObservedObject var meter: AudioMeter
    let running: Bool
    var compact = false
    @State private var heldPeak: Float = 0
    private var peak: Float { meter.peak }
    private var db: Double { running && peak > 0 ? 20 * log10(Double(peak)) : -90 }
    private var heldDB: String { heldPeak > 0 ? String(format: "%.1f", 20 * log10(Double(heldPeak))) : "−∞" }
    var body: some View {
        Group {
            if compact {
                HStack(spacing: 8) {
                    Text("Output").foregroundStyle(AuralStyle.secondary)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(AuralStyle.elevated)
                            Capsule().fill(db >= -1 ? AuralStyle.warning : AuralStyle.accent)
                                .auralFrame(width: geometry.size.width * min(1, max(0, (db + 60) / 60)))
                        }
                    }.auralFrame(width: 70, height: 5)
                        .accessibilityRepresentation { peakAccessibility }
                    Text(db > -90 ? String(format: "%.1f dBFS", db) : "−∞ dBFS").monospacedDigit().auralFrame(width: 74, alignment: .trailing)
                        .accessibilityHidden(true)
                    Button { heldPeak = running ? peak : 0 } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.plain).accessibilityLabel("Reset peak hold")
                        .accessibilityValue(heldPeak > 0 ? AuralAccessibility.samplePeak(20 * log10(Double(heldPeak))) : "Silent")
                        .help("Peak hold: \(heldDB) dBFS. Click to reset.")
                }.auralFont(size: 11)
            } else { expanded }
        }.onChange(of: peak) { _, value in if running { heldPeak = max(heldPeak, value) } }
            .onChange(of: running) { _, value in if !value { heldPeak = 0 } }
    }
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AuralSectionLabel(title: "Output level")
                Spacer()
                Text(db > -90 ? String(format: "%.1f", db) : "−∞").auralFont(size: 13, weight: .medium, design: .monospaced)
                Text("dBFS").auralFont(size: 9).foregroundStyle(AuralStyle.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(AuralStyle.background)
                    RoundedRectangle(cornerRadius: 2).fill(db >= -1 ? AuralStyle.warning : AuralStyle.accent)
                        .auralFrame(width: geometry.size.width * min(1, max(0, (db + 60) / 60)))
                    HStack(spacing: 0) { ForEach(0..<24, id: \.self) { _ in Spacer(minLength: 0); Rectangle().fill(AuralStyle.surface).auralFrame(width: 2) } }
                }
            }.auralFrame(height: 15).accessibilityRepresentation { peakAccessibility }
            HStack { Text("−60"); Spacer(); Text("−30"); Spacer(); Text("0 dBFS") }
                .auralFont(size: 9, design: .monospaced).foregroundStyle(AuralStyle.secondary)
            HStack {
                Text("Hold  \(heldDB) dBFS").auralFont(size: 10, design: .monospaced).foregroundStyle(AuralStyle.secondary)
                Spacer()
                Button { heldPeak = running ? peak : 0 } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).accessibilityLabel("Reset peak hold").help("Reset maximum output peak")
            }
        }
    }
    private var peakAccessibility: some View {
        ProgressView(value: min(1, max(0, (db + 60) / 60)))
            .accessibilityLabel("Output sample peak")
            .accessibilityValue(AuralAccessibility.samplePeak(db))
    }
}
