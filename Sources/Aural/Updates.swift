import SwiftUI

@MainActor final class UpdateChecker: ObservableObject {
    @Published private(set) var release: ReleaseInfo?
    @Published private(set) var checking = false
    @Published private(set) var status = ""
    @Published private(set) var available = false
    @Published private(set) var error: String?
    let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    static let releasesURL = URL(string: "https://github.com/NikoZBK/aural/releases")!

    func check() async {
        guard !checking else { return }
        checking = true; release = nil; available = false; error = nil
        defer { checking = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/NikoZBK/aural/releases/latest")!)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Aural/\(installed)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AudioFailure(message: "GitHub returned an invalid response.") }
            guard http.statusCode == 200 else {
                if http.statusCode == 403 || http.statusCode == 429 { throw AudioFailure(message: "GitHub is limiting update checks. Try again later or visit Releases.") }
                if http.statusCode == 404 { throw AudioFailure(message: "No published release was found. Visit Releases to check manually.") }
                throw AudioFailure(message: "GitHub could not check for updates (HTTP \(http.statusCode)). Try again later.")
            }
            guard data.count <= 1_048_576 else { throw AudioFailure(message: "The release response is too large. Visit Releases to check manually.") }
            let latest = try JSONDecoder().decode(ReleaseInfo.self, from: data)
            let remoteVersion = try latest.version(), localVersion = try AppVersion(installed)
            available = remoteVersion > localVersion
            status = available ? "Aural \(latest.tagName) is available" : (remoteVersion == localVersion ? "You’re up to date" : "You’re running a newer version")
            release = latest
        } catch is CancellationError { status = "Update check cancelled." }
        catch { self.error = error.localizedDescription }
    }

    func download() {
        guard let url = release?.downloadURL else { error = "No compatible installer was found. Visit Releases to download manually."; return }
        if !NSWorkspace.shared.open(url) { error = "Could not open your browser. Visit Releases to download manually." }
    }
}

struct UpdatesView: View {
    @StateObject private var checker = UpdateChecker()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Software updates").font(.title2.weight(.semibold))
            Text("Installed: Aural \(checker.installed)").foregroundStyle(.secondary)
            if checker.checking {
                HStack { ProgressView().controlSize(.small); Text("Checking GitHub Releases…") }
            } else if let error = checker.error {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(checker.status).font(.headline)
            }
            if let release = checker.release {
                Text("Latest release · \(release.tagName)").font(.subheadline.weight(.medium))
                ScrollView {
                    Text(release.changelog)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 240).padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                if checker.available && release.downloadURL == nil {
                    Text("No compatible installer is attached. Visit Releases for download options.").foregroundStyle(.orange)
                }
            }
            Text("Downloads open in your browser. Quit Aural, then replace the app with the downloaded version. Your saved settings stay on this Mac.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Link("Releases page", destination: UpdateChecker.releasesURL)
                Spacer()
                Button("Check again") { Task { await checker.check() } }.disabled(checker.checking)
                if checker.available, checker.release?.downloadURL != nil {
                    Button("Download Update") { checker.download() }.buttonStyle(.borderedProminent)
                }
            }
        }.font(.system(size: 12)).padding(22).frame(width: 530)
            .background(AuralStyle.background).preferredColorScheme(.dark).tint(AuralStyle.accent)
            .task { await checker.check() }
    }
}
