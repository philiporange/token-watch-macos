import XCTest

/// Exercises the installed client against a paired Mac on a physical iPhone.
@MainActor
final class PhoneJourneyTests: XCTestCase {
    func testPairedDashboardNavigationAndRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let claude = app.buttons["provider-Claude"]
        XCTAssertTrue(claude.waitForExistence(timeout: 25), "A paired Mac must supply the dashboard.")
        capture("Long range dashboard")
        app.buttons["Session"].tap()
        XCTAssertTrue(app.buttons["Session"].isSelected)
        XCTAssertTrue(claude.label.localizedCaseInsensitiveContains("session"))
        capture("Session dashboard")
        app.buttons["Long range"].tap()
        XCTAssertTrue(app.buttons["Long range"].isSelected)
        claude.tap()
        XCTAssertTrue(app.staticTexts["LIMITS"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Weekly"].exists)
        capture("Provider detail")
        app.buttons["Done"].tap()

        app.buttons["connection"].tap()
        let address = app.textFields["mac-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertTrue((address.value as? String)?.contains(":8037") == true)
        XCTAssertTrue(app.secureTextFields["pairing-key"].exists)
        capture("Saved Mac connection")
        app.buttons["Done"].tap()

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["provider-Claude"].waitForExistence(timeout: 15), "Saved source and readings survive a relaunch.")
        capture("Restored dashboard")
    }

    func testOfflineSnapshotRemainsVisible() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["provider-Claude"].waitForExistence(timeout: 10))
        let offline = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Can’t reach your Mac")).firstMatch
        XCTAssertTrue(offline.waitForExistence(timeout: 20), "Stop the paired Mac before running this recovery check.")
        XCTAssertEqual(app.buttons["connection"].value as? String, "Offline")
        capture("Offline saved readings")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
