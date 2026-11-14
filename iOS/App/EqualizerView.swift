import SwiftUI

struct AuralRootView: View {
    @EnvironmentObject private var model: AuralModel
    @State private var setup = false
    var body: some View {
        TabView {
            Tab("Equalizer", systemImage: "slider.horizontal.3") { EqualizerView() }
            Tab("Presets", systemImage: "square.stack") { PresetsView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
        .sheet(isPresented: $setup) { ConnectionGuide() }
        .task { setup = !model.state.completedSetup }
        .alert("Aural", isPresented: Binding(get: { model.issue != nil }, set: { if !$0 { model.issue = nil } })) {
            Button("OK", role: .cancel) { model.issue = nil }
        } message: { Text(model.issue?.message ?? "") }
    }
}

struct EqualizerView: View {
    @EnvironmentObject private var model: AuralModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var editor: EditorSession?
    @State private var stereo = false
    @State private var save = false
    @State private var updatePreset = false
    @State private var name = ""
    struct EditorSession: Identifiable {
        let id = UUID()
        let profile: Profile
        let revision: Int
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let side = geometry.size.width >= 760 && !typeSize.isAccessibilitySize && model.state.library.filterPanelPosition == .right
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let problem = model.storageProblem {
                            Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                        }
                        if side {
                            HStack(alignment: .top, spacing: 20) {
                                VStack(spacing: 18) { response; toneControls }.frame(maxWidth: .infinity)
                                filterControls.frame(width: min(370, geometry.size.width * 0.42))
                            }
                        } else {
                            response
                            toneControls
                            filterControls
                        }
                        Button { stereo = true } label: {
                            ContentCard {
                                HStack(spacing: 14) {
                                    AuralIcon(symbol: "headphones", color: .auralViolet)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Stereo & listening").font(.system(.headline, design: .rounded))
                                        Text(model.profile.stereoSettings.isNeutral ? "Neutral · balance, width & crossfeed" : "Adjusted · balance, width & crossfeed").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                            }
                        }.buttonStyle(.plain)
                    }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 20)
                        .frame(maxWidth: 1200).frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("equalizer.scroll")
                .background { AuralBackground() }
                .safeAreaInset(edge: .bottom, spacing: 8) { ConnectionBar().frame(maxWidth: 640).padding(.horizontal, 16).padding(.bottom, 8) }
            }
            .navigationTitle("Aural").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }.disabled(!model.history.canUndo)
                    Menu {
                        Button("Redo", systemImage: "arrow.uturn.forward") { model.undo(redo: true) }.disabled(!model.history.canRedo)
                        Button("Save as preset…", systemImage: "square.and.arrow.down") { name = ""; save = true }
                        if model.canUpdatePreset {
                            Button("Save changes to \(model.title)", systemImage: "checkmark") { updatePreset = true }
                        }
                        Button("Save comparison", systemImage: "a.square") { model.captureComparison() }
                        Button("Swap A/B", systemImage: "arrow.left.arrow.right") { model.swapComparison() }.disabled(model.comparison == nil)
                        Divider()
                        Picker("Filter panel", selection: Binding(get: { model.state.library.filterPanelPosition }, set: { value in model.preference { $0.filterPanelPosition = value } })) {
                            ForEach(FilterPanelPosition.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                        }
                    } label: { Label("More", systemImage: "ellipsis") }
                }
            }
            .sheet(item: $editor) { session in FilterWorkspace(profile: session.profile, revision: session.revision) }
            .sheet(isPresented: $stereo) { StereoEditor(profile: model.profile, revision: model.revision) }
            .sheet(isPresented: $save) { PresetNameSheet(title: "Save preset", name: name) { try model.savePreset($0) } }
            .confirmationDialog("Update \(model.title)?", isPresented: $updatePreset, titleVisibility: .visible) {
                Button("Save changes") { model.perform { try model.updateSelectedPreset() } }
            } message: { Text("Replace this saved preset with the current EQ. Other presets are unchanged.") }
        }
    }
    private var profileHeading: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR SOUND").font(.caption2.weight(.bold)).tracking(2.4).foregroundStyle(Color.auralAccent)
                Text(model.title).font(.system(.largeTitle, design: .rounded).weight(.bold)).fixedSize(horizontal: false, vertical: true)
                Label(model.state.modified ? "Modified · unsaved changes" : model.state.selectedPreset == nil ? "Current profile" : "Saved preset", systemImage: model.state.modified ? "pencil" : "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if model.comparison != nil {
                Button("A/B", systemImage: "arrow.left.arrow.right") { model.swapComparison() }
                    .labelStyle(.titleOnly).buttonStyle(.glass).accessibilityLabel("Swap with saved comparison")
            }
        }
    }
    private var response: some View {
        ContentCard(emphasized: true) {
            VStack(alignment: .leading, spacing: 16) {
                profileHeading
                HStack(alignment: .firstTextBaseline) {
                    Text("Frequency response").font(.subheadline.weight(.medium))
                    Spacer()
                    Text(model.state.bypass ? "Bypassed" : "\(model.profile.filters?.count ?? GraphicEQ.frequencies.count) bands")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                ResponseGraph(analysis: model.analysis).frame(height: 180)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { responseLegend }
                    VStack(alignment: .leading, spacing: 8) { responseLegend }
                }.font(.caption.weight(.medium))
                Text("EQ + preamp · excludes stereo effects and peak protection").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private var responseLegend: some View {
        Label(model.analysis.midSide ? "Mid" : "Left", systemImage: "minus").foregroundStyle(Color.auralAccent)
        if model.analysis.hasChannelFilters { Label(model.analysis.midSide ? "Side" : "Right", systemImage: "minus").foregroundStyle(Color.auralViolet) }
        if model.comparison != nil { Label("Comparison", systemImage: "ellipsis").foregroundStyle(.secondary) }
    }
    private var headingLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
    }
    private var toneControls: some View {
        ContentCard {
            VStack(spacing: 12) {
                headingLayout {
                    SectionHeading(title: "Level & tone", symbol: "dial.low")
                    if !typeSize.isAccessibilitySize { Spacer() }
                    Button("Auto preamp") { model.autoPreamp() }.font(.subheadline).buttonStyle(.bordered).buttonBorderShape(.capsule).frame(minHeight: 44)
                }
                ValueSlider(title: "Preamp", value: profileBinding(\.preamp), range: model.profile.preampRange, editing: model.gesture)
                ValueSlider(title: "Tilt", value: profileBinding(\.tilt), range: Profile.tiltRange, editing: model.gesture)
            }
        }
    }
    private func profileBinding(_ keyPath: WritableKeyPath<Profile, Double>) -> Binding<Double> {
        Binding(get: { model.profile[keyPath: keyPath] }, set: { value in model.edit { $0[keyPath: keyPath] = value } })
    }
    private var filterControls: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 14) {
                headingLayout {
                    SectionHeading(title: model.profile.filters == nil ? "Graphic EQ" : "Parametric EQ", symbol: "slider.horizontal.3")
                    if !typeSize.isAccessibilitySize { Spacer() }
                    Button(model.profile.filters == nil ? "Advanced" : "Edit") {
                        editor = EditorSession(profile: model.profile, revision: model.revision)
                    }.buttonStyle(.bordered).buttonBorderShape(.capsule).frame(minHeight: 44)
                }
                if let filters = model.profile.filters {
                    ForEach(Array(filters.enumerated()), id: \.offset) { index, filter in
                        Button { editor = EditorSession(profile: model.profile, revision: model.revision) } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)").font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(filter.enabled ? Color.auralAccent : .secondary).frame(width: 32, height: 32)
                                    .background(Color.auralAccent.opacity(filter.enabled ? 0.12 : 0.03), in: .circle)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(filter.shape.name).font(.subheadline.weight(.medium))
                                    Text("\(frequencyLabel(filter.frequency)) · \(filter.effectiveChannel.label)" + (filter.enabled ? "" : " · Off")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if filter.kind.usesGain { Text(filter.gain, format: .number.precision(.fractionLength(1))).monospacedDigit() }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if index < filters.count - 1 { Divider() }
                    }
                } else {
                    ForEach(GraphicEQ.frequencies.indices, id: \.self) { index in
                        ValueSlider(title: frequencyLabel(GraphicEQ.frequencies[index]), value: Binding(get: { model.profile.gains[index] }, set: { value in model.edit { $0.gains[index] = value } }), range: -12...12, editing: model.gesture)
                    }
                }
            }
        }
    }
}

struct ResponseGraph: View {
    let analysis: ResponseAnalysis
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var opaque
    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: 30, y: 8, width: max(1, size.width - 38), height: max(1, size.height - 32))
            let scale = analysis.scale(showFilters: false)
            let low = max(-60, scale.lower), high = max(12, min(48, scale.upper))
            func point(_ hz: Double, _ db: Double) -> CGPoint {
                CGPoint(x: plot.minX + log10(hz / 20) / 3 * plot.width,
                        y: plot.minY + (high - db) / (high - low) * plot.height)
            }
            for db in stride(from: low, through: high, by: max(6, scale.interval)) {
                var path = Path(); path.move(to: point(20, db)); path.addLine(to: point(20000, db))
                context.stroke(path, with: .color(.primary.opacity(contrast == .increased ? 0.5 : db == 0 ? 0.3 : 0.07)), style: StrokeStyle(lineWidth: 1, dash: db == 0 ? [] : [2, 5]))
                context.draw(Text("\(Int(db))").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary), at: CGPoint(x: 23, y: point(20, db).y), anchor: .trailing)
            }
            for hz in [20.0, 100, 1000, 10000, 20000] {
                var path = Path(); path.move(to: point(hz, high)); path.addLine(to: point(hz, low))
                context.stroke(path, with: .color(.primary.opacity(contrast == .increased ? 0.35 : 0.06)), lineWidth: 1)
                let label = hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
                context.draw(Text(label).font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: point(hz, 0).x, y: size.height - 6))
            }
            func trace(_ values: [Double], color: Color, dashed: Bool = false, fill: Bool = false) {
                guard values.count == analysis.frequencies.count else { return }
                var path = Path()
                for (index, hz) in analysis.frequencies.enumerated() {
                    let p = point(hz, values[index]); if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                if !dashed && !opaque && contrast != .increased {
                    if fill {
                        // Shade the actual departure from 0 dB, not an invented spectrum.
                        var area = path
                        area.addLine(to: point(20000, 0)); area.addLine(to: point(20, 0)); area.closeSubpath()
                        context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.3), color.opacity(0.04)]), startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
                    }
                    context.stroke(path, with: .color(color.opacity(0.08)), style: StrokeStyle(lineWidth: 12, lineJoin: .round))
                    context.stroke(path, with: .color(color.opacity(0.13)), style: StrokeStyle(lineWidth: 6, lineJoin: .round))
                }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: dashed ? 2 : 3, lineJoin: .round, dash: dashed ? [4, 4] : []))
            }
            context.clip(to: Path(plot))
            if let comparison = analysis.comparisonValues(for: analysis.lanes.first) { trace(comparison, color: .secondary, dashed: true) }
            if analysis.hasChannelFilters, let comparison = analysis.comparisonValues(for: analysis.lanes.second) { trace(comparison, color: .auralViolet.opacity(0.7), dashed: true) }
            trace(analysis.values(for: analysis.lanes.first), color: .auralAccent, fill: true)
            if analysis.hasChannelFilters { trace(analysis.values(for: analysis.lanes.second), color: .auralViolet) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("EQ response, 20 hertz to 20 kilohertz")
        .accessibilityValue("Maximum EQ gain \(analysis.peak.formatted(.number.precision(.fractionLength(1)))) decibels. Exact values are available in the filter controls.")
    }
}
