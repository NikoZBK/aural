import AppKit
import Combine

enum AppIconState: CaseIterable {
    case listening, processing

    init(running: Bool, bypass: Bool) {
        self = running && !bypass ? .processing : .listening
    }

    var resourceName: String {
        switch self {
        case .listening: return "AppIcon"
        case .processing: return "AppIconActive"
        }
    }
}

/// Lives with the application delegate, so closing every window does not stop icon updates.
@MainActor final class AppIconController: ObservableObject {
    @Published private(set) var image: NSImage?
    private let images: [AppIconState: NSImage]
    private let setApplicationIcon: @MainActor (NSImage) -> Void
    private var updatesApplicationIcon = false
    private var observation: AnyCancellable?

    init(running: AnyPublisher<Bool, Never>, bypass: AnyPublisher<Bool, Never>,
         loadImage: @MainActor (String) -> NSImage? = AppIconController.loadImage,
         setApplicationIcon: @escaping @MainActor (NSImage) -> Void = { NSApplication.shared.applicationIconImage = $0 },
         reportError: @escaping @MainActor (String) -> Void) {
        var images: [AppIconState: NSImage] = [:]
        for state in AppIconState.allCases { images[state] = loadImage(state.resourceName) }
        self.images = images
        self.setApplicationIcon = setApplicationIcon

        // Model publishes these values on the main actor. Observe only processing state,
        // not objectWillChange: metering and other UI changes must not redraw the Dock icon.
        observation = running.combineLatest(bypass)
            .map { AppIconState(running: $0, bypass: $1) }
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.image = self.images[state]
                if let image = self.image {
                    if self.updatesApplicationIcon { self.setApplicationIcon(image) }
                } else {
                    reportError("Aural could not load \(state.resourceName).icns. Reinstall the app to restore its icon.")
                }
            }
    }

    /// Apply the latest cached image once AppKit has finished launching and owns the Dock tile.
    func startUpdatingApplicationIcon() {
        guard !updatesApplicationIcon else { return }
        updatesApplicationIcon = true
        // Also replaces a stale Launch Services icon after an in-place update.
        if let image { setApplicationIcon(image) }
    }

    private static func loadImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }
}
