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

    func testRemoteRefreshAndResetNotifications() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["provider-Claude"].waitForExistence(timeout: 25))
        let refresh = app.buttons["remote-refresh"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: refresh)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        refresh.tap()
        let fresh = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Mac refreshed"), object: refresh)
        XCTAssertEqual(XCTWaiter.wait(for: [fresh], timeout: 65), .completed)
        XCTAssertTrue(app.buttons["codex-reset-banner"].exists)
        capture("Fresh Mac readings and reset announcement")
        app.buttons["reset-alerts"].tap()
        XCTAssertTrue(app.staticTexts["Codex resets"].waitForExistence(timeout: 5))
        let enable = app.buttons["enable-reset-notifications"]
        if enable.exists {
            enable.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let allow = springboard.alerts.buttons["Allow"]
            if allow.waitForExistence(timeout: 5) { allow.tap() }
        }
        XCTAssertTrue(app.staticTexts["alerts-enabled"].waitForExistence(timeout: 15), "Notifications need to be allowed on this phone.")
        capture("Enabled reset alerts")
        app.buttons["test-reset-notification"].tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notification = system.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Token Watch test")).firstMatch
        XCTAssertTrue(notification.waitForExistence(timeout: 10), "A real test alert should be presented on the phone.")
        capture("Delivered notification")
        app.buttons["Done"].tap()
    }

    func testAutomaticConnectionRecovery() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["provider-Claude"].waitForExistence(timeout: 10), "Saved readings remain available during an interruption.")
        let offline = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Can’t reach your Mac")).firstMatch
        XCTAssertTrue(offline.waitForExistence(timeout: 20), "Start this check with the paired Mac app stopped.")
        XCTAssertEqual(app.buttons["connection"].value as? String, "Offline")
        capture("Automatically reconnecting with saved readings")
        NSLog("TOKEN_WATCH_RECOVERY_OFFLINE_OBSERVED")
        let recovered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Connected"), object: app.buttons["connection"])
        XCTAssertEqual(XCTWaiter.wait(for: [recovered], timeout: 50), .completed, "The host harness restarts the Mac; the phone must recover without a tap.")
        XCTAssertFalse(offline.exists)
        capture("Automatically reconnected to Mac")

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertEqual(app.buttons["connection"].value as? String, "Connected")
        capture("Connected after returning to app")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
