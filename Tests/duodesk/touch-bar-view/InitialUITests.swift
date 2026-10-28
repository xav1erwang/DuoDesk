// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import XCTest
final class InitialUITests: XCTestCase {
    @MainActor func testPictureChromePreservesPixelsAndEdgeTouches() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch(); defer { app.terminate() }
        let surface = app.otherElements["duo.touchbar.surface"]
        let audit = app.staticTexts["fixture.chromeAudit"]
        let events = app.staticTexts["fixture.events"]
        XCTAssertTrue(surface.waitForExistence(timeout: 12), app.debugDescription)
        expectation(for: NSPredicate(format: "label != 'Checking'"), evaluatedWith: audit)
        waitForExpectations(timeout: 12)
        XCTAssertTrue(audit.label.hasPrefix("PASS live=0"), audit.label)
        print("TOUCH BAR CHROME PIXELS: \(audit.label) (synthetic picture)")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).tap()
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        let log = events.label
        let endpoints = log.components(separatedBy: ",").filter { !$0.hasPrefix("moved:") }
        XCTAssertEqual(endpoints, ["began:1:1", "ended:1:1", "began:99:1", "ended:99:1"], log)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Touch Bar chrome fixture (synthetic, not live)"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor func testTouchCoordinatesAndSourceReplacement() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch(); defer { app.terminate() }
        let surface = app.otherElements["duo.touchbar.surface"]
        let events = app.staticTexts["fixture.events"]
        XCTAssertTrue(surface.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(events.label, "none")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertEqual(events.label, "none", "Letterbox must not start a touch")
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        let log = events.label
        XCTAssertTrue(log.contains("began:25:1"), log)
        XCTAssertTrue(log.contains("ended:75:1"), log)
        XCTAssertTrue(log.contains("moved:"), log)
        app.buttons["替换来源"].tap()
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8)
        let changed = events.label
        XCTAssertTrue(changed.contains("began:50:1"), changed)
        XCTAssertTrue(changed.contains("cancelled:50:1"), changed)
        XCTAssertFalse(changed.contains("ended:"), changed)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Touch Bar touch fixture (not live)"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor func testRehostingCancelsOldTouchAndShowsNewLayer() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch(); defer { app.terminate() }
        let surface = app.otherElements["duo.touchbar.surface"]
        let events = app.staticTexts["fixture.events"]
        XCTAssertTrue(surface.waitForExistence(timeout: 12), app.debugDescription)
        app.buttons["替换画面容器"].tap()
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8)
        let changed = events.label
        XCTAssertTrue(changed.contains("began:50:1"), changed)
        XCTAssertTrue(changed.contains("cancelled:50:1"), changed)
        XCTAssertFalse(changed.contains("ended:"), changed)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Rehosted synthetic layer (not live)"; screenshot.lifetime = .keepAlways; add(screenshot)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let resumed = events.label
        XCTAssertTrue(resumed.hasSuffix("began:50:1,ended:50:1"), resumed)
    }

    @MainActor func testReadOnlyStateRejectsTouchesAndCancelsActiveContact() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch(); defer { app.terminate() }
        let surface = app.descendants(matching: .any)["duo.touchbar.surface"]
        let events = app.staticTexts["fixture.events"]
        XCTAssertTrue(surface.waitForExistence(timeout: 12), app.debugDescription)
        let interactiveWidth = surface.frame.width
        app.buttons["设为只读"].tap()
        XCTAssertEqual(surface.value as? String, "只读")
        XCTAssertLessThan(surface.frame.width, interactiveWidth, "The read-only label needs its own space beside the picture")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(events.label, "none")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Read-only synthetic Touch Bar (not live)"; screenshot.lifetime = .keepAlways; add(screenshot)

        app.buttons["恢复触摸"].tap()
        XCTAssertNotEqual(surface.value as? String, "只读")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(events.label.hasSuffix("began:50:1,ended:50:1"), events.label)

        app.buttons["触摸时设为只读"].tap()
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8)
        let changed = events.label
        XCTAssertTrue(changed.contains("began:50:1"), changed)
        XCTAssertTrue(changed.contains("cancelled:50:1"), changed)
        XCTAssertFalse(changed.contains("ended:"), changed)
        XCTAssertEqual(surface.value as? String, "只读")
    }

}
