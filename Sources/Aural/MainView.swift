import SwiftUI

struct MainView: View {
    @ObservedObject var model: Model
    @ObservedObject var icon: AppIconController
    @State private var showStartup = false
    @State private var showFilterEditor = false
    @State private var page = StudioPage.equalizer

    private var status: String { model.running ? (model.bypass ? "Bypassed" : "Processing") : "Stopped" }
    private var statusColor: Color { model.running ? (model.bypass ? AuralStyle.warning : AuralStyle.accent) : AuralStyle.secondary }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AuralStyle.border)
            HStack(spacing: 0) {
                StudioSidebar(model: model).frame(width: 184)
                Divider().overlay(AuralStyle.border)
                GeometryReader { geometry in
                    workspace(graphHeight: min(246, max(160, geometry.size.height * 0.30)))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(AuralStyle.border)
                MonitorPanel(model: model).frame(width: 218)
            }
            Divider().overlay(AuralStyle.border)
            footer
        }
        .frame(minWidth: 1060, minHeight: 700)
        .background(AuralStyle.background).preferredColorScheme(.dark).tint(AuralStyle.accent)
        .sheet(isPresented: $showFilterEditor) { FilterEditor(model: model) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let image = icon.image { Image(nsImage: image).resizable() }
                else { Image(systemName: "headphones").resizable().scaledToFit().padding(5) }
            }.frame(width: 35, height: 35).accessibilityHidden(true)
            Text("AURAL").font(.system(size: 18, weight: .bold)).tracking(2)
            Text("AUDIO WORKSPACE").font(.system(size: 9, weight: .medium)).tracking(1.2)
                .foregroundStyle(AuralStyle.secondary)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(status).font(.system(size: 11, weight: .medium))
            }.foregroundStyle(statusColor).accessibilityElement(children: .ignore)
                .accessibilityLabel("Equalizer status: \(status)")
            Divider().frame(height: 22).padding(.horizontal, 4)
            Toggle("Bypass", isOn: Binding(get: { model.bypass }, set: model.setBypass)).toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 11))
                .help("Bypass EQ, preamp, and stereo effects. Routing and peak protection stay active.")
            Button { model.running ? model.stop() : model.start() } label: {
                Label(model.running ? "Stop EQ" : "Start EQ", systemImage: model.running ? "stop.fill" : "play.fill")
                    .frame(width: 80)
            }.buttonStyle(AuralButtonStyle(prominent: true)).disabled(model.selected == nil && !model.running)
            Button { showStartup.toggle() } label: { Image(systemName: "gearshape").frame(width: 15) }
                .buttonStyle(AuralButtonStyle()).accessibilityLabel("Settings").help("Startup, About, and updates")
                .popover(isPresented: $showStartup) { StartupSettings(model: model) }
        }.padding(.horizontal, 18).frame(height: 62)
    }

    private func workspace(graphHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    AuralSectionLabel(title: "Active profile")
                    HStack(spacing: 8) {
                        Text(model.selectedPresetName ?? "Custom EQ").font(.system(size: 20, weight: .semibold))
                            .lineLimit(1).help(model.currentPresetTitle)
                        if model.isPresetModified {
                            Text("EDITED").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                                .foregroundStyle(AuralStyle.warning).padding(.horizontal, 6).padding(.vertical, 3)
                                .background(AuralStyle.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }.accessibilityElement(children: .ignore).accessibilityLabel("Current preset: \(model.currentPresetTitle)")
                }
                Spacer(minLength: 4)
                Button { model.undoProfile() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(AuralButtonStyle()).disabled(!model.canUndo).help(model.undoLabel).accessibilityLabel(model.undoLabel)
                Button { model.redoProfile() } label: { Image(systemName: "arrow.uturn.forward") }
                    .buttonStyle(AuralButtonStyle()).disabled(!model.canRedo).help(model.redoLabel).accessibilityLabel(model.redoLabel)
                Menu {
                    Button("Edit as a draft…") { showFilterEditor = true }
                    Divider()
                    Button("Copy EQ") { model.copyEQ() }
                    Button("Export EQ…") { model.exportEQ() }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                    .accessibilityLabel("Profile actions")
            }
            notices
            ResponseCurve(profile: model.profile, rate: model.responseRate, bypass: model.bypass, running: model.running,
                          comparisonProfile: model.otherComparisonProfile)
                .equatable().frame(height: graphHeight).auralPanel(padding: 14)
            comparison
            HStack {
                Picker("Workspace", selection: $page) {
                    Text("Equalizer").tag(StudioPage.equalizer)
                    Text("Stereo & timing").tag(StudioPage.stereo)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 242)
                Spacer()
                if page == .equalizer {
                    Menu("New layout") {
                        Button("10-band octave EQ") { model.useGraphicTemplate(bands: 10) }
                        Button("31-band third-octave EQ") { model.useGraphicTemplate(bands: 31) }
                    }.fixedSize().help("Start a flat layout. Undo restores your previous curve.")
                }
            }
            if page == .equalizer {
                FilterRack(model: model).frame(maxHeight: .infinity)
            } else {
                StereoPanel(model: model).frame(maxHeight: .infinity)
            }
        }.padding(18)
    }

    private var comparison: some View {
        HStack(spacing: 8) {
            AuralSectionLabel(title: "Compare")
            Button("A") { model.selectComparison(.a) }
                .buttonStyle(AuralButtonStyle(prominent: model.comparisonSlot == .a)).help("Listen to comparison A")
            Button("B") { model.selectComparison(.b) }
                .buttonStyle(AuralButtonStyle(prominent: model.comparisonSlot == .b)).help("Listen to comparison B")
            Menu {
                Button("Copy \(model.comparisonSlot.rawValue.uppercased()) to other slot") { model.copyComparisonToOther() }
                Button("Reset both to current profile") { model.captureComparison() }
            } label: { Image(systemName: "doc.on.doc") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                .accessibilityLabel("Comparison actions")
            Spacer()
            Text(model.comparisonAvailable ? "Edits stay in the selected slot" : "Select B to start a comparison")
                .font(.system(size: 10)).foregroundStyle(AuralStyle.secondary)
        }.accessibilityElement(children: .contain).accessibilityLabel("A/B comparison")
    }

    @ViewBuilder private var notices: some View {
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

    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(statusColor).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(model.running ? "CORE AUDIO  /  STEREO" : "OFFLINE PREVIEW")
            Text("·").foregroundStyle(AuralStyle.border)
            Text(String(format: "%g kHz", model.responseRate / 1000)).monospacedDigit()
            Spacer()
            Text("Close window to keep EQ in the menu bar").foregroundStyle(AuralStyle.secondary)
            Image(systemName: "lock.shield").accessibilityHidden(true)
        }.font(.system(size: 9, weight: .medium)).tracking(0.3).foregroundStyle(AuralStyle.secondary)
            .padding(.horizontal, 18).frame(height: 27)
    }
}

private enum StudioPage { case equalizer, stereo }
