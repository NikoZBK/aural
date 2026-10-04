import Foundation

struct AutoEQCatalogEntry: Identifiable, Equatable, Sendable {
    let name: String
    let measurement: String
    let components: [String]
    private let searchText: String
    var id: String { components.joined(separator: "/") }
    var provider: String { components[0] }
    var collection: String { components[1] }
    var presetName: String { "\(name) · \(measurement)" }
    var resultURL: URL { components.reduce(AutoEQCatalog.resultsURL) { $0.appendingPathComponent($1) } }
    var profileURL: URL {
        components.reduce(AutoEQCatalog.rawResultsURL) { $0.appendingPathComponent($1) }
            .appendingPathComponent(components[2] + " ParametricEQ.txt")
    }
    var origin: AutoEQSource { AutoEQSource(name: name, measurement: measurement, url: resultURL) }

    fileprivate init(name: String, measurement: String, components: [String]) {
        self.name = name; self.measurement = measurement; self.components = components
        searchText = Self.normalized("\(name) \(measurement) \(components[1])")
    }

    static func matching(_ entries: [Self], query: String, provider: String = "") -> [Self] {
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map { normalized(String($0)) }.filter { !$0.isEmpty }
        return entries.filter { entry in
            (provider.isEmpty || entry.provider == provider) && tokens.allSatisfy { entry.searchText.contains($0) }
        }
    }

    private static func normalized(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

enum AutoEQCatalog {
    static let resultsURL = URL(string: "https://github.com/jaakkopasanen/AutoEq/tree/master/results")!
    static let rawResultsURL = URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results")!
    static let indexURL = rawResultsURL.appendingPathComponent("INDEX.md")
    static let maximumIndexBytes = 4 * 1024 * 1024

    // Keep all measurements distinct. The published index is the source of both
    // the display attribution and the exact directory/file name to download.
    static func parse(_ text: String) throws -> [AutoEQCatalogEntry] {
        guard text.utf8.count <= maximumIndexBytes else { throw AudioFailure(message: "The AutoEQ catalog exceeds the 4 MB limit.") }
        let pattern = try NSRegularExpression(pattern: #"^- \[(.+)\]\((\./.+)\) by (.+)$"#)
        var entries: [AutoEQCatalogEntry] = []
        var identifiers = Set<String>()
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- [") else { continue }
            func invalid() -> AudioFailure { AudioFailure(message: "AutoEQ catalog line \(index + 1) has an unsupported result. Try refreshing the catalog.") }
            guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let pathRange = Range(match.range(at: 2), in: line),
                  let measurementRange = Range(match.range(at: 3), in: line) else { throw invalid() }
            let name = String(line[nameRange]), measurement = String(line[measurementRange])
            let encoded = line[pathRange].dropFirst(2).split(separator: "/", omittingEmptySubsequences: false)
            guard encoded.count == 3, !name.trimmingCharacters(in: .whitespaces).isEmpty,
                  !measurement.trimmingCharacters(in: .whitespaces).isEmpty else { throw invalid() }
            let components = try encoded.map { component -> String in
                guard let decoded = String(component).removingPercentEncoding, !decoded.isEmpty,
                      decoded != ".", decoded != "..", !decoded.contains("/"), !decoded.contains("\\"),
                      !decoded.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }) else { throw invalid() }
                return decoded
            }
            let entry = AutoEQCatalogEntry(name: name, measurement: measurement, components: components)
            guard identifiers.insert(entry.id).inserted else { throw invalid() }
            entries.append(entry)
            guard entries.count <= 30000 else { throw AudioFailure(message: "The AutoEQ catalog contains too many results.") }
        }
        guard !entries.isEmpty else { throw AudioFailure(message: "AutoEQ returned an empty or unsupported catalog. Try refreshing the catalog.") }
        return entries
    }
}

struct AutoEQPreview: Equatable, Sendable {
    let entry: AutoEQCatalogEntry
    let profile: Profile
}

struct AutoEQCatalogClient: Sendable {
    var session: URLSession = .shared

    func catalog(refresh: Bool = false) async throws -> [AutoEQCatalogEntry] {
        let text = try await download(AutoEQCatalog.indexURL, limit: AutoEQCatalog.maximumIndexBytes, refresh: refresh)
        try Task.checkCancellation()
        return try AutoEQCatalog.parse(text)
    }

    func preview(_ entry: AutoEQCatalogEntry) async throws -> AutoEQPreview {
        let text = try await download(entry.profileURL, limit: 65536, refresh: false)
        try Task.checkCancellation()
        var profile = try AutoEQ.parse(text, name: entry.presetName)
        profile.autoEQSource = entry.origin
        return AutoEQPreview(entry: entry, profile: try profile.validated())
    }

    private func download(_ url: URL, limit: Int, refresh: Bool) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = refresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("Aural-AutoEQ", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AudioFailure(message: "AutoEQ returned an invalid response.") }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 { throw AudioFailure(message: "This AutoEQ result is no longer available. Refresh the catalog or choose another measurement.") }
            if http.statusCode == 403 || http.statusCode == 429 { throw AudioFailure(message: "GitHub is limiting AutoEQ downloads. Try again later.") }
            throw AudioFailure(message: "Could not download AutoEQ data (HTTP \(http.statusCode)). Try again.")
        }
        guard response.expectedContentLength <= limit else { throw AudioFailure(message: "The AutoEQ download exceeds the \(limit / 1024) KB limit.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw AudioFailure(message: "The AutoEQ download exceeds the \(limit / 1024) KB limit.") }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard let text = String(data: data, encoding: .utf8) else { throw AudioFailure(message: "AutoEQ returned data that is not UTF-8 text.") }
        return text
    }
}
