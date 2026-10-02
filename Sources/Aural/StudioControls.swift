import SwiftUI

struct StudioSidebar: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var saving = false
    private func matches(_ name: String) -> Bool { search.isEmpty || name.localizedCaseInsensitiveContains(search) }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                AuralSectionLabel(title: "Presets")
                Spacer()
                Button { openWindow.showAuralWindow("presets") } label: { Image(systemName: "square.stack") }
                    .buttonStyle(.plain).foregroundStyle(AuralStyle.secondary).accessibilityLabel("Manage preset library")
                    .help("Search, organize, and back up presets (⇧⌘P)")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(AuralStyle.secondary).accessibilityHidden(true)
                TextField("Find a preset", text: $search).textFieldStyle(.plain).accessibilityLabel("Find a preset")
            }.font(.system(size: 11)).padding(8).background(AuralStyle.background, in: RoundedRectangle(cornerRadius: 5))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    group("Favorites", names: model.favoritePresets.sorted())
                    group("My presets", names: model.customPresets.filter { !model.favoritePresets.contains($0) })
                    group("Factory", names: model.factory.keys.sorted().filter { !model.favoritePresets.contains($0) })
                    if (Array(model.factory.keys) + model.customPresets).filter(matches).isEmpty {
                        Text("No matching presets").font(.system(size: 11)).foregroundStyle(AuralStyle.secondary).padding(.vertical, 12)
                    }
                }
            }.frame(maxHeight: .infinity)
            Button { saving.toggle() } label: { Label("Save current…", systemImage: "plus").frame(maxWidth: .infinity) }
                .buttonStyle(AuralButtonStyle()).popover(isPresented: $saving) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Save preset").font(.headline)
                        TextField("Preset name", text: $model.presetName).textFieldStyle(.roundedBorder)
                            .onSubmit { save() }
                        Button("Save") { save() }.buttonStyle(AuralButtonStyle(prominent: true))
                            .disabled(model.presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let error = model.error { AuralNotice(message: error, isError: true) }
                    }.padding(18).frame(width: 280)
                }
            Divider().overlay(AuralStyle.border)
            VStack(alignment: .leading, spacing: 10) {
                AuralSectionLabel(title: "Transfer")
                HStack(spacing: 6) {
                    Button { model.copyEQ() } label: { Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                        .accessibilityLabel("Copy EQ").help("Copy Equalizer APO text (⇧⌘C)")
                    Button { model.pasteEQ() } label: { Label("Paste", systemImage: "clipboard").frame(maxWidth: .infinity) }
                        .accessibilityLabel("Paste EQ").help("Import clipboard EQ (⇧⌘V). Stops processing.")
                }.buttonStyle(AuralButtonStyle())
                Menu {
                    Button("Import AutoEQ text…") { model.importAutoEQ() }
                    Button("Export EQ text…") { model.exportEQ() }
                    Divider()
                    Button("Back up presets…") { model.backupPresets() }
                    Button("Restore presets…") { model.restorePresets() }
                } label: { Label("Files & backups", systemImage: "folder") }.font(.system(size: 11))
            }
        }.padding(14).background(AuralStyle.surface)
    }
    @ViewBuilder private func group(_ title: String, names: [String]) -> some View {
        let visible = names.filter(matches)
        if !visible.isEmpty {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.7)
                .foregroundStyle(AuralStyle.secondary).padding(.top, 9).padding(.bottom, 4)
            ForEach(visible, id: \.self) { name in
                Button { model.apply(name) } label: {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 1).fill(model.selectedPresetName == name ? AuralStyle.accent : .clear)
                            .frame(width: 2, height: 18)
                        Text(name).font(.system(size: 12, weight: model.selectedPresetName == name ? .semibold : .regular))
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        if model.favoritePresets.contains(name) { Image(systemName: "star.fill").font(.system(size: 8)) }
                    }.foregroundStyle(model.selectedPresetName == name ? AuralStyle.accent : Color.primary)
                        .padding(.horizontal, 7).frame(height: 32)
                        .background(model.selectedPresetName == name ? AuralStyle.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(name).accessibilityLabel("Apply preset \(name)")
                    .contextMenu {
                        Button(model.favoritePresets.contains(name) ? "Remove favorite" : "Add favorite") { model.toggleFavorite(name) }
                        Button("Duplicate") { model.duplicatePreset(name) }
                        Button("Manage…") { openWindow.showAuralWindow("presets") }
                    }
            }
        }
    }
    private func save() { model.savePreset(); if model.error == nil { saving = false } }
}

struct MonitorPanel: View {
    @ObservedObject var model: Model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                output
                Divider().overlay(AuralStyle.border)
                preamp
                Divider().overlay(AuralStyle.border)
                StudioMeter(peak: model.peak, running: model.running)
                Divider().overlay(AuralStyle.border)
                VStack(alignment: .leading, spacing: 9) {
                    AuralSectionLabel(title: "Signal path")
                    stage("01", "Preamp & filters", detail: "\(model.profile.filters?.filter(\.enabled).count ?? 10) active bands")
                    stage("02", "Stereo & timing", detail: model.profile.stereoSettings == StereoSettings() ? "Neutral" : "Custom processing")
                    stage("03", "Peak protection", detail: "Stereo-linked · always active")
                }
                Text("Bypass removes EQ and stereo processing. Stop restores the original audio route.")
                    .font(.system(size: 10)).foregroundStyle(AuralStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(16)
        }.background(AuralStyle.surface)
    }
    private var output: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AuralSectionLabel(title: "Output", systemImage: "hifispeaker")
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(AuralStyle.secondary).accessibilityLabel("Refresh outputs").help("Refresh audio devices")
            }
            Picker("Output device", selection: Binding(get: { model.selectedUID }, set: model.select)) {
                if model.selected == nil { Text("Select an output").tag(model.selectedUID) }
                ForEach(model.devices) { Text($0.name).tag($0.uid) }
            }.labelsHidden().frame(maxWidth: .infinity)
                .help("Select the output used by your apps. Changing output stops EQ; it does not change the macOS default.")
            Text(model.running ? String(format: "Stereo · %g kHz", model.responseRate / 1000) : "Select output, then Start EQ")
                .font(.system(size: 10)).foregroundStyle(AuralStyle.secondary)
        }
    }
    private var preamp: some View {
        VStack(alignment: .leading, spacing: 12) {
            AuralSectionLabel(title: "Master preamp")
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(String(format: "%+.2f", model.profile.preamp)).font(.system(size: 30, weight: .light, design: .monospaced)).monospacedDigit()
                Text("dB").font(.system(size: 12)).foregroundStyle(AuralStyle.secondary)
            }
            Slider(value: Binding(get: { model.profile.preamp }, set: model.setPreamp), in: model.profile.preampRange,
                   onEditingChanged: { active in active ? model.beginProfileGesture(label: "Preamp") : model.endProfileGesture() })
                .accessibilityLabel("Master preamp").accessibilityValue(String(format: "%.2f decibels", model.profile.preamp))
            HStack {
                PrecisionField(value: model.profile.preamp, range: model.profile.preampRange, label: "Exact preamp in decibels", revision: model.editRevision, commit: model.setPreamp)
                Text("dB").font(.system(size: 11)).foregroundStyle(AuralStyle.secondary)
            }
            Button { model.headroom() } label: { Label("Auto headroom", systemImage: "arrow.down.to.line").frame(maxWidth: .infinity) }
                .buttonStyle(AuralButtonStyle()).help("Set preamp to offset the estimated EQ and stereo gain. This is not a true-peak guarantee.")
        }
    }
    private func stage(_ number: String, _ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.system(size: 9, design: .monospaced)).foregroundStyle(AuralStyle.accent).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(detail).font(.system(size: 9)).foregroundStyle(AuralStyle.secondary)
            }
        }.padding(.vertical, 4)
    }
}

private struct StudioMeter: View {
    let peak: Float
    let running: Bool
    @State private var heldPeak: Float = 0
    private var db: Double { running && peak > 0 ? 20 * log10(Double(peak)) : -90 }
    private var heldDB: String { heldPeak > 0 ? String(format: "%.1f", 20 * log10(Double(heldPeak))) : "−∞" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AuralSectionLabel(title: "Output peak")
                Spacer()
                Text(db > -90 ? String(format: "%.1f", db) : "−∞").font(.system(size: 13, weight: .medium, design: .monospaced))
                Text("dBFS").font(.system(size: 9)).foregroundStyle(AuralStyle.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(AuralStyle.background)
                    RoundedRectangle(cornerRadius: 2).fill(db >= -1 ? AuralStyle.warning : AuralStyle.accent)
                        .frame(width: geometry.size.width * min(1, max(0, (db + 60) / 60)))
                    HStack(spacing: 0) { ForEach(0..<24, id: \.self) { _ in Spacer(minLength: 0); Rectangle().fill(AuralStyle.surface).frame(width: 2) } }
                }
            }.frame(height: 15).accessibilityLabel("Output sample peak").accessibilityValue(db > -90 ? "\(db) dBFS" : "Silent")
            HStack { Text("−60"); Spacer(); Text("−30"); Spacer(); Text("0 dBFS") }
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(AuralStyle.secondary)
            HStack {
                Text("Hold  \(heldDB) dBFS").font(.system(size: 10, design: .monospaced)).foregroundStyle(AuralStyle.secondary)
                Spacer()
                Button { heldPeak = running ? peak : 0 } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).accessibilityLabel("Reset peak hold").help("Reset maximum output peak")
            }
        }.onChange(of: peak) { _, value in if running { heldPeak = max(heldPeak, value) } }
            .onChange(of: running) { _, value in if !value { heldPeak = 0 } }
    }
}
