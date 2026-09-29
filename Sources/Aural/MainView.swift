import SwiftUI

struct MainView: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    @State private var appIcon: NSImage?
    @State private var showStartup = false
    @State private var showFilterEditor = false
    private let frequencies = ["31.5", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    private let frequencyLabels = ["31.5", "63", "125", "250", "500", "1000", "2000", "4000", "8000", "16000"]

    private var status: String { model.running ? (model.bypass ? "Bypassed" : "Processing") : "Stopped" }
    private var statusColor: Color { model.running ? (model.bypass ? AuralStyle.warning : AuralStyle.accent) : AuralStyle.secondary }
    private var canSave: Bool { !model.presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 24).padding(.vertical, 18)
            Divider().overlay(AuralStyle.border)
            ScrollView {
                VStack(spacing: 18) {
                    outputControls
                    notices
                    HStack(alignment: .top, spacing: 18) {
                        equalizer.frame(maxWidth: .infinity)
                        controlRail.frame(width: 256)
                    }
                }.padding(24)
            }
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").foregroundStyle(AuralStyle.accent).accessibilityHidden(true)
                Text("Audio stays on your Mac")
                Spacer()
                Text("Stop or Quit restores normal audio")
            }.font(.system(size: 11)).foregroundStyle(AuralStyle.secondary)
                .padding(.horizontal, 24).padding(.bottom, 14)
        }
        .frame(minWidth: 940, minHeight: 680)
        .background(AuralStyle.background).preferredColorScheme(.dark).tint(AuralStyle.accent)
        .sheet(isPresented: $showFilterEditor) { FilterEditor(model: model) }
        .onAppear(perform: loadAppIcon)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.stop() }
    }

    private func loadAppIcon() {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else {
            model.error = "Aural could not load its app icon. Reinstall the app to restore it."
            return
        }
        // Launch Services may retain the previous icon after an in-place update.
        appIcon = icon
        NSApp.applicationIconImage = icon
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let appIcon { Image(nsImage: appIcon).resizable() }
                else { Image(systemName: "headphones").resizable().scaledToFit().padding(7) }
            }.frame(width: 42, height: 42).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Aural").font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("Your sound. Precisely.").font(.system(size: 12)).foregroundStyle(AuralStyle.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(status).font(.system(size: 12, weight: .medium))
            }.foregroundStyle(statusColor).padding(.horizontal, 12).padding(.vertical, 8)
                .background(statusColor.opacity(0.08), in: Capsule())
                .accessibilityElement(children: .ignore).accessibilityLabel("Equalizer status: \(status)")
            Button { showStartup.toggle() } label: {
                Image(systemName: "gearshape").font(.system(size: 15)).frame(width: 18, height: 18)
            }.buttonStyle(AuralButtonStyle()).help("Startup, About, and updates").accessibilityLabel("Settings")
                .popover(isPresented: $showStartup) { StartupSettings(model: model) }
        }
    }

    private var outputControls: some View {
        HStack(spacing: 16) {
            Image(systemName: "hifispeaker.fill").font(.system(size: 22)).foregroundStyle(AuralStyle.accent)
                .frame(width: 44, height: 44).background(AuralStyle.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                AuralSectionLabel(title: "Listening on")
                HStack(spacing: 8) {
                    Picker("Output device", selection: Binding(get: { model.selectedUID }, set: { model.select($0) })) {
                        if model.selected == nil { Text("Select an output").tag(model.selectedUID) }
                        ForEach(model.devices) { Text($0.name).tag($0.uid) }
                    }.labelsHidden().frame(maxWidth: 320, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("Choose the output your audio apps use. Changing outputs stops EQ; Aural does not change the macOS default output.")
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 16, height: 16) }
                        .buttonStyle(AuralButtonStyle()).help("Refresh audio devices").accessibilityLabel("Refresh outputs")
                }
            }
            Spacer(minLength: 8)
            Toggle("Bypass", isOn: $model.bypass).toggleStyle(.switch).controlSize(.small)
                .help("Hear audio without EQ or preamp. Routing and peak protection stay active while processing.")
                .onChange(of: model.bypass) { model.change() }
            Divider().frame(height: 30).padding(.horizontal, 4)
            Button { model.running ? model.stop() : model.start() } label: {
                Label(model.running ? "Stop EQ" : "Start EQ", systemImage: model.running ? "stop.fill" : "play.fill")
                    .frame(width: 92, height: 18)
            }.buttonStyle(AuralButtonStyle(prominent: true)).disabled(model.selected == nil && !model.running)
        }.auralPanel(padding: 14)
    }

    private var equalizer: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Equalizer").font(.system(size: 21, weight: .semibold))
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(model.selectedPresetName ?? "Custom EQ")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(model.selectedPresetName == nil ? AuralStyle.secondary : AuralStyle.accent)
                            .lineLimit(2)
                        if model.isPresetModified {
                            Text("Modified").font(.system(size: 10, weight: .medium))
                                .foregroundStyle(AuralStyle.warning)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(AuralStyle.warning.opacity(0.08), in: Capsule())
                        }
                    }.accessibilityElement(children: .ignore)
                        .accessibilityLabel("Current preset: \(model.currentPresetTitle)")
                        .help(model.currentPresetTitle)
                }
                Spacer(minLength: 0)
                Button { showFilterEditor = true } label: { Label("Edit filters…", systemImage: "slider.horizontal.3") }
                    .buttonStyle(AuralButtonStyle())
            }
            ResponseCurve(profile: model.profile, rate: model.responseRate, bypass: model.bypass, running: model.running)
                .equatable().frame(height: 214)
            Divider().overlay(AuralStyle.border)
            if let filters = model.profile.filters {
                ImportedFiltersView(filters: filters)
            } else {
                bands
            }
            HStack {
                Text(model.profile.filters == nil ? "±12 dB per band" : "Exact values · up to 32 filters")
                    .font(.system(size: 11)).foregroundStyle(AuralStyle.secondary)
                Spacer()
                Button("Reset to flat") { model.apply("Flat") }.buttonStyle(.borderless)
                    .font(.system(size: 12)).help("Apply flat EQ and return to the ten sliders")
            }
        }.auralPanel()
    }

    private var controlRail: some View {
        VStack(alignment: .leading, spacing: 20) {
            preampControls
            Divider().overlay(AuralStyle.border)
            presetControls
            Divider().overlay(AuralStyle.border)
            transferControls
        }.auralPanel()
    }

    private var preampControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            AuralSectionLabel(title: "Preamp", systemImage: "speaker.wave.2")
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(String(format: "%.2f", model.profile.preamp))
                    .font(.system(size: 32, weight: .medium, design: .rounded)).monospacedDigit()
                Text("dB").font(.system(size: 13)).foregroundStyle(AuralStyle.secondary)
                Spacer()
            }.accessibilityElement(children: .combine)
            Slider(value: Binding(get: { model.profile.preamp }, set: { model.profile.preamp = $0; model.change() }), in: model.profile.preampRange, step: 0.5)
                .accessibilityLabel("Preamp gain").accessibilityValue(String(format: "%.2f decibels", model.profile.preamp))
            Button { model.headroom() } label: { Label("Auto headroom", systemImage: "wand.and.stars").frame(maxWidth: .infinity) }
                .buttonStyle(AuralButtonStyle()).help("Reduce preamp to compensate for the combined EQ boost")
            OutputMeter(peak: model.peak, running: model.running)
        }
    }

    private var presetControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AuralSectionLabel(title: "Presets", systemImage: "square.stack")
                Spacer()
                Button("Library") { openWindow(id: "presets") }.buttonStyle(.borderless)
                    .font(.system(size: 12)).help("Search, organize, and back up presets (⇧⌘P)")
            }
            Menu { PresetMenuItems(model: model) } label: {
                Label(model.currentPresetTitle, systemImage: "waveform.path").lineLimit(1)
            }.controlSize(.large).frame(maxWidth: .infinity)
                .accessibilityLabel("Preset: \(model.currentPresetTitle)")
                .help("\(model.currentPresetTitle). Choose a preset to apply it immediately and start EQ if stopped.")
            HStack(spacing: 7) {
                TextField("Name this EQ", text: $model.presetName).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Preset name").onSubmit { if canSave { model.savePreset() } }
                Button { model.savePreset() } label: { Text("Save") }
                    .buttonStyle(AuralButtonStyle()).disabled(!canSave).accessibilityLabel("Save preset")
                    .help("Save the current EQ as a named preset")
            }
        }
    }

    private var transferControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            AuralSectionLabel(title: "Import & share", systemImage: "arrow.left.arrow.right")
            HStack(spacing: 8) {
                Button { model.copyEQ() } label: { Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                    .buttonStyle(AuralButtonStyle()).accessibilityLabel("Copy EQ").help("Copy Equalizer APO text (⇧⌘C)")
                Button { model.pasteEQ() } label: { Label("Paste", systemImage: "clipboard").frame(maxWidth: .infinity) }
                    .buttonStyle(AuralButtonStyle()).accessibilityLabel("Paste EQ").help("Paste Equalizer APO text (⇧⌘V). Stops EQ until you click Start EQ.")
            }
            Menu {
                Button("Import AutoEQ…") { model.importAutoEQ() }
                Button("Export EQ…") { model.exportEQ() }
            } label: { Label("Import / export file", systemImage: "doc.text") }
                .controlSize(.large).frame(maxWidth: .infinity)
            Text("Equalizer APO format. Import and Paste stop EQ until you press Start.")
                .font(.system(size: 11)).foregroundStyle(AuralStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bands: some View {
        VStack(alignment: .leading, spacing: 16) {
            AuralSectionLabel(title: "Graphic bands")
            HStack(spacing: 0) {
                ForEach(0..<10, id: \.self) { i in
                    VStack(spacing: 10) {
                        Text(String(format: "%+.1f", model.profile.gains[i]))
                            .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(AuralStyle.accent)
                        Slider(value: Binding(get: { model.profile.gains[i] }, set: { model.profile.gains[i] = $0; model.change() }), in: -12...12, step: 0.5)
                            .frame(width: 138).rotationEffect(.degrees(-90)).frame(width: 28, height: 144)
                            .accessibilityLabel("\(frequencyLabels[i]) hertz gain").accessibilityValue("\(model.profile.gains[i]) decibels")
                        Text(frequencies[i]).font(.system(size: 11, design: .monospaced)).foregroundStyle(AuralStyle.secondary)
                    }.frame(maxWidth: .infinity)
                }
            }
        }.padding(.vertical, 3)
    }

    @ViewBuilder private var notices: some View {
        if let notice = model.startupNotice {
            HStack {
                AuralNotice(message: notice)
                Button("Cancel startup") { model.stop() }.buttonStyle(AuralButtonStyle())
            }
        }
        if let error = model.error {
            HStack(alignment: .top) {
                AuralNotice(message: error, isError: true)
                Button { model.error = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(AuralButtonStyle()).accessibilityLabel("Dismiss error")
            }
        } else if let notice = model.importNotice {
            HStack(alignment: .top) {
                AuralNotice(message: notice)
                Button { model.importNotice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(AuralButtonStyle()).accessibilityLabel("Dismiss notice")
            }
        }
    }
}

private struct OutputMeter: View {
    let peak: Float
    let running: Bool
    private var level: Double { running ? min(1, max(0, Double(peak))) : 0 }
    private var label: String { level > 0 ? String(format: "%.1f dBFS", 20 * log10(level)) : "−∞ dBFS" }
    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text("OUTPUT PEAK").font(.system(size: 9, weight: .semibold)).tracking(0.8)
                Spacer()
                Text(label).font(.system(size: 10, design: .monospaced)).monospacedDigit()
            }.foregroundStyle(AuralStyle.secondary).accessibilityHidden(true)
            ProgressView(value: level, total: 1).tint(level >= 0.98 ? AuralStyle.warning : AuralStyle.accent)
                .accessibilityLabel("Output peak").accessibilityValue(label)
        }
    }
}

struct ImportedFiltersView: View {
    let filters: [ImportedFilter]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AuralSectionLabel(title: "Filter chain")
                Spacer()
                Text("\(filters.filter(\.enabled).count) of \(filters.count) enabled")
                    .font(.system(size: 11)).foregroundStyle(AuralStyle.secondary)
            }
            HStack(spacing: 10) {
                Text("#").frame(width: 22, alignment: .leading)
                Text("TYPE").frame(width: 122, alignment: .leading)
                Text("Hz").frame(maxWidth: .infinity, alignment: .trailing)
                Text("dB").frame(maxWidth: .infinity, alignment: .trailing)
                Text("Q").frame(width: 55, alignment: .trailing)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(AuralStyle.secondary).padding(.horizontal, 10)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filters.indices, id: \.self) { i in
                        let filter = filters[i]
                        HStack(spacing: 10) {
                            Text("\(i + 1)").foregroundStyle(AuralStyle.secondary).frame(width: 22, alignment: .leading)
                            HStack(spacing: 7) {
                                Image(systemName: filter.enabled ? "circle.fill" : "circle.slash")
                                    .font(.system(size: 6)).foregroundStyle(filter.enabled ? AuralStyle.accent : AuralStyle.secondary)
                                Text(filter.kind.label.components(separatedBy: " · ")[0]).font(.system(size: 11))
                            }.frame(width: 122, alignment: .leading)
                            Text(String(format: "%.2f", filter.frequency)).frame(maxWidth: .infinity, alignment: .trailing)
                            Text(filter.kind.usesGain ? String(format: "%+.2f", filter.gain) : "—")
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(String(format: "%.3f", filter.q)).frame(width: 55, alignment: .trailing)
                        }.font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(filter.enabled ? Color.primary : AuralStyle.secondary)
                            .padding(.horizontal, 10).frame(height: 29)
                            .background(i % 2 == 0 ? AuralStyle.elevated.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Filter \(i + 1), \(filter.kind.label), \(filter.enabled ? "enabled" : "disabled"), \(filter.frequency) hertz, \(filter.kind.usesGain ? "\(filter.gain) decibels, " : "")Q \(filter.q)")
                    }
                }
            }.frame(height: min(215, CGFloat(filters.count) * 31 - 2))
        }
    }
}
