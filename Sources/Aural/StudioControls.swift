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
                    HStack { AuralNotice(message: notice); Button("Cancel") { model.stop() }.buttonStyle(AuralButtonStyle()).help("Cancel the pending automatic EQ start.") }
                        .transition(.auralReveal(reduceMotion: reduceMotion))
                }
                if let message = model.error ?? model.importNotice {
                    HStack(alignment: .top, spacing: 4 * interfaceScale) {
                        AuralNotice(message: message, isError: model.error != nil)
                        Button { model.error = nil; model.importNotice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).auralPadding(8).accessibilityLabel("Dismiss notice")
                            .help("Dismiss this notice.")
                    }.transition(.auralReveal(reduceMotion: reduceMotion))
                }
            }.transition(.auralReveal(reduceMotion: reduceMotion))
        }
    }
}

struct PresetBrowser: View {
    @Environment(\.auralPalette) private var palette
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
                    .help("Filter presets by name.")
            }.auralFont(size: comfortable ? 14 : 11).auralPadding(comfortable ? 11 : 8).background(palette.field, in: RoundedRectangle(cornerRadius: 5))
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
                        .background(model.selectedPresetName == name ? palette.elevated.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(AuralHelp.applyPreset(name)).accessibilityLabel("Apply preset \(name)")
                    .accessibilityValue(model.selectedPresetName == name ? "Selected" : "")
                    .contextMenu {
                        Button(model.favoritePresets.contains(name) ? "Remove favorite" : "Add favorite") { model.toggleFavorite(name) }.help(model.favoritePresets.contains(name) ? "Remove this preset from favorites." : "Add this preset to favorites.")
                        Button("Duplicate") { model.duplicatePreset(name) }.help("Create a separate copy of this preset.")
                        Button("Manage…") { openWindow.showAuralWindow("presets") }.help(AuralHelp.presetLibrary)
                    }
            }
        }
    }
}

struct PresetSelection: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        AuralEquatableContent(key: PresetSelectionKey(factory: model.factory.keys.sorted(), custom: model.customPresets,
                                                      favorites: model.favoritePresets, title: model.currentPresetTitle,
                                                      selected: model.selectedPresetName, scale: interfaceScale)) {
        Menu {
            group("Favorites", names: model.favoritePresets.sorted())
            group("My presets", names: model.customPresets.filter { !model.favoritePresets.contains($0) })
            group("Factory", names: model.factory.keys.sorted().filter { !model.favoritePresets.contains($0) })
            Divider()
            Button("Manage presets…") { openWindow.showAuralWindow("presets") }.help(AuralHelp.presetLibrary)
            PresetDeletionMenuItems(model: model, submissions: submissions)
        } label: {
            Text(model.selectedPresetName ?? "Custom EQ").lineLimit(1)
        }
        .auralMenuButton()
        .auralFrame(maxWidth: .infinity)
        .accessibilityLabel("Preset")
        .accessibilityValue(model.currentPresetTitle)
        .help("\(model.currentPresetTitle)\nChoose a preset, or manage your preset library")
        }.equatable()
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
                    }.help(AuralHelp.applyPreset(name))
                }
            }
        }
    }
}

private struct PresetSelectionKey: Equatable {
    let factory: [String]
    let custom: [String]
    let favorites: Set<String>
    let title: String
    let selected: String?
    let scale: CGFloat
}

struct EQFileMenu: View {
    let model: Model
    @Environment(\.openWindow) private var openWindow
    let submissions: PrecisionSubmissionCoordinator
    var body: some View {
        Menu {
            Button("Search AutoEQ profiles…") { if submitPendingInput() { openWindow.showAuralWindow("autoeq") } }.help(AuralHelp.autoEQ)
            Button("Import AutoEQ text…") { if submitPendingInput() { model.importAutoEQ() } }.help("Choose an Equalizer APO text file or paste AutoEQ text to import.")
            Button("Copy EQ") { if submitPendingInput() { model.copyEQ() } }.help(AuralHelp.copyEQ)
            Button("Paste EQ") { if submitPendingInput() { withAuralAnimation { model.pasteEQ() } } }.help(AuralHelp.pasteEQ)
            Button("Export EQ text…") { if submitPendingInput() { model.exportEQ() } }.help(AuralHelp.exportEQ)
            Divider()
            Button("Back up presets…") { model.backupPresets() }.help("Export custom presets and favorites to a backup file.")
            Button("Restore presets…") { if submitPendingInput() { model.restorePresets() } }.help("Import presets and favorites from a backup file.")
        } label: { Label("Files", systemImage: "folder").auralFrame(maxWidth: .infinity) }
            .auralMenuButton(.small)
            .tint(.primary)
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
        Button {
            switch submissions.submitActive() {
            case .rejected: return
            case .submitted where model.error != nil: return
            default: saving = true
            }
        } label: {
            Text("Save…").auralFrame(maxWidth: .infinity)
        }.buttonStyle(AuralButtonStyle()).accessibilityLabel("Save preset")
            .help("Save the current EQ as a named preset.")
            .popover(isPresented: $saving) {
                VStack(alignment: .leading, spacing: 12 * interfaceScale) {
                    Text("Save preset").auralFont(size: 13, weight: .semibold)
                    TextField("Preset name", text: $model.presetName).textFieldStyle(.roundedBorder)
                        .help("Enter a name for the current EQ. Press Return to save.")
                        .onSubmit { save() }
                    Button("Save") { save() }.buttonStyle(AuralButtonStyle(prominent: true))
                        .help("Save the current EQ with this preset name.")
                        .disabled(model.presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let error = model.error { AuralNotice(message: error, isError: true) }
                }.auralPadding(18).auralFrame(width: 280).auralZoom(model)
            }
    }
    private func save() { model.savePreset(); if model.error == nil { saving = false } }
}

struct MonitorPanel: View {
    @Environment(\.auralPalette) private var palette
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
                            protectionEnabled: Binding(get: { model.peakProtectionEnabled }, set: model.setPeakProtection),
                            resetHolds: model.resetLevelHolds)
                Divider().overlay(AuralStyle.border)
                VStack(alignment: .leading, spacing: 9 * interfaceScale) {
                    AuralSectionLabel(title: "Audio processing")
                    stage("01", "Preamp & filters", detail: "\(model.profile.filters?.filter(\.enabled).count ?? GraphicEQ.frequencies.filter { $0 < model.responseRate * 0.49 }.count) active bands")
                    stage("02", "Stereo & delay", detail: model.profile.stereoSettings == StereoSettings() ? "Neutral" : "Custom processing")
                    stage("03", "Peak protection", detail: model.peakProtectionEnabled ? "Both channels · on" : "Off")
                }
                Text("Bypass pauses EQ and stereo effects. Stop turns off audio processing.")
                    .auralFont(size: 10).foregroundStyle(AuralStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }.auralPadding(16)
        }.background(palette.surface)
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

/// Keep the two numeric controls in the rail on the same label, value, and unit columns.
private struct ToneControlRow<Field: View, Action: View>: View {
    @Environment(\.auralInterfaceScale) private var scale
    let title: String
    let help: String
    @ViewBuilder let field: () -> Field
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: 6 * scale) {
            Text(title).help(help).auralFrame(width: 42, alignment: .leading)
            field().auralFrame(width: 64)
            Text("dB").auralFrame(maxWidth: .infinity, alignment: .leading)
            action().auralFrame(width: 54, alignment: .trailing)
        }.auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
    }
}

struct PreampControls: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    var compact = false
    @ViewBuilder var body: some View {
        if compact {
            ToneControlRow(title: "Preamp", help: AuralHelp.preamp) {
                PrecisionField(value: model.profile.preamp, range: model.profile.preampRange, label: "Exact preamp in decibels", revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model] value in
                    model.endProfileGesture(); model.setPreamp(value)
                }
            } action: {
                Button { if submitPendingInput() { model.headroom() } } label: {
                    Text(model.calculatingHeadroom ? "…" : "Auto").auralFrame(maxWidth: .infinity)
                }
                    .buttonStyle(AuralButtonStyle()).disabled(model.calculatingHeadroom)
                    .accessibilityLabel("Auto preamp")
                    .accessibilityValue(model.calculatingHeadroom ? "Calculating" : "")
                    .help(model.calculatingHeadroom ? "Calculating preamp headroom…" : "Estimate a preamp level that leaves room for EQ boosts and stereo adjustments.")
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
                .help(AuralHelp.preamp)
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
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    var body: some View {
        ToneControlRow(title: "Tilt", help: AuralHelp.tilt) {
            PrecisionField(value: model.profile.tilt, range: Profile.tiltRange, label: "Tilt in decibels", decimals: 1, revision: model.editRevision, currentRevision: { [model] in model.editRevision }, submissions: submissions) { [model] value in
                model.endProfileGesture(); model.setTilt(value)
            }
        } action: {
            Stepper("Tilt", onIncrement: { if submitPendingInput() { model.adjustTilt(0.5) } },
                    onDecrement: { if submitPendingInput() { model.adjustTilt(-0.5) } })
                .labelsHidden().accessibilityLabel("Tilt").accessibilityValue(AuralAccessibility.decibels(model.profile.tilt))
                .help("Adjust tilt in 0.5 dB steps. " + AuralHelp.tilt)
                .auralFrame(width: 24)
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

/// Loudness compensation follows the macOS volume, after the filters and tilt. The
/// reference that sets where it starts is in a popover.
struct LoudnessControls: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    @State private var showReference = false
    var body: some View {
        HStack(spacing: 6 * interfaceScale) {
            Toggle(isOn: Binding(get: { model.loudness.enabled }, set: model.setLoudnessEnabled)) {
                HStack(spacing: 6 * interfaceScale) {
                    Text("Loudness")
                    Text(model.loudness.enabled ? "On" : "Off").monospacedDigit()
                }
            }.toggleStyle(AuralCheckboxStyle()).auralControlSize(.small)
                .accessibilityLabel("Loudness compensation")
                .help("Restores bass and treble as you turn the volume down, following the ISO 226 equal-loudness contours. At the reference volume, EQ plays as set.")
            Spacer(minLength: 0)
            Button { showReference.toggle() } label: {
                Image(systemName: "slider.horizontal.3").auralFrame(width: 24, height: 24).contentShape(Rectangle())
            }
                .buttonStyle(.plain).accessibilityLabel("Loudness reference")
                .help("Set the volume and level where EQ plays as set")
                .popover(isPresented: $showReference) {
                    VStack(alignment: .leading, spacing: 14 * interfaceScale) {
                        Text("Loudness compensation").font(.headline)
                        Text("Restores bass and treble as you turn the volume down, following the ISO 226 equal-loudness contours. At the reference volume, EQ plays as set.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if model.loudness.enabled {
                            LoudnessReference(model: model)
                        } else {
                            Text("Turn on Loudness to set the reference volume.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.auralPadding(18).auralFrame(width: 300).auralAppearance(model.theme).auralZoom(model)
                }
        }.auralFont(size: 10).foregroundStyle(AuralStyle.secondary)
    }
}

struct OutputSelection: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    let submissions: PrecisionSubmissionCoordinator
    @State private var selectionRevision = 0
    var comfortable = false
    var compact = false
    /// The rail omits the hint: Start EQ is directly above the picker.
    var captioned = true
    @ViewBuilder var body: some View {
        AuralEquatableContent(key: OutputSelectionKey(devices: model.devices, selected: model.selectedUID, running: model.running,
                                                      rate: model.responseRate, comfortable: comfortable, compact: compact,
                                                      scale: interfaceScale, revision: selectionRevision)) {
        if compact {
            HStack(spacing: 7 * interfaceScale) {
                Text("Output").auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
                devicePicker
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").auralFrame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Refresh outputs").help("Refresh audio devices")
            }
        } else { expanded }
        }.equatable()
    }
    private var devicePicker: some View {
        AuralPicker(title: "Output device", value: model.selected?.name ?? "Select an output",
                    selection: Binding(get: { model.selectedUID }, set: selectOutput), size: comfortable ? .large : .regular) {
            if model.selected == nil { Text("Select an output").tag(model.selectedUID) }
            ForEach(model.devices) { Text($0.name).tag($0.uid) }
        }.auralFrame(maxWidth: compact ? nil : .infinity).id(selectionRevision)
            .help("Select the output used by your apps. Changing output stops EQ; it does not change the macOS default. Follow macOS output in Settings switches automatically.")
    }
    private var expanded: some View {
        VStack(alignment: .leading, spacing: (captioned ? 12 : 7) * interfaceScale) {
            HStack {
                AuralSectionLabel(title: "Output", systemImage: "hifispeaker")
                Spacer()
                Button { model.refresh() } label: {
                    Image(systemName: "arrow.clockwise").auralFrame(width: comfortable ? 30 : 24, height: comfortable ? 28 : 24)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain).foregroundStyle(AuralStyle.secondary).accessibilityLabel("Refresh outputs").help("Refresh audio devices")
            }
            devicePicker
            if captioned { Text(comfortable ? "Choose the output your apps are using. Changing output stops EQ; press Start EQ when you are ready." : (model.running ? String(format: "Stereo · %g kHz", model.responseRate / 1000) : "Select output, then Start EQ"))
                .auralFont(size: comfortable ? 13 : 10).foregroundStyle(AuralStyle.secondary).fixedSize(horizontal: false, vertical: true) }
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

private struct OutputSelectionKey: Equatable {
    let devices: [OutputDevice]
    let selected: String
    let running: Bool
    let rate: Double
    let comfortable: Bool
    let compact: Bool
    let scale: CGFloat
    let revision: Int
}

struct StudioMeter: View {
    @Environment(\.auralPalette) private var palette
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var meter: AudioMeter
    let running: Bool
    @Binding var protectionEnabled: Bool
    let resetHolds: () -> Void
    var compact = false
    /// Compact only: protection sits beside the meter instead of below it.
    var inline = false
    @State private var heldPeak: Float = 0
    @State private var showDetails = false
    private var peak: Float { meter.peak }
    private var db: Double { running && peak > 0 ? 20 * log10(Double(peak)) : -90 }
    private var heldDB: String { heldPeak > 0 ? String(format: "%.1f", 20 * log10(Double(heldPeak))) : "−∞" }
    /// The bar spans −60 to 0 dB.
    private var level: Double { MeterFill.fraction(for: db) }
    private let levelHelp = "Loudest sample leaving Aural, in decibels relative to full scale (dBFS). With peak protection off, samples can exceed 0 dBFS. Your Mac's volume is applied afterwards."
    var body: some View {
        Group {
            if compact {
                let layout = inline ? AnyLayout(HStackLayout(spacing: 14 * interfaceScale))
                                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 5 * interfaceScale))
                layout {
                    HStack(spacing: (inline ? 8 : 6) * interfaceScale) {
                        levelDetailsButton
                        ZStack {
                            // A translucent track stays visible on every surface in both appearances.
                            RoundedRectangle(cornerRadius: 1).fill(AuralStyle.grid.opacity(0.14))
                            MeterFill(fraction: level, cornerRadius: 1).fill(db >= -1 ? AuralStyle.warning : AuralStyle.accent)
                        }.auralFrame(minWidth: inline ? 70 : 44, idealWidth: 70, maxWidth: inline ? 200 : 70, minHeight: 5, maxHeight: 5)
                            .help(levelHelp)
                            .accessibilityRepresentation { peakAccessibility }
                        Text(db > -90 ? String(format: "%.1f dB", db) : "−∞ dB").monospacedDigit()
                            .auralFrame(minWidth: 58, maxWidth: inline ? 58 : .infinity, alignment: .trailing)
                            .accessibilityHidden(true)
                        Button { heldPeak = running ? peak : 0 } label: {
                            Image(systemName: "arrow.counterclockwise").auralFrame(width: 24, height: 24).contentShape(Rectangle())
                        }
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
    private var levelDetailsButton: some View {
        Button { showDetails.toggle() } label: {
            HStack(spacing: 4 * interfaceScale) {
                Text(compact ? "Level" : "Output level")
                Image(systemName: "chevron.down").auralFont(size: 8, weight: .semibold)
                    .accessibilityHidden(true)
            }.foregroundStyle(AuralStyle.secondary).fixedSize().contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Level details")
            .help("Show input, post-EQ, and output peaks, overloads, and maximum gain reduction.")
            .popover(isPresented: $showDetails, arrowEdge: .trailing) {
                LevelMeterDetails(meter: meter, running: running, resetHolds: resetHolds)
            }
    }
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 12 * interfaceScale) {
            HStack {
                levelDetailsButton.auralFont(size: 11, weight: .semibold)
                Spacer()
                Text(db > -90 ? String(format: "%.1f", db) : "−∞").auralFont(size: 13, weight: .medium, design: .monospaced)
                Text("dB").auralFont(size: 9).foregroundStyle(AuralStyle.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(palette.background)
                MeterFill(fraction: level, cornerRadius: 2).fill(db >= -1 ? AuralStyle.warning : AuralStyle.accent)
                HStack(spacing: 0) { ForEach(0..<24, id: \.self) { _ in Spacer(minLength: 0); Rectangle().fill(palette.surface).auralFrame(width: 2) } }
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
            }.toggleStyle(AuralCheckboxStyle()).auralControlSize(.small)
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

struct LevelMeterDetails: View {
    @ObservedObject var meter: AudioMeter
    let running: Bool
    let resetHolds: () -> Void
    @Environment(\.auralInterfaceScale) private var scale
    @Environment(\.auralPalette) private var palette

    var body: some View {
        let overloaded = meter.overloadPeak > 1
        let limited = meter.heldReductionDB >= 0.05
        VStack(alignment: .leading, spacing: 10 * scale) {
            Text("Sample peaks").auralFont(size: 13, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            peakRow("Input", value: meter.reading.inputPeak,
                    help: "Signal entering the EQ, after per-app volume and mute.")
            peakRow("Post-EQ", value: meter.reading.postEQPeak,
                    help: "Signal after EQ and stereo processing, before peak protection. In Bypass this includes any level matching.")
            peakRow("Output", value: meter.peak,
                    help: "Signal leaving Aural after peak protection, before macOS output volume.")
            Divider()
            holdRow("Overload hold", value: overloaded ? peakText(meter.overloadPeak) : "None",
                    active: overloaded, help: "Highest post-EQ sample above 0 dBFS since reset.")
            holdRow("Limiter hold", value: String(format: "%.1f dB", meter.heldReductionDB),
                    active: limited, help: "Largest gain reduction applied by peak protection since reset.")
            Button(action: resetHolds) {
                Text("Reset holds").auralFrame(maxWidth: .infinity)
            }.buttonStyle(AuralButtonStyle()).disabled(!overloaded && !limited)
                .help("Clear both the overload and limiter holds.")
        }.auralPadding(16).auralFrame(width: 280).background(palette.surface)
    }

    private func peakRow(_ title: String, value: Float, help: String) -> some View {
        let peak = running ? value : 0
        let db = sampleDecibels(peak)
        let fraction = MeterFill.fraction(for: db)
        return HStack(spacing: 8 * scale) {
            Text(title).auralFrame(width: 54, alignment: .leading)
            ZStack {
                RoundedRectangle(cornerRadius: 1).fill(AuralStyle.grid.opacity(0.14))
                MeterFill(fraction: fraction, cornerRadius: 1).fill(db >= -1 ? AuralStyle.warning : AuralStyle.accent)
            }.auralFrame(minHeight: 5, maxHeight: 5)
            Text(peakText(peak)).monospacedDigit().auralFrame(width: 82, alignment: .trailing)
        }.auralFont(size: 11)
            .accessibilityRepresentation {
                ProgressView(value: fraction)
                    .accessibilityLabel("\(title) sample peak")
                    .accessibilityValue(AuralAccessibility.samplePeak(db))
            }.help(help)
    }

    private func holdRow(_ title: String, value: String, active: Bool, help: String) -> some View {
        HStack(spacing: 8 * scale) {
            Text(title)
            Spacer(minLength: 0)
            Text(value).monospacedDigit().foregroundStyle(active ? AuralStyle.warning : AuralStyle.secondary)
        }.auralFont(size: 11).accessibilityElement(children: .combine).help(help)
    }

    private func sampleDecibels(_ peak: Float) -> Double { peak > 0 ? 20 * log10(Double(peak)) : -.infinity }
    private func peakText(_ peak: Float) -> String {
        let db = sampleDecibels(peak)
        return db > -90 ? String(format: "%+.1f dBFS", db) : "−∞ dBFS"
    }
}

/// The filled part of a level bar. It is drawn within the track's own frame, which interface
/// zoom has already scaled, so the fill can never run past the track.
private struct MeterFill: Shape {
    static func fraction(for db: Double) -> Double { min(1, max(0, (db + 60) / 60)) }
    var fraction: Double
    var cornerRadius: CGFloat?
    func path(in rect: CGRect) -> Path {
        let filled = CGRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height)
        return cornerRadius.map { RoundedRectangle(cornerRadius: $0).path(in: filled) } ?? Capsule().path(in: filled)
    }
}
