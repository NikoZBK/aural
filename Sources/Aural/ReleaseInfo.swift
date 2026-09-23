import Foundation

struct AppVersion: Comparable {
    let parts: [Int]
    init(_ text: String) throws {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              pieces.allSatisfy({ Int($0) != nil }) else {
            throw AudioFailure(message: "The release version is not recognized. Visit Releases to check manually.")
        }
        parts = pieces.compactMap { Int($0) } + Array(repeating: 0, count: 3 - pieces.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct ReleaseInfo: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name; case browserDownloadURL = "browser_download_url" }
    }
    let tagName: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    enum CodingKeys: String, CodingKey { case body, draft, prerelease, assets; case tagName = "tag_name" }

    func version() throws -> AppVersion {
        guard !draft && !prerelease else { throw AudioFailure(message: "GitHub did not return a stable release. Visit Releases to check manually.") }
        return try AppVersion(tagName)
    }
    var changelog: String {
        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "No changelog was provided for this release." }
        return body
    }
    var downloadURL: URL? {
        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        for ext in ["dmg", "zip"] {
            let name = "Aural-\(version)-universal.\(ext)"
            if let asset = assets.first(where: { $0.name == name }),
               asset.browserDownloadURL.scheme == "https", asset.browserDownloadURL.host == "github.com",
               asset.browserDownloadURL.user == nil, asset.browserDownloadURL.password == nil,
               asset.browserDownloadURL.port == nil,
               asset.browserDownloadURL.path == "/NikoZBK/aural/releases/download/\(tagName)/\(name)" {
                return asset.browserDownloadURL
            }
        }
        return nil
    }
}
