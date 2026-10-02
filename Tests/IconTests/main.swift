import AppKit
import Combine

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@MainActor final class IconRecorder {
    var loaded: [String] = []
    var applied: [NSImage] = []
    var errors: [String] = []
}

@MainActor final class WeakController {
    weak var value: AppIconController?
    init(_ value: AppIconController?) { self.value = value }
}

@MainActor final class Fixture {
    let running = CurrentValueSubject<Bool, Never>(false)
    let bypass = CurrentValueSubject<Bool, Never>(false)
    let eyesClosed = NSImage(size: NSSize(width: 16, height: 16))
    let listening = NSImage(size: NSSize(width: 16, height: 16))
    let recorder = IconRecorder()
    var controller: AppIconController?

    init(missing: Set<String> = [], startUpdating: Bool = true) {
        let recorder = recorder, eyesClosed = eyesClosed, listening = listening
        controller = AppIconController(running: running.eraseToAnyPublisher(), bypass: bypass.eraseToAnyPublisher(), loadImage: { name in
            recorder.loaded.append(name)
            if missing.contains(name) { return nil }
            switch name {
            case "AppIconSleeping": return eyesClosed
            case "AppIcon": return listening
            default: fatalError("Unexpected icon resource: \(name)")
            }
        }, setApplicationIcon: { recorder.applied.append($0) }, reportError: { recorder.errors.append($0) })
        if startUpdating { controller?.startUpdatingApplicationIcon() }
    }

    func requireImage(_ image: NSImage, _ message: String) {
        require(controller?.image === image && recorder.applied.last === image, message)
    }
}

@main struct IconTests {
    @MainActor static func main() {
        require(AppIconState(running: false, bypass: false) == .listening, "Stopped EQ must use the listening dog")
        require(AppIconState(running: false, bypass: true) == .listening, "Stopped and bypassed EQ must use the listening dog")
        require(AppIconState(running: true, bypass: true) == .listening, "Running bypass must use the listening dog")
        require(AppIconState(running: true, bypass: false) == .processing, "Processing EQ must use the closed-eyes dog")

        require(AppIconState.listening.resourceName == "AppIcon", "Inactive state must preserve the original open-eyed artwork")
        require(AppIconState.processing.resourceName == "AppIconSleeping", "Active state must use the existing closed-eyes artwork")

        let fixture = Fixture()
        fixture.requireImage(fixture.listening, "Initial stopped state must update both the UI image and Dock image")
        require(fixture.recorder.loaded == ["AppIcon", "AppIconSleeping"], "Load each named resource exactly once at application startup")
        fixture.running.send(false)
        fixture.bypass.send(true)
        fixture.running.send(true)
        fixture.requireImage(fixture.listening, "Starting while bypassed must keep the listening dog")
        require(fixture.recorder.applied.count == 1, "Equivalent listening states must not repeat Dock icon updates")

        fixture.bypass.send(false)
        fixture.requireImage(fixture.eyesClosed, "Disabling bypass while running must close the dog’s eyes")
        fixture.running.send(true)
        fixture.bypass.send(false)
        require(fixture.recorder.applied.count == 2, "Duplicate processing state publications must not repeat Dock updates")

        fixture.bypass.send(true)
        fixture.requireImage(fixture.listening, "Enabling bypass must restore the listening dog")
        fixture.running.send(false)
        fixture.bypass.send(false)
        require(fixture.recorder.applied.count == 3, "Stopping and clearing bypass while stopped must keep one listening update")
        fixture.running.send(true)
        fixture.requireImage(fixture.eyesClosed, "Restarting EQ must restore the cached closed-eyes dog")
        fixture.running.send(false)
        fixture.requireImage(fixture.listening, "Stopping active EQ must restore the cached listening dog")
        require(fixture.recorder.applied.count == 5 && fixture.recorder.loaded.count == 2, "Transitions must reuse cached assets without redundant updates")
        require(fixture.recorder.errors.isEmpty, "Available artwork must not report errors")

        let launching = Fixture(startUpdating: false)
        require(launching.controller?.image === launching.listening && launching.recorder.applied.isEmpty, "Initialization must prepare the UI image without changing AppKit's icon before launch completes")
        launching.running.send(true)
        require(launching.controller?.image === launching.eyesClosed && launching.recorder.applied.isEmpty, "Pre-launch state changes must update the UI image and defer Dock writes")
        launching.controller?.startUpdatingApplicationIcon()
        launching.requireImage(launching.eyesClosed, "Launch completion must apply the latest processing state")
        launching.controller?.startUpdatingApplicationIcon()
        require(launching.recorder.applied.count == 1, "Repeated activation must not write the same Dock icon again")
        launching.running.send(false)
        launching.requireImage(launching.listening, "State observation must remain active after launch completion")

        let released = WeakController(fixture.controller)
        fixture.controller = nil
        require(released.value == nil, "The processing observation must not retain the icon controller")
        fixture.running.send(true)
        require(fixture.recorder.applied.count == 5, "Releasing the controller must cancel processing observation")

        let incomplete = Fixture(missing: ["AppIcon"])
        require(incomplete.controller?.image == nil && incomplete.recorder.applied.isEmpty, "Missing listening artwork must not claim to apply an icon")
        require(incomplete.recorder.errors.count == 1 && incomplete.recorder.errors[0].contains("AppIcon.icns"), "Missing artwork must report the specific resource failure")
        incomplete.running.send(false)
        require(incomplete.recorder.errors.count == 1, "Duplicate state notifications must not repeatedly report the same missing asset")
        incomplete.running.send(true)
        incomplete.requireImage(incomplete.eyesClosed, "An unavailable variant must not prevent using the other valid asset")

        let missingProcessing = Fixture(missing: ["AppIconSleeping"])
        missingProcessing.requireImage(missingProcessing.listening, "Missing processing artwork must not affect the valid initial listening image")
        missingProcessing.running.send(true)
        require(missingProcessing.controller?.image == nil && missingProcessing.recorder.applied.count == 1, "Missing processing artwork must not claim a Dock update")
        require(missingProcessing.recorder.errors.count == 1 && missingProcessing.recorder.errors[0].contains("AppIconSleeping.icns"), "Missing closed-eyes artwork must identify its resource")

        print("PASS icon state combinations, deferred launch activation, live transitions without windows, shared image updates, cached resources, duplicate suppression, cancellation, and missing artwork errors")
    }
}
