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
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    @StateObject private var browser: AutoEQBrowser
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        VStack(alignment: .leading, spacing: 16 * interfaceScale) {
            header
            HSplitView {
                catalog.auralFrame(minWidth: 310, idealWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
                detail.auralPadding(.leading, 12)
                    .auralFrame(minWidth: 370, maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
            }.auralFrame(minHeight: 340, maxHeight: .infinity)
            HStack {
                Link("AutoEQ project & license", destination: URL(string: "https://github.com/jaakkopasanen/AutoEq")!)
                Spacer()
                Text("Search stays on your Mac. Profiles download from GitHub.")
                    .foregroundStyle(AuralStyle.secondary)
            }.auralFont(size: 11)
            if let error = browser.catalogError {
                AuralNotice(message: error + (browser.entries.isEmpty ? "" : " The previously loaded catalog is still shown."), isError: true)
                    .transition(.auralReveal(.bottom, reduceMotion: reduceMotion))
            }
            if let error = model.error {
                AuralNotice(message: error, isError: true).transition(.auralReveal(.bottom, reduceMotion: reduceMotion))
            } else if let notice = model.importNotice {
                AuralNotice(message: notice).transition(.auralReveal(.bottom, reduceMotion: reduceMotion))
            }
        }
        .auralAnimation(value: [browser.catalogError, model.error, model.importNotice])
        .auralPadding(24).auralFrame(minWidth: 780, minHeight: 620)
        .auralAppearance(model.theme)
        .auralAnnouncement(browser.catalogError ?? browser.previewError ?? model.error ?? model.importNotice)
        .task(id: catalogRevision) { await browser.loadCatalog(refresh: catalogRevision > 0) }
        .task(id: PreviewRequest(id: selectedID, revision: previewRevision)) { await browser.loadPreview(selected) }
        .onChange(of: search) { _, _ in clearHiddenSelection() }
        .onChange(of: provider) { _, _ in clearHiddenSelection() }
        .onChange(of: browser.entries) { _, _ in clearHiddenSelection() }
    }

    private var header: some View {
        HStack(spacing: 14 * interfaceScale) {
            Image(systemName: "headphones")
                .auralFont(size: 23, weight: .medium).foregroundStyle(AuralStyle.secondary)
                .auralFrame(width: 48, height: 48)
                .background(AuralStyle.elevated, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4 * interfaceScale) {
                Text("AutoEQ profiles").auralFont(size: 23, weight: .semibold)
                Text("Find your headphones, preview the correction, and import a preset.")
                    .auralFont(size: 12).foregroundStyle(AuralStyle.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(AuralButtonStyle())
        }
    }

    private var catalog: some View {
        let results = matches
        return VStack(alignment: .leading, spacing: 12 * interfaceScale) {
            HStack {
                AuralSectionLabel(title: "HEADPHONE CATALOG", systemImage: "globe")
                Spacer()
                Button { catalogRevision += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(browser.loading)
                    .accessibilityLabel("Refresh AutoEQ catalog").help("Download the latest catalog")
            }
            HStack(spacing: 8 * interfaceScale) {
                Image(systemName: "magnifyingglass").foregroundStyle(AuralStyle.secondary).accessibilityHidden(true)
                TextField("Search headphones", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("Search AutoEQ headphones")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(AuralStyle.secondary).accessibilityLabel("Clear headphone search")
                        .transition(.auralPop(reduceMotion: reduceMotion))
                }
            }.auralAnimation(AuralMotion.quick, value: search.isEmpty)
                .auralPadding(10).background(AuralStyle.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AuralStyle.border))
            HStack(spacing: 8 * interfaceScale) {
                Text("Measurement source").auralFont(size: 12).accessibilityHidden(true)
                AuralPicker(title: "Measurement source", value: provider.isEmpty ? "All sources" : provider, selection: $provider) {
                    Text("All sources").tag("")
                    ForEach(Array(Set(browser.entries.map(\.provider))).sorted(), id: \.self) { Text($0).tag($0) }
                }
            }
            if browser.loading {
                HStack { ProgressView().auralControlSize(.small); Text("Loading AutoEQ catalog…") }
                    .auralFont(size: 12).foregroundStyle(AuralStyle.secondary)
                    .transition(.opacity)
            }
            Text("\(results.count) / \(browser.entries.count) profiles")
                .auralFont(size: 11, design: .monospaced).foregroundStyle(AuralStyle.secondary)
            ZStack {
            if results.isEmpty {
                VStack(spacing: 10 * interfaceScale) {
                    Text(browser.entries.isEmpty ? "Online headphone profiles" : "No headphones found")
                        .auralFont(size: 15, weight: .semibold)
                    Text(browser.entries.isEmpty ? "Connect to the internet to load the AutoEQ catalog." : "Try another model name or measurement source.")
                        .auralFont(size: 12).foregroundStyle(AuralStyle.secondary).multilineTextAlignment(.center)
                    if !browser.loading {
                        Button(browser.entries.isEmpty ? "Try again" : "Clear filters") {
                            if browser.entries.isEmpty { catalogRevision += 1 }
                            else { search = ""; provider = "" }
                        }.buttonStyle(AuralButtonStyle())
                    }
                }.auralFrame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results, selection: $selectedID) { entry in
                    VStack(alignment: .leading, spacing: 4 * interfaceScale) {
                        Text(entry.name).auralFont(size: 13, weight: .medium).lineLimit(2)
                        Text(entry.measurement).auralFont(size: 11)
                            .foregroundStyle(selectedID == entry.id ? Color.primary : AuralStyle.secondary).lineLimit(2)
                    }.auralPadding(.vertical, 4).tag(entry.id)
                        .help("\(entry.name) · \(entry.measurement) · \(entry.collection)")
                        .accessibilityElement(children: .combine)
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            }.auralAnimation(AuralMotion.fade, value: results.isEmpty)
            if let date = browser.loadedAt {
                Text("Catalog loaded \(date.formatted(date: .abbreviated, time: .shortened))")
                    .auralFont(size: 10).foregroundStyle(AuralStyle.secondary)
            }
        }.auralAnimation(value: browser.loading).auralPanel(padding: 16)
    }

    private var detail: some View {
        ZStack {
            if let entry = selected {
                VStack(alignment: .leading, spacing: 12 * interfaceScale) {
                    ScrollView {
                        profileDetails(entry)
                    }
                    if let preview = browser.preview, preview.entry.id == entry.id {
                        Group {
                        Divider()
                        Text("Import saves a preset, replaces your EQ, and stops processing. Click Start EQ when ready. Undo restores the previous EQ.")
                            .auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { model.importOnlineAutoEQ(preview) } label: {
                            Label("Import profile", systemImage: "square.and.arrow.down").auralFrame(maxWidth: .infinity)
                        }.buttonStyle(AuralButtonStyle(prominent: true))
                        }.transition(.auralReveal(.bottom, reduceMotion: reduceMotion))
                    }
                }
            } else {
                VStack(spacing: 14 * interfaceScale) {
                    Image(systemName: "headphones").auralFont(size: 33, weight: .light)
                        .foregroundStyle(AuralStyle.secondary).accessibilityHidden(true)
                    Text("Choose your headphones").auralFont(size: 20, weight: .semibold)
                    Text("Search by brand or model. Different measurements appear separately so you can compare their corrections.")
                        .auralFont(size: 13).foregroundStyle(AuralStyle.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }.auralPadding(20).auralFrame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .auralAnimation(AuralMotion.fade, value: selected == nil)
        .auralAnimation(value: browser.preview?.entry.id)
        .auralPanel()
    }

    private func profileDetails(_ entry: AutoEQCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 16 * interfaceScale) {
            AuralSectionLabel(title: "AUTOEQ CORRECTION")
            Text(entry.name).auralFont(size: 22, weight: .semibold).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6 * interfaceScale) {
                Text("Measured by \(entry.measurement)")
                Text(entry.collection).foregroundStyle(AuralStyle.secondary)
                Link("View original result", destination: entry.resultURL)
            }.auralFont(size: 12).textSelection(.enabled)
            if let preview = browser.preview, preview.entry.id == entry.id {
                ResponseCurve(profile: preview.profile, rate: model.responseRate, bypass: false, running: false)
                    .equatable().auralFrame(height: 220)
                    .transition(.opacity)
                Text("\(preview.profile.filters?.count ?? 0) parametric filters · Preamp \(preview.profile.preamp, specifier: "%.1f") dB")
                    .auralFont(size: 12).foregroundStyle(AuralStyle.secondary)
                    .transition(.opacity)
            } else if browser.previewEntryID == entry.id, let error = browser.previewError {
                AuralNotice(message: error, isError: true).transition(.auralReveal(reduceMotion: reduceMotion))
                Button("Retry download") { previewRevision += 1 }.buttonStyle(AuralButtonStyle()).transition(.opacity)
            } else {
                HStack { ProgressView().auralControlSize(.small); Text("Downloading profile…") }.auralFont(size: 12)
                    .transition(.opacity)
            }
            Divider()
            Text("This is AutoEQ’s computed correction using the published target for this result. Match the model, pads, and listening mode shown in its name.")
                .auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .auralAnimation(value: browser.previewError)
        .auralFrame(maxWidth: .infinity, alignment: .leading)
    }

    private func clearHiddenSelection() {
        if let selectedID, !matches.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }
}
