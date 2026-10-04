import SwiftUI

@MainActor final class AutoEQBrowser: ObservableObject {
    @Published private(set) var entries: [AutoEQCatalogEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var catalogError: String?
    @Published private(set) var preview: AutoEQPreview?
    @Published private(set) var previewLoading = false
    @Published private(set) var previewError: String?
    @Published private(set) var previewEntryID: String?
    @Published private(set) var loadedAt: Date?
    private var catalogGeneration = UUID()
    private var previewGeneration = UUID()
    private let fetchCatalog: @Sendable (Bool) async throws -> [AutoEQCatalogEntry]
    private let fetchPreview: @Sendable (AutoEQCatalogEntry) async throws -> AutoEQPreview

    init(client: AutoEQCatalogClient = AutoEQCatalogClient()) {
        fetchCatalog = { try await client.catalog(refresh: $0) }
        fetchPreview = { try await client.preview($0) }
    }

    init(fetchCatalog: @escaping @Sendable (Bool) async throws -> [AutoEQCatalogEntry],
         fetchPreview: @escaping @Sendable (AutoEQCatalogEntry) async throws -> AutoEQPreview) {
        self.fetchCatalog = fetchCatalog; self.fetchPreview = fetchPreview
    }

    func loadCatalog(refresh: Bool = false) async {
        if !refresh, !entries.isEmpty { return }
        let generation = UUID(); catalogGeneration = generation
        loading = true; catalogError = nil
        defer { if catalogGeneration == generation { loading = false } }
        do {
            let result = try await fetchCatalog(refresh)
            try Task.checkCancellation()
            guard catalogGeneration == generation else { return }
            entries = result; loadedAt = Date()
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch {
            guard catalogGeneration == generation, !Task.isCancelled else { return }
            catalogError = error.localizedDescription
        }
    }

    func loadPreview(_ entry: AutoEQCatalogEntry?) async {
        let generation = UUID(); previewGeneration = generation
        preview = nil; previewError = nil; previewEntryID = entry?.id; previewLoading = entry != nil
        defer { if previewGeneration == generation { previewLoading = false } }
        guard let entry else { return }
        do {
            let result = try await fetchPreview(entry)
            try Task.checkCancellation()
            guard previewGeneration == generation else { return }
            preview = result
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch {
            guard previewGeneration == generation, !Task.isCancelled else { return }
            previewError = error.localizedDescription
        }
    }
}

struct AutoEQBrowserView: View {
    @ObservedObject var model: Model
    @StateObject private var browser: AutoEQBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var provider = ""
    @State private var selectedID: String?
    @State private var catalogRevision = 0
    @State private var previewRevision = 0

    @MainActor init(model: Model, browser: AutoEQBrowser? = nil) {
        self.model = model
        _browser = StateObject(wrappedValue: browser ?? AutoEQBrowser())
    }

    private var matches: [AutoEQCatalogEntry] { AutoEQCatalogEntry.matching(browser.entries, query: search, provider: provider) }
    private var selected: AutoEQCatalogEntry? { browser.entries.first { $0.id == selectedID } }
    private struct PreviewRequest: Equatable { let id: String?; let revision: Int }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HSplitView {
                catalog.frame(minWidth: 310, idealWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
                detail.padding(.leading, 12)
                    .frame(minWidth: 370, maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
            }.frame(minHeight: 340, maxHeight: .infinity)
            HStack {
                Link("AutoEQ project & license", destination: URL(string: "https://github.com/jaakkopasanen/AutoEq")!)
                Spacer()
                Text("Search stays on your Mac. Profiles download from GitHub.")
                    .foregroundStyle(AuralStyle.secondary)
            }.font(.system(size: 11))
            if let error = browser.catalogError {
                AuralNotice(message: error + (browser.entries.isEmpty ? "" : " The previously loaded catalog is still shown."), isError: true)
            }
            if let error = model.error { AuralNotice(message: error, isError: true) }
            else if let notice = model.importNotice { AuralNotice(message: notice) }
        }
        .padding(24).frame(minWidth: 780, minHeight: 620)
        .auralAppearance(model.theme, style: model.interfaceStyle)
        .auralAnnouncement(browser.catalogError ?? browser.previewError ?? model.error ?? model.importNotice)
        .task(id: catalogRevision) { await browser.loadCatalog(refresh: catalogRevision > 0) }
        .task(id: PreviewRequest(id: selectedID, revision: previewRevision)) { await browser.loadPreview(selected) }
        .onChange(of: search) { _, _ in clearHiddenSelection() }
        .onChange(of: provider) { _, _ in clearHiddenSelection() }
        .onChange(of: browser.entries) { _, _ in clearHiddenSelection() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "headphones")
                .font(.system(size: 23, weight: .medium)).foregroundStyle(AuralStyle.accent)
                .frame(width: 48, height: 48)
                .background(AuralStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("AutoEQ profiles").font(.system(size: 23, weight: .semibold))
                Text("Find your headphones, preview the correction, and import a preset.")
                    .font(.system(size: 12)).foregroundStyle(AuralStyle.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(AuralButtonStyle())
        }
    }

    private var catalog: some View {
        let results = matches
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                AuralSectionLabel(title: "HEADPHONE CATALOG", systemImage: "globe")
                Spacer()
                Button { catalogRevision += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(browser.loading)
                    .accessibilityLabel("Refresh AutoEQ catalog").help("Download the latest catalog")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(AuralStyle.secondary).accessibilityHidden(true)
                TextField("Search headphones", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("Search AutoEQ headphones")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(AuralStyle.secondary).accessibilityLabel("Clear headphone search")
                }
            }.padding(10).background(AuralStyle.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(AuralStyle.border))
            Picker("Measurement source", selection: $provider) {
                Text("All sources").tag("")
                ForEach(Array(Set(browser.entries.map(\.provider))).sorted(), id: \.self) { Text($0).tag($0) }
            }.font(.system(size: 12))
            if browser.loading {
                HStack { ProgressView().controlSize(.small); Text("Loading AutoEQ catalog…") }
                    .font(.system(size: 12)).foregroundStyle(AuralStyle.secondary)
            }
            Text("\(results.count) / \(browser.entries.count) profiles")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(AuralStyle.secondary)
            if results.isEmpty {
                VStack(spacing: 10) {
                    Text(browser.entries.isEmpty ? "Online headphone profiles" : "No headphones found")
                        .font(.system(size: 15, weight: .semibold))
                    Text(browser.entries.isEmpty ? "Connect to the internet to load the AutoEQ catalog." : "Try another model name or measurement source.")
                        .font(.system(size: 12)).foregroundStyle(AuralStyle.secondary).multilineTextAlignment(.center)
                    if !browser.loading {
                        Button(browser.entries.isEmpty ? "Try again" : "Clear filters") {
                            if browser.entries.isEmpty { catalogRevision += 1 }
                            else { search = ""; provider = "" }
                        }.buttonStyle(AuralButtonStyle())
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results, selection: $selectedID) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        Text(entry.measurement).font(.system(size: 11))
                            .foregroundStyle(selectedID == entry.id ? Color.primary : AuralStyle.secondary).lineLimit(2)
                    }.padding(.vertical, 4).tag(entry.id)
                        .help("\(entry.name) · \(entry.measurement) · \(entry.collection)")
                        .accessibilityElement(children: .combine)
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            if let date = browser.loadedAt {
                Text("Catalog loaded \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(AuralStyle.secondary)
            }
        }.auralPanel(padding: 16)
    }

    private var detail: some View {
        Group {
            if let entry = selected {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                        profileDetails(entry)
                    }
                    if let preview = browser.preview, preview.entry.id == entry.id {
                        Divider()
                        Text("Import saves a preset, replaces your EQ, and stops processing. Click Start EQ when ready. Undo restores the previous EQ.")
                            .font(.system(size: 11)).foregroundStyle(AuralStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { model.importOnlineAutoEQ(preview) } label: {
                            Label("Import profile", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                        }.buttonStyle(AuralButtonStyle(prominent: true))
                    }
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "headphones").font(.system(size: 33, weight: .light))
                        .foregroundStyle(AuralStyle.accent).accessibilityHidden(true)
                    Text("Choose your headphones").font(.system(size: 20, weight: .semibold))
                    Text("Search by brand or model. Different measurements appear separately so you can compare their corrections.")
                        .font(.system(size: 13)).foregroundStyle(AuralStyle.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.auralPanel()
    }

    private func profileDetails(_ entry: AutoEQCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            AuralSectionLabel(title: "AUTOEQ CORRECTION")
            Text(entry.name).font(.system(size: 22, weight: .semibold)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Measured by \(entry.measurement)")
                Text(entry.collection).foregroundStyle(AuralStyle.secondary)
                Link("View original result", destination: entry.resultURL)
            }.font(.system(size: 12)).textSelection(.enabled)
            if let preview = browser.preview, preview.entry.id == entry.id {
                ResponseCurve(profile: preview.profile, rate: model.responseRate, bypass: false, running: false)
                    .equatable().frame(height: 220)
                Text("\(preview.profile.filters?.count ?? 0) parametric filters · Preamp \(preview.profile.preamp, specifier: "%.1f") dB")
                    .font(.system(size: 12)).foregroundStyle(AuralStyle.secondary)
            } else if browser.previewEntryID == entry.id, let error = browser.previewError {
                AuralNotice(message: error, isError: true)
                Button("Retry download") { previewRevision += 1 }.buttonStyle(AuralButtonStyle())
            } else {
                HStack { ProgressView().controlSize(.small); Text("Downloading profile…") }.font(.system(size: 12))
            }
            Divider()
            Text("This is AutoEQ’s computed correction using the published target for this result. Match the model, pads, and listening mode shown in its name.")
                .font(.system(size: 11)).foregroundStyle(AuralStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clearHiddenSelection() {
        if let selectedID, !matches.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }
}
