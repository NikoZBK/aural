import SwiftUI

struct PresetLibraryView: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var search = ""
    @State private var favoritesOnly = false
    @State private var selected: String?
    @State private var newName = ""

    private var names: [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (Array(model.factory.keys) + model.customPresets).sorted().filter {
            (query.isEmpty || $0.localizedCaseInsensitiveContains(query)) &&
                (!favoritesOnly || model.favoritePresets.contains($0))
        }
    }
    private var selectedName: String? {
        selected.flatMap { names.contains($0) ? $0 : nil }
    }
    private var totalCount: Int { model.factory.count + model.customPresets.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * interfaceScale) {
            header
            HSplitView {
                library
                    .auralFrame(minWidth: 280, idealWidth: 310, maxWidth: .infinity, maxHeight: .infinity)
                detail
                    .auralPadding(.leading, 12)
                    .auralFrame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
            }.auralFrame(minHeight: 290, maxHeight: .infinity)
            footer
            if let error = model.error {
                AuralNotice(message: error, isError: true)
                    .transition(.auralReveal(.bottom, reduceMotion: reduceMotion))
            } else if let notice = model.importNotice {
                AuralNotice(message: notice)
                    .transition(.auralReveal(.bottom, reduceMotion: reduceMotion))
            }
        }
        .auralAnimation(value: [model.error, model.importNotice])
        .auralPadding(24)
        .auralFrame(minWidth: 760, minHeight: 520)
        .auralAppearance(model.theme)
        .auralAnnouncement(model.error ?? model.importNotice)
        .onChange(of: selected) { _, value in newName = value ?? "" }
        .onChange(of: names) { _, visibleNames in
            if let selected, !visibleNames.contains(selected) {
                self.selected = nil
                newName = ""
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14 * interfaceScale) {
            Image(systemName: "square.stack.3d.up")
                .auralFont(size: 23, weight: .medium)
                .foregroundStyle(AuralStyle.secondary)
                .auralFrame(width: 48, height: 48)
                .background(AuralStyle.elevated, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4 * interfaceScale) {
                Text("Preset library").auralFont(size: 23, weight: .semibold)
                Text("Search, compare, and organize your saved configurations.")
                    .auralFont(size: 12).foregroundStyle(AuralStyle.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(AuralButtonStyle())
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 14 * interfaceScale) {
            HStack {
                AuralSectionLabel(title: "YOUR PRESETS", systemImage: "tray.full")
                Spacer()
                Text("\(names.count) / \(totalCount)")
                    .auralFont(size: 11, weight: .medium, design: .monospaced)
                    .foregroundStyle(AuralStyle.secondary)
                    .accessibilityLabel("\(names.count) of \(totalCount) presets shown")
            }
            HStack(spacing: 8 * interfaceScale) {
                Image(systemName: "magnifyingglass").foregroundStyle(AuralStyle.secondary)
                    .accessibilityHidden(true)
                TextField("Search presets", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search presets")
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }.buttonStyle(.plain)
                        .foregroundStyle(AuralStyle.secondary)
                        .help("Clear search")
                        .accessibilityLabel("Clear preset search")
                        .transition(.auralPop(reduceMotion: reduceMotion))
                }
            }
            .auralAnimation(AuralMotion.quick, value: search.isEmpty)
            .auralPadding(10)
            .background(AuralStyle.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AuralStyle.border))
            Toggle(isOn: $favoritesOnly) {
                Label("Favorites only", systemImage: "star.fill")
            }.toggleStyle(.checkbox).auralFont(size: 12)

            // Overlapping the empty state and the list lets them crossfade in place.
            ZStack {
            if names.isEmpty {
                VStack(spacing: 10 * interfaceScale) {
                    Image(systemName: favoritesOnly ? "star.slash" : "magnifyingglass")
                        .auralFont(size: 25).foregroundStyle(AuralStyle.secondary)
                        .accessibilityHidden(true)
                    Text("No presets found").auralFont(size: 14, weight: .semibold)
                    Text(favoritesOnly ? "Try another search or turn off Favorites only." : "Try a different name.")
                        .auralFont(size: 12).foregroundStyle(AuralStyle.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Clear filters") { search = ""; favoritesOnly = false }
                        .buttonStyle(AuralButtonStyle())
                }.auralFrame(maxWidth: .infinity, maxHeight: .infinity)
                    .auralPadding(.vertical, 20)
            } else {
                List(names, id: \.self, selection: $selected) { name in
                    HStack(spacing: 10 * interfaceScale) {
                        Image(systemName: model.favoritePresets.contains(name) ? "star.fill" : "waveform")
                            .auralSymbolTransition()
                            .auralFont(size: 13)
                            .foregroundStyle(model.favoritePresets.contains(name) ? AuralStyle.accent : AuralStyle.secondary)
                            .auralFrame(width: 18)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4 * interfaceScale) {
                            Text(name).auralFont(size: 13, weight: .medium)
                                .lineLimit(1).help(name)
                            Text(model.factory[name] == nil ? "Custom preset" : "Built-in preset")
                                .auralFont(size: 10).foregroundStyle(AuralStyle.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .auralPadding(.vertical, 5)
                    .tag(name)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(name), \(model.factory[name] == nil ? "custom" : "built-in") preset\(model.favoritePresets.contains(name) ? ", favorite" : "")")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .auralFrame(maxHeight: .infinity)
            }
            }.auralAnimation(AuralMotion.fade, value: names.isEmpty)
        }
        .auralPanel(padding: 16)
    }

    private var detail: some View {
        ZStack {
            if let name = selectedName {
                ScrollView {
                    presetDetails(name)
                        .auralFrame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .center, spacing: 14 * interfaceScale) {
                    Image(systemName: "slider.horizontal.3")
                        .auralFont(size: 33, weight: .light)
                        .foregroundStyle(AuralStyle.secondary)
                        .accessibilityHidden(true)
                    Text("Find your sound").auralFont(size: 20, weight: .semibold)
                    Text("Choose a preset to apply it, make a copy, or add it to your favorites.")
                        .auralFont(size: 13).foregroundStyle(AuralStyle.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .auralPadding(20)
                .auralFrame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .auralAnimation(AuralMotion.fade, value: selectedName == nil)
        .auralPanel()
    }

    private func presetDetails(_ name: String) -> some View {
        let isCustom = model.customPresets.contains(name)
        let isFavorite = model.favoritePresets.contains(name)
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 18 * interfaceScale) {
            VStack(alignment: .leading, spacing: 8 * interfaceScale) {
                AuralSectionLabel(title: isCustom ? "CUSTOM PRESET" : "BUILT-IN PRESET")
                Text(name).auralFont(size: 22, weight: .semibold)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(isCustom ? "A saved EQ from your personal collection." : "A listening curve included with Aural.")
                    .auralFont(size: 12).foregroundStyle(AuralStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let profile = model.presetProfile(named: name) {
                if let source = profile.autoEQSource {
                    VStack(alignment: .leading, spacing: 5 * interfaceScale) {
                        Text("AutoEQ · \(source.name)")
                        Text("Measured by \(source.measurement)").foregroundStyle(AuralStyle.secondary)
                        Link("Original AutoEQ result", destination: source.url)
                    }.auralFont(size: 11).fixedSize(horizontal: false, vertical: true)
                }
                ResponseCurve(profile: profile, rate: model.responseRate, bypass: false, running: false)
                    .equatable().auralFrame(height: 220)
            }
            VStack(alignment: .leading, spacing: 9 * interfaceScale) {
                Button { withAuralAnimation { model.apply(name) } } label: {
                    Label("Apply preset", systemImage: "play.fill")
                        .auralFrame(maxWidth: .infinity)
                }.buttonStyle(AuralButtonStyle(prominent: true))
                Text("Applying starts EQ if it is stopped.")
                    .auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
            }
            HStack(spacing: 8 * interfaceScale) {
                Button { model.duplicatePreset(name) } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }.buttonStyle(AuralButtonStyle())
                Button { withAuralAnimation(AuralMotion.quick) { model.toggleFavorite(name) } } label: {
                    Label {
                        Text(isFavorite ? "Unfavorite" : "Favorite")
                    } icon: {
                        Image(systemName: isFavorite ? "star.slash" : "star").auralSymbolTransition()
                    }
                }.buttonStyle(AuralButtonStyle())
            }
            Divider().overlay(AuralStyle.border)
            if isCustom {
                VStack(alignment: .leading, spacing: 10 * interfaceScale) {
                    AuralSectionLabel(title: "RENAME PRESET", systemImage: "pencil")
                    TextField("Preset name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("New preset name")
                    Button("Rename") { rename(name) }
                        .buttonStyle(AuralButtonStyle())
                        .disabled(trimmedName.isEmpty || trimmedName == name)
                }
                VStack(alignment: .leading, spacing: 8 * interfaceScale) {
                    Button(role: .destructive) { model.deletePreset(name) } label: {
                        Label("Delete preset", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(AuralStyle.warning)
                    Text("Deleting leaves your current EQ unchanged. You can undo the latest deletion until Aural quits.")
                        .auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label {
                    Text("Duplicate a built-in preset to give it your own name.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }.auralFont(size: 12).foregroundStyle(AuralStyle.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10 * interfaceScale) {
            Button { openWindow.showAuralWindow("autoeq") } label: {
                Label("AutoEQ…", systemImage: "headphones")
            }.buttonStyle(AuralButtonStyle()).help("Search online headphone correction profiles")
            Button { model.backupPresets() } label: {
                Label("Back up…", systemImage: "square.and.arrow.up")
            }.buttonStyle(AuralButtonStyle())
                .help("Export your custom presets and favorites to a backup file")
                .accessibilityLabel("Back up presets")
            Button { model.restorePresets() } label: {
                Label("Restore…", systemImage: "square.and.arrow.down")
            }.buttonStyle(AuralButtonStyle())
                .help("Restore presets from a backup file")
                .accessibilityLabel("Restore presets")
            Spacer()
            Button { model.restoreDeletedPreset() } label: {
                Label("Undo delete", systemImage: "arrow.uturn.backward")
            }.buttonStyle(AuralButtonStyle())
                .disabled(model.deletedPreset == nil)
                .help("Restore the most recently deleted preset")
        }
    }

    private func rename(_ name: String) {
        if model.renamePreset(name, to: newName) {
            selected = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

struct PresetMenuItems: View {
    @ObservedObject var model: Model
    var body: some View {
        if !model.favoritePresets.isEmpty {
            Menu("Favorites") {
                ForEach(model.favoritePresets.sorted(), id: \.self) { name in
                    presetButton(name)
                }
            }
            Divider()
        }
        ForEach(model.factory.keys.sorted(), id: \.self) { name in
            presetButton(name)
        }
        if !model.customPresets.isEmpty {
            Divider()
            ForEach(model.customPresets, id: \.self) { name in
                presetButton(name)
            }
        }
    }
    private func presetButton(_ name: String) -> some View {
        Button { withAuralAnimation { model.apply(name) } } label: {
            if model.selectedPresetName == name {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }
}
