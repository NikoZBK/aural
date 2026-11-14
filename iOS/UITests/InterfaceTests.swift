import XCTest

final class InterfaceTests: XCTestCase {
    @MainActor
    func testScreensAndDraftCancellation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--preview-fixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Aural"].waitForExistence(timeout: 20))
        capture("01-equalizer")
        app.buttons["Presets"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Find your headphones"].waitForExistence(timeout: 5) || app.staticTexts["Find your headphones"].exists)
        capture("02-presets")
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.switches["Peak protection"].waitForExistence(timeout: 5))
        capture("03-settings")
        app.buttons["Equalizer"].firstMatch.tap()
        let scroll = app.scrollViews["equalizer.scroll"]
        let advanced = app.buttons["Advanced"]
        for _ in 0..<5 where !advanced.isHittable { scroll.swipeUp() }
        XCTAssertTrue(advanced.isHittable)
        advanced.tap()
        XCTAssertTrue(app.navigationBars["Edit filters"].waitForExistence(timeout: 5))
        capture("04-filter-workspace")
        // A precise value may be typed without altering the active EQ before Apply.
        let preamp = app.textFields["Preamp in dB"]
        XCTAssertTrue(preamp.exists)
        preamp.tap()
        let old = preamp.value as? String ?? ""
        preamp.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "-17.123456")
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.navigationBars["Edit filters"].exists)
        advanced.tap()
        XCTAssertNotEqual(app.textFields["Preamp in dB"].value as? String, "-17.123456")
        app.buttons["Cancel"].tap()
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
