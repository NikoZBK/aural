import SwiftUI

@main struct AuralApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        Window("Aural", id: "main") { MainView(model: model) }
            .windowResizability(.contentSize)
            .commands { AuralCommands() }
        Window("About Aural", id: "about") { AboutView() }
            .windowResizability(.contentSize)
        MenuBarExtra("Aural", systemImage: "pawprint.fill") { MenuBarControls(model: model) }
    }
}

struct AuralCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appInfo) {
            Button("About Aural") { openWindow(id: "about"); NSApp.activate(ignoringOtherApps: true) }
        }
    }
}

struct MenuBarControls: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(model.running ? "Stop equalization" : "Start equalization") { model.running ? model.stop() : model.start() }
        Toggle("Bypass EQ", isOn: $model.bypass).onChange(of: model.bypass) { model.change() }
        Divider()
        Button("Show Aural") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("About Aural") { openWindow(id: "about"); NSApp.activate(ignoringOtherApps: true) }
        Button("Quit Aural") { model.stop(); NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

enum AuralStyle {
    static let accent = Color(red: 0.62, green: 0.88, blue: 0.57)
    static let background = Color(red: 0.055, green: 0.068, blue: 0.063)
}

struct MainView: View {
    @ObservedObject var model: Model
    @State private var showStartup = false
    private let accent = AuralStyle.accent
    private let labels = ["31.5", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            outputControls
            HStack(spacing: 12) {
                Text("Equalizer").font(.system(size: 14, weight: .semibold))
                Menu("Presets") {
                    ForEach(model.factory.keys.sorted(), id: \.self) { name in Button(name) { model.apply(name) } }
                    if !model.customPresets.isEmpty {
                        Divider()
                        ForEach(model.customPresets, id: \.self) { name in Button(name) { model.apply(name) } }
                    }
                }.fixedSize()
                Button("Import AutoEQ…") { model.importAutoEQ() }
                Spacer()
                Toggle("Bypass", isOn: $model.bypass).toggleStyle(.switch).controlSize(.small)
                    .onChange(of: model.bypass) { model.change() }
            }
            ResponseCurve(profile: model.profile, rate: model.responseRate, bypass: model.bypass, accent: accent)
                .frame(height: 92)
            if let filters = model.profile.filters {
                ImportedFiltersView(filters: filters, name: model.profile.sourceName ?? "Imported profile")
            } else {
                bands
            }
            preampControls
            HStack(spacing: 8) {
                TextField("Preset name", text: $model.presetName).textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit { if !model.presetName.trimmingCharacters(in: .whitespaces).isEmpty { model.savePreset() } }
                Button("Save preset") { model.savePreset() }.disabled(model.presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Reset to flat") { model.apply("Flat") }
            }
            notices
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").foregroundStyle(accent)
                Text("Processed on your Mac").font(.system(size: 10))
                Spacer()
                Text("Stop or Quit restores normal audio").font(.system(size: 10))
            }.foregroundStyle(.secondary)
        }
        .padding(22).frame(width: 760).background(AuralStyle.background)
        .preferredColorScheme(.dark).tint(accent)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.stop() }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Aural").font(.system(size: 23, weight: .semibold))
                Text("System audio equalizer").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(model.running ? accent : .gray).frame(width: 6, height: 6)
                Text(model.running ? (model.bypass ? "Bypassed" : "Processing") : "Stopped")
                    .font(.system(size: 11, weight: .medium))
            }.padding(.horizontal, 10).padding(.vertical, 7).background(.white.opacity(0.05), in: Capsule())
            Button { showStartup.toggle() } label: { Image(systemName: "gearshape").frame(width: 22, height: 22) }
                .buttonStyle(.borderless).help("Settings and About").accessibilityLabel("Settings")
                .popover(isPresented: $showStartup) { StartupSettings(model: model) }
        }
    }
    private var outputControls: some View {
        HStack(spacing: 12) {
            Image(systemName: "hifispeaker.fill").foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("OUTPUT DEVICE").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Picker("Output", selection: Binding(get: { model.selectedUID }, set: { model.select($0) })) {
                    if model.selected == nil { Text("Select an output").tag(model.selectedUID) }
                    ForEach(model.devices) { Text($0.name).tag($0.uid) }
                }.labelsHidden().fixedSize().frame(maxWidth: 330, alignment: .leading)
                    .help("Choose the same output your audio apps use. Aural does not change the macOS default output.")
            }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh audio devices").accessibilityLabel("Refresh outputs")
            Button { model.running ? model.stop() : model.start() } label: {
                Label(model.running ? "Stop" : "Start EQ", systemImage: model.running ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .frame(width: 98, height: 32).background(accent, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).disabled(model.selected == nil && !model.running)
        }.fixedSize(horizontal: true, vertical: false)
            .padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
    private var bands: some View {
        HStack(spacing: 0) {
            ForEach(0..<10, id: \.self) { i in
                VStack(spacing: 6) {
                    Text(String(format: "%+.1f", model.profile.gains[i])).font(.system(size: 11, design: .monospaced)).foregroundStyle(accent)
                    Slider(value: Binding(get: { model.profile.gains[i] }, set: { model.profile.gains[i] = $0; model.change() }), in: -12...12, step: 0.5)
                        .frame(width: 104).rotationEffect(.degrees(-90)).frame(width: 26, height: 108)
                        .accessibilityLabel("\(labels[i]) hertz gain").accessibilityValue("\(model.profile.gains[i]) decibels")
                    Text(labels[i]).font(.system(size: 11, weight: .medium, design: .monospaced))
                }.frame(maxWidth: .infinity)
            }
        }.padding(.vertical, 2)
    }
    private var preampControls: some View {
        HStack(spacing: 12) {
            Text("Preamp").font(.system(size: 12, weight: .medium))
            Slider(value: Binding(get: { model.profile.preamp }, set: { model.profile.preamp = $0; model.change() }), in: model.profile.preampRange, step: 0.5)
                .frame(width: 145).accessibilityLabel("Preamp gain")
            Text(String(format: model.profile.filters == nil ? "%.1f dB" : "%.2f dB", model.profile.preamp))
                .font(.system(size: 11, design: .monospaced)).frame(width: 68, alignment: .trailing)
            Button("Auto headroom") { model.headroom() }.help("Reduce preamp to compensate for the combined EQ boost")
            Spacer(minLength: 4)
            Text("OUT").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            ProgressView(value: Double(model.peak), total: 1).frame(width: 70).tint(accent).accessibilityLabel("Output peak")
        }.padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
    @ViewBuilder private var notices: some View {
        if let notice = model.startupNotice {
            HStack {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Cancel") { model.stop() }.controlSize(.small)
            }
        }
        if let notice = model.importNotice {
            Text(notice).font(.system(size: 11)).foregroundStyle(accent).fixedSize(horizontal: false, vertical: true)
        }
        if let error = model.error {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { model.error = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss error")
            }.padding(10).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct ImportedFiltersView: View {
    let filters: [ImportedFilter]
    let name: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1).help(name)
                Spacer()
                Text("\(filters.count) filters · original values").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("#").frame(width: 22, alignment: .leading)
                Text("TYPE").frame(width: 68, alignment: .leading)
                Text("FREQUENCY").frame(maxWidth: .infinity, alignment: .trailing)
                Text("GAIN").frame(maxWidth: .infinity, alignment: .trailing)
                Text("Q").frame(maxWidth: .infinity, alignment: .trailing)
            }.font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 10)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filters.indices, id: \.self) { i in
                        let f = filters[i]
                        HStack(spacing: 10) {
                            Text("\(i + 1)").frame(width: 22, alignment: .leading)
                            Text(f.enabled ? f.kind.rawValue : "OFF").frame(width: 68, alignment: .leading)
                            Text(String(format: "%.2f Hz", f.frequency)).frame(maxWidth: .infinity, alignment: .trailing)
                            Text(String(format: "%+.2f dB", f.gain)).frame(maxWidth: .infinity, alignment: .trailing)
                            Text(String(format: "%.3f", f.q)).frame(maxWidth: .infinity, alignment: .trailing)
                        }.font(.system(size: 11, design: .monospaced)).foregroundStyle(f.enabled ? .primary : .secondary)
                            .padding(.horizontal, 10).frame(height: 22)
                            .background(.white.opacity(i % 2 == 0 ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }.frame(height: min(238, CGFloat(filters.count) * 24 - 2))
        }
    }
}

struct ResponseCurve: View {
    let profile: Profile
    let rate: Double
    let bypass: Bool
    let accent: Color
    var body: some View {
        Canvas { context, size in
            let top = 6.0, bottom = size.height - 18
            func y(_ db: Double) -> Double { top + (24 - db) / 48 * (bottom - top) }
            func x(_ frequency: Double) -> Double { log10(frequency / 20) / 3 * size.width }
            for db in [-24.0, -12, 0, 12, 24] {
                var line = Path(); line.move(to: CGPoint(x: 0, y: y(db))); line.addLine(to: CGPoint(x: size.width, y: y(db)))
                context.stroke(line, with: .color(.white.opacity(db == 0 ? 0.2 : 0.06)), lineWidth: 1)
            }
            for frequency in [100.0, 1000, 10000] {
                var line = Path(); line.move(to: CGPoint(x: x(frequency), y: top)); line.addLine(to: CGPoint(x: x(frequency), y: bottom))
                context.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 1)
            }
            var curve = Path()
            for i in 0...400 {
                let frequency = 20 * pow(1000, Double(i)/400)
                let db = bypass ? 0 : profile.response(min(frequency, rate * 0.49), rate: rate)
                let point = CGPoint(x: Double(i)/400*size.width, y: y(min(24, max(-24, db))))
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(bypass ? .gray : accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            for (frequency, label) in [(20.0,"20 Hz"),(100,"100"),(1000,"1k"),(10000,"10k"),(20000,"20k")] {
                let point = CGPoint(x: min(size.width-16, max(16, x(frequency))), y: size.height-5)
                context.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundColor(.gray), at: point)
            }
            context.draw(Text("±24 dB").font(.system(size: 9, design: .monospaced)).foregroundColor(.gray), at: CGPoint(x: 24, y: 10))
        }.accessibilityLabel("Equalizer frequency response, 20 hertz to 20 kilohertz, plus or minus 24 decibels")
    }
}

struct StartupSettings: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Startup").font(.headline)
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLoginRequested }, set: model.setLaunchAtLogin))
            Toggle("Start EQ automatically", isOn: Binding(get: { model.startEQAutomatically }, set: model.setStartAutomatically))
            Text("Use the saved output and profile on launch. Wait up to 60 seconds if the device is disconnected. Stop pauses EQ for this session.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.loginStatus == .requiresApproval {
                Text("macOS approval is needed to launch at login.").font(.caption).foregroundStyle(.orange)
                Button("Open Login Items settings") { model.openLoginSettings() }
            }
            Divider()
            Button("About Aural") { openWindow(id: "about") }
        }.padding(18).frame(width: 300).onAppear { model.refreshLoginStatus() }
    }
}
