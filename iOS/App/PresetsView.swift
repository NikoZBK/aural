import SwiftUI
import UniformTypeIdentifiers

struct PresetDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }
    var data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw AudioFailure(message: "The file could not be read.") }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct PresetsView: View {
    @EnvironmentObject private var model: AuralModel
    @State private var search = ""
    @State private var favoritesOnly = false
    @State private var sheet: Sheet?
    @State private var importing = false
    @State private var reading = false
    @State private var exporting = false
    @State private var document = PresetDocument(Data())
    @State private var exportName = "Aural profile"
    @State private var exportType = UTType.json
    @State private var deleteName: String?
    enum Sheet: Identifiable {
        case save, rename(String), autoEQ, preview(ProfileImport, String)
        var id: String {
            switch self { case .save: return "save"; case .rename(let name): return "rename:" + name; case .autoEQ: return "autoeq"; case .preview(_, let name): return "import:" + name }
        }
    }
    private var names: [String] {
        model.presetNames.filter { name in
            (search.isEmpty || name.localizedCaseInsensitiveContains(search)) && (!favoritesOnly || model.state.library.favoritePresets?.contains(name) == true)
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { sheet = .autoEQ } label: {
                        ContentCard(emphasized: true) {
                            VStack(alignment: .leading, spacing: 20) {
                                HStack {
                                    AuralIcon(symbol: "headphones")
                                    Spacer()
                                    Text("AUTOEQ").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Color.auralAccent)
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Find your headphones").font(.system(.title2, design: .rounded).weight(.bold)).foregroundStyle(.primary)
                                    Text("A sound made for your pair. Explore measured headphone corrections.").font(.subheadline).foregroundStyle(.secondary)
                                }
                                Label("Browse AutoEQ measurements", systemImage: "arrow.up.right").font(.subheadline.weight(.semibold)).foregroundStyle(Color.auralAccent)
                            }
                        }
                    }.buttonStyle(.plain).accessibilityLabel("Find your headphones").accessibilityHint("Browse AutoEQ measurements")
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    Toggle("Favorites only", isOn: $favoritesOnly)
                    if reading { ProgressView("Reading import…") }
                    ForEach(names, id: \.self) { name in presetRow(name) }
                    if names.isEmpty { ContentUnavailableView.search(text: search.isEmpty ? "favorites" : search) }
                } header: { Text("Your sounds · \(names.count)") }
                footer: { Text("Choosing a preset enables EQ and starts the receiver. Select Aural in Control Center if it is not connected.") }
            }
            .scrollContentBackground(.hidden).background { AuralBackground() }
            .navigationTitle("Presets").searchable(text: $search, prompt: "Find a preset")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Save current EQ…", systemImage: "plus") { sheet = .save }
                        Button("Import file…", systemImage: "square.and.arrow.down") { importing = true }
                        Divider()
                        Button("Export current profile", systemImage: "square.and.arrow.up") { export(library: false) }
                        Button("Back up preset library", systemImage: "externaldrive") { export(library: true) }
                        Button("Export Equalizer APO text") {
                            model.perform {
                                document = PresetDocument(Data(try AutoEQ.export(model.profile).utf8))
                                exportType = .plainText; exportName = "Aural EQ"; exporting = true
                            }
                        }
                    } label: { Label("Manage presets", systemImage: "plus") }
                }
            }
            .sheet(item: $sheet) { item in
                switch item {
                case .save: PresetNameSheet(title: "Save preset", name: "") { try model.savePreset($0) }
                case .rename(let old): PresetNameSheet(title: "Rename preset", name: old) { try model.renamePreset(old, to: $0) }
                case .autoEQ: AutoEQSearchView()
                case .preview(let imported, let name): ImportPreviewView(imported: imported, name: name)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText], allowsMultipleSelection: false) { result in
                switch result {
                case .failure(let error): model.issue = .init(message: error.localizedDescription)
                case .success(let urls):
                    guard let url = urls.first else { model.issue = .init(message: "No file was selected."); return }
                    read(url)
                }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: exportName) { result in
                if case .failure(let error) = result { model.issue = .init(message: error.localizedDescription) }
            }
            .confirmationDialog("Delete \(deleteName ?? "preset")?", isPresented: Binding(get: { deleteName != nil }, set: { if !$0 { deleteName = nil } }), titleVisibility: .visible) {
                Button("Delete preset", role: .destructive) {
                    if let name = deleteName { model.perform { try model.libraryEdit { try $0.deletePreset(name) } } }
                    deleteName = nil
                }
            } message: { Text("Your current EQ will stay active. The saved preset will be removed.") }
        }
    }
    private func presetRow(_ name: String) -> some View {
        HStack(spacing: 12) {
            Button { model.loadPreset(name) } label: {
                HStack(spacing: 12) {
                    AuralIcon(symbol: model.state.selectedPreset == name ? "checkmark" : "waveform.path", color: model.state.selectedPreset == name ? .auralAccent : .auralViolet)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.system(.body, design: .rounded).weight(.semibold)).foregroundStyle(.primary)
                        Text(model.state.selectedPreset == name ? "Selected" + (model.state.modified ? " · modified" : "") : Profile.builtInPresets[name] == nil ? "Saved preset" : "Aural collection").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }.frame(minHeight: 58).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Apply preset and enable EQ")
            Button {
                model.perform { try model.libraryEdit { try $0.toggleFavorite(name) } }
            } label: {
                Image(systemName: model.state.library.favoritePresets?.contains(name) == true ? "star.fill" : "star")
            }.buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel((model.state.library.favoritePresets?.contains(name) == true ? "Unfavorite " : "Favorite ") + name)
        }
        .contextMenu {
            Button("Duplicate", systemImage: "plus.square.on.square") { model.perform { try model.libraryEdit { try $0.duplicatePreset(name) } } }
            if Profile.builtInPresets[name] == nil {
                Button("Rename", systemImage: "pencil") { sheet = .rename(name) }
                Button("Delete", systemImage: "trash", role: .destructive) { deleteName = name }
            }
        }
    }
    private func export(library: Bool) {
        model.perform {
            document = PresetDocument(try library ? model.exportLibrary() : model.exportProfile())
            exportName = library ? "Aural presets" : "Aural profile"; exportType = .json; exporting = true
        }
    }
    private func read(_ url: URL) {
        reading = true
        Task {
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let file = try FileHandle(forReadingFrom: url)
                    let data = try file.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
                    try file.close()
                    return try ProfileImport.read(data, name: url.deletingPathExtension().lastPathComponent, isJSON: url.pathExtension.lowercased() == "json")
                }.value
                sheet = .preview(imported, url.deletingPathExtension().lastPathComponent)
            } catch { model.issue = .init(message: error.localizedDescription) }
            reading = false
        }
    }
}

struct PresetNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var name: String
    let save: (String) throws -> Void
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                TextField("Preset name", text: $name).focused($focused).submitLabel(.done).onSubmit(commit)
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save", action: commit).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }.onAppear { focused = true }
        }.presentationDetents([.medium, .large])
    }
    private func commit() { do { try save(name); dismiss() } catch { self.error = error.localizedDescription } }
}

struct ImportPreviewView: View {
    @EnvironmentObject private var model: AuralModel
    @Environment(\.dismiss) private var dismiss
    let imported: ProfileImport
    let name: String
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(name).font(.title2.bold())
                    switch imported {
                    case .profile(let profile):
                        ProfilePreview(profile: profile)
                        Text("Import replaces the current EQ and stops the receiver. Saved presets are unchanged. Save the imported EQ as a preset when you’re ready.").font(.subheadline).foregroundStyle(.secondary)
                    case .library(let backup):
                        Label("\(backup.presets.count) saved presets", systemImage: "square.stack").font(.headline)
                        Text("Existing presets are preserved. Matching names receive a numbered suffix, and favorites are restored.").foregroundStyle(.secondary)
                        ForEach(backup.presets.keys.sorted(), id: \.self) { Text($0) }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }.padding(24)
            }.navigationTitle("Review import").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") { do { try model.acceptImport(imported); dismiss() } catch { self.error = error.localizedDescription } }
                    }
                }
        }
    }
}

struct ProfilePreview: View {
    let profile: Profile
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ResponseGraph(analysis: ResponseAnalysis(profile: profile, rate: 48000, bypass: false)).frame(height: 190)
            LabeledContent("Preamp", value: profile.preamp.formatted(.number.precision(.fractionLength(1))) + " dB")
            LabeledContent("EQ", value: profile.filters.map { "\($0.count) parametric filters" } ?? "10 graphic bands")
            if let origin = profile.autoEQSource {
                Text("Measurement: \(origin.measurement)").font(.subheadline).foregroundStyle(.secondary)
                Link("View original AutoEQ result", destination: origin.url)
            }
        }
    }
}

struct AutoEQSearchView: View {
    @State private var entries: [AutoEQCatalogEntry] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var refresh = 0
    @Environment(\.dismiss) private var dismiss
    private var results: [AutoEQCatalogEntry] { Array(AutoEQCatalogEntry.matching(entries, query: search).prefix(150)) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose the exact model and measurement source. Preview the correction before applying it.").font(.subheadline).foregroundStyle(.secondary)
                    Link("About AutoEQ & licensing", destination: URL(string: "https://github.com/jaakkopasanen/AutoEq")!)
                }
                if loading { ProgressView("Loading headphone catalog…") }
                if let error { Text(error).foregroundStyle(.red); Button("Try again") { refresh += 1 } }
                ForEach(results) { entry in
                    NavigationLink { AutoEQResultView(entry: entry, close: { dismiss() }) } label: {
                        VStack(alignment: .leading, spacing: 4) { Text(entry.name); Text(entry.measurement).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if !loading && error == nil {
                    if results.isEmpty { ContentUnavailableView.search(text: search) }
                    else if results.count == 150 { Text("Showing the first 150 results. Narrow your search to find your model.").font(.footnote).foregroundStyle(.secondary) }
                }
            }.navigationTitle("Find headphones").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "Brand or model")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .task(id: refresh) {
                    loading = true; error = nil
                    do {
                        let downloaded = try await AutoEQCatalogClient().catalog(refresh: refresh > 0)
                        try Task.checkCancellation(); entries = downloaded
                    } catch is CancellationError { /* Dismissed or replaced request. */ }
                    catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                    loading = false
                }
        }
    }
}

struct AutoEQResultView: View {
    @EnvironmentObject private var model: AuralModel
    let entry: AutoEQCatalogEntry
    let close: () -> Void
    @State private var preview: AutoEQPreview?
    @State private var error: String?
    @State private var refresh = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(entry.name).font(.title2.bold())
                if let preview {
                    ProfilePreview(profile: preview.profile)
                    Text("This saves a new preset and replaces the current EQ. The receiver will stop so you can start listening when ready.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Save & use EQ") {
                        do { try model.acceptAutoEQ(preview); close() } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.glassProminent).controlSize(.large)
                } else if error == nil { ProgressView("Loading correction…") }
                if let error { Text(error).foregroundStyle(.red); Button("Try again") { refresh += 1 } }
            }.padding(24)
        }.navigationTitle("Preview correction").navigationBarTitleDisplayMode(.inline)
            .task(id: refresh) {
                error = nil
                do { let result = try await AutoEQCatalogClient().preview(entry); try Task.checkCancellation(); preview = result }
                catch is CancellationError { /* Navigation canceled the request. */ }
                catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
    }
}
