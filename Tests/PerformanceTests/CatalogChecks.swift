import Foundation

private let catalogFixture = """
# Index
- [Sennheiser HD 650](./oratory1990/over-ear/Sennheiser%20HD%20650) by oratory1990
- [Sennheiser HD 650](./crinacle/GRAS%2043AG-7%20over-ear/Sennheiser%20HD%20650) by crinacle on GRAS 43AG-7
- [Sony WH-1000XM5 (ANC on)](./Rtings/HMS%20II.3%20over-ear/Sony%20WH-1000XM5%20(ANC%20on)) by Rtings on HMS II.3
- [Test + & # café\u{200B}](./Test%20Source/711%20in-ear/Test%20+%20&%20%23%20caf%C3%A9%E2%80%8B) by Test Source on 711
"""
private let profileFixture = "Preamp: -6.123456789 dB\nFilter 1: ON PK Fc 1234.56789 Hz Gain -2.3456789 dB Q 0.7123456789\n"

private struct CatalogHTTPStub: Sendable {
    var status = 200
    let data: Data
    var length: Int? = nil
}

private final class CatalogURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stub = CatalogHTTPStub(data: Data())
    static func respond(_ value: CatalogHTTPStub) {
        lock.lock(); defer { lock.unlock() }
        stub = value
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let stub = Self.stub; Self.lock.unlock()
        var headers = ["Content-Type": "text/plain"]
        if let length = stub.length { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: stub.data)
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private actor PreviewGate {
    private var pending: [String: CheckedContinuation<AutoEQPreview, Error>] = [:]
    func fetch(_ entry: AutoEQCatalogEntry) async throws -> AutoEQPreview {
        try await withCheckedThrowingContinuation { pending[entry.id] = $0 }
    }
    func contains(_ id: String) -> Bool { pending[id] != nil }
    func finish(_ preview: AutoEQPreview) { pending.removeValue(forKey: preview.entry.id)!.resume(returning: preview) }
}

@MainActor func checkAutoEQCatalog() async throws {
    let entries = try AutoEQCatalog.parse(catalogFixture.replacingOccurrences(of: "\n", with: "\r\n"))
    require(entries.count == 4 && entries[0].id != entries[1].id, "Measurements of the same headphone must remain separate")
    require(AutoEQCatalogEntry.matching(entries, query: "HD650").count == 2, "Search must match model numbers without spaces")
    require(AutoEQCatalogEntry.matching(entries, query: "  hd650 ORATORY ").count == 1, "Search must combine case-insensitive model and measurement tokens")
    require(AutoEQCatalogEntry.matching(entries, query: "wh1000xm5", provider: "Rtings").count == 1, "Search must ignore model punctuation and filter by source")
    require(AutoEQCatalogEntry.matching(entries, query: "cafe").count == 1, "Search must match diacritics")
    require(AutoEQCatalogEntry.matching(entries, query: "missing").isEmpty, "An unmatched search must be empty")
    require(entries[3].profileURL.lastPathComponent == "Test + & # café\u{200B} ParametricEQ.txt" && entries[3].profileURL.fragment == nil,
            "Download URLs must preserve punctuation, Unicode, and formatting characters used by the live catalog")
    for invalid in ["<html>not a catalog</html>", "# Index", "- [Broken](https://example.com/profile) by Source",
                    "- [Broken](./Source/../Model) by Source", "- [Broken](./Source/over-ear/%2Fetc) by Source",
                    "- [Broken](./Source/over-ear/%00) by Source", catalogFixture + "\n" + catalogFixture] {
        do { _ = try AutoEQCatalog.parse(invalid); fatalError("Accepted malformed AutoEQ catalog") }
        catch is AudioFailure { }
    }
    do { _ = try AutoEQCatalog.parse(String(repeating: "x", count: AutoEQCatalog.maximumIndexBytes + 1)); fatalError("Accepted oversized catalog") }
    catch is AudioFailure { }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CatalogURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = AutoEQCatalogClient(session: session)
    CatalogURLProtocol.respond(CatalogHTTPStub(data: Data(catalogFixture.utf8)))
    let downloaded = try await client.catalog()
    require(downloaded == entries, "HTTP catalog loading must preserve every measurement")
    CatalogURLProtocol.respond(CatalogHTTPStub(data: Data(profileFixture.utf8)))
    let preview = try await client.preview(entries[0])
    require(preview.profile.preamp == -6.123456789 && preview.profile.filters?[0].q == 0.7123456789,
            "Downloading must retain the published precision")
    require(preview.profile.autoEQSource == entries[0].origin, "Preview must retain source attribution")
    let restored = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(preview.profile))
    require(restored == preview.profile, "Source attribution and exact values must survive persistence and backup")
    for stub in [CatalogHTTPStub(status: 404, data: Data()), CatalogHTTPStub(status: 429, data: Data()),
                 CatalogHTTPStub(status: 500, data: Data()), CatalogHTTPStub(data: Data([0xff])),
                 CatalogHTTPStub(data: Data("GraphicEQ: 20 -3".utf8)),
                 CatalogHTTPStub(data: Data(), length: 65537),
                 CatalogHTTPStub(data: Data(repeating: 120, count: 65537))] {
        CatalogURLProtocol.respond(stub)
        do { _ = try await client.preview(entries[0]); fatalError("Accepted failed or invalid AutoEQ download") }
        catch is AudioFailure { }
    }

    let browser = AutoEQBrowser(fetchCatalog: { refresh in
        if refresh { throw URLError(.notConnectedToInternet) }
        return entries
    }, fetchPreview: { entry in
        if entry.id == entries[1].id { throw AudioFailure(message: "Profile unavailable") }
        return preview
    })
    await browser.loadCatalog()
    await browser.loadCatalog(refresh: true)
    require(browser.entries == entries && browser.catalogError != nil && !browser.loading, "A failed refresh must keep the existing catalog and show the failure")
    await browser.loadPreview(entries[0])
    require(browser.preview == preview, "A successful download must show a preview")
    await browser.loadPreview(entries[1])
    require(browser.preview == nil && browser.previewError == "Profile unavailable", "A failed selection must remove the previous importable profile")
    await browser.loadPreview(nil)
    require(browser.preview == nil && browser.previewError == nil && !browser.previewLoading, "Clearing selection must clear its preview")

    let gate = PreviewGate()
    let delayed = AutoEQBrowser(fetchCatalog: { _ in entries }, fetchPreview: { try await gate.fetch($0) })
    let first = Task { await delayed.loadPreview(entries[0]) }
    while !(await gate.contains(entries[0].id)) { await Task.yield() }
    let second = Task { await delayed.loadPreview(entries[1]) }
    while !(await gate.contains(entries[1].id)) { await Task.yield() }
    let secondPreview = AutoEQPreview(entry: entries[1], profile: preview.profile)
    await gate.finish(secondPreview); await second.value
    await gate.finish(preview); await first.value
    require(delayed.preview == secondPreview, "A late response from a previous selection must never replace the current preview")
    let cancelled = Task { await delayed.loadPreview(entries[2]) }
    while !(await gate.contains(entries[2].id)) { await Task.yield() }
    cancelled.cancel()
    await gate.finish(AutoEQPreview(entry: entries[2], profile: preview.profile)); await cancelled.value
    require(delayed.preview == nil && delayed.previewError == nil && !delayed.previewLoading, "A cancelled download must never publish an importable profile")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aural-autoeq-checks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("settings.json")
    let model = Model(settingsFile: file, readLoginStatus: { .notRegistered })
    let original = model.profile, output = model.selectedUID, revision = model.editRevision
    // Exercise the rejected-import control state without opening a real audio route.
    model.running = true; model.bypass = true
    var invalid = preview.profile; invalid.preamp = .nan
    model.importOnlineAutoEQ(AutoEQPreview(entry: entries[0], profile: invalid))
    require(model.profile == original && model.editRevision == revision && model.customPresets.isEmpty && model.error != nil && model.running && model.bypass,
            "Invalid downloaded profiles must not change EQ, history, or presets")
    model.importOnlineAutoEQ(preview)
    require(model.profile == preview.profile && !model.running && !model.route.hasResources && !model.bypass,
            "Online import must replace EQ while leaving processing stopped")
    require(model.selectedUID == output && model.selectedPresetName == entries[0].presetName && model.canUndo && model.error == nil,
            "Import must preserve output, select the saved preset, and record undo")
    model.importOnlineAutoEQ(preview)
    require(model.customPresets.count == 2 && model.selectedPresetName == entries[0].presetName + " (2)", "Repeated online imports must not overwrite existing presets")
    model.undoProfile(); model.undoProfile()
    require(model.profile == original && !model.running, "Undo must restore the previous EQ without starting processing")
    let saved = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
    require(saved.presets[entries[0].presetName]?.autoEQSource == entries[0].origin, "The saved library must retain the original result link")
    let blockedParent = directory.appendingPathComponent("file-as-directory")
    try Data("fixture".utf8).write(to: blockedParent)
    let blocked = Model(settingsFile: blockedParent.appendingPathComponent("settings.json"), readLoginStatus: { .notRegistered })
    blocked.importOnlineAutoEQ(preview)
    require(blocked.error?.contains("Could not save settings:") == true && blocked.importNotice == nil && !blocked.running,
            "A failed preset save must report failure without a success notice or starting audio")
    print("PASS AutoEQ search, source filtering, URL encoding, HTTP failures, bounded downloads, precision, attribution, cancellation, stale-response exclusion, preset import, duplicate names, and undo")
}

func checkAutoEQLive() async throws {
    let client = AutoEQCatalogClient()
    let entries = try await client.catalog(refresh: true)
    guard let entry = AutoEQCatalogEntry.matching(entries, query: "HD650", provider: "oratory1990").first(where: { $0.name == "Sennheiser HD 650" }) else {
        throw AudioFailure(message: "The live AutoEQ catalog did not contain the expected reference profile.")
    }
    let preview = try await client.preview(entry)
    require(preview.profile.filters?.count == 10 && preview.profile.autoEQSource == entry.origin, "Live download must parse the published parametric profile and preserve its source")
    print("PASS live AutoEQ catalog: \(entries.count) results; downloaded \(entry.presetName), \(preview.profile.filters!.count) filters, \(preview.profile.preamp) dB preamp")
}
