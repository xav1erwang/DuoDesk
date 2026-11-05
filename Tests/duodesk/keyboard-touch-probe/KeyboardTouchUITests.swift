// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import XCTest

final class KeyboardTouchUITests: XCTestCase {
    @MainActor
    func testFirstChordAndTapLatch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-KeyboardTouchUI"]
        app.launch()
        defer { app.terminate() }

        let hold = app.buttons["probe.hold"]
        let release = app.buttons["probe.release"]
        let clear = app.buttons["probe.clear"]
        let result = app.staticTexts["probe.result"]
        let w = app.buttons["duo.key.hid-26"]
        let command = app.buttons["duo.key.modifier-227"]
        XCTAssertTrue(hold.waitForExistence(timeout: 15))
        XCTAssertTrue(w.waitForExistence(timeout: 10))
        XCTAssertTrue(command.exists)

        // The fixture sends the modifier's actual UIControl touch-down; W is a real UI tap.
        hold.tap()
        XCTAssertEqual(result.label, "command dispatched")
        XCTAssertTrue(command.isSelected, "Hold must reach the mounted Command control")
        w.tap()
        XCTAssertEqual(result.label, "command-w")
        clear.tap()
        w.tap()
        XCTAssertEqual(result.label, "command-w")
        release.tap()
        clear.tap()
        w.tap()
        XCTAssertEqual(result.label, "plain-w")

        clear.tap()
        command.tap()
        w.tap()
        XCTAssertEqual(result.label, "command-w")
        clear.tap()
        w.tap()
        XCTAssertEqual(result.label, "plain-w")

        hold.tap()
        clear.tap()
        app.buttons["duo.trackpad"].tap()
        XCTAssertEqual(result.label, "command-click")
        clear.tap()
        w.tap()
        XCTAssertEqual(result.label, "command-w")
        release.tap()
        clear.tap()
        w.tap()
        XCTAssertEqual(result.label, "plain-w")
    }
}
