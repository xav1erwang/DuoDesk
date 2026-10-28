// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import XCTest
final class InitialUITests: XCTestCase {
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

}
