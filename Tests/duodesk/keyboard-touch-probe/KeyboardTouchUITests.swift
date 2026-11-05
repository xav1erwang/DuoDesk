// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import XCTest

final class KeyboardTouchUITests: XCTestCase {
    @MainActor
    func testHeldCommandAndTapRelease() {
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
        clear.tap()
        w.tap()
        XCTAssertEqual(result.label, "26d:1048576,26u:1048576")
        clear.tap()
        w.tap()
        XCTAssertEqual(result.label, "26d:1048576,26u:1048576")
        release.tap()
        clear.tap()
        w.tap()
        XCTAssertEqual(result.label, "26d:0,26u:0")

        hold.tap()
        clear.tap()
        app.buttons["duo.key.input-source"].tap()
        XCTAssertEqual(result.label, "224d:1310720,44d:1310720,44u:1310720,224u:1048576")
        clear.tap()
        w.tap()
        XCTAssertEqual(result.label, "26d:1048576,26u:1048576")
        release.tap()

        hold.tap()
        clear.tap()
        app.buttons["probe.video"].tap()
        XCTAssertEqual(result.label, "227u:0")
        app.buttons["probe.video"].tap()
        release.tap()

        clear.tap()
        command.tap()
        w.tap()
        XCTAssertEqual(result.label, "227d:1048576,227u:0,26d:0,26u:0")

        hold.tap()
        clear.tap()
        app.buttons["duo.trackpad"].tap()
        XCTAssertEqual(result.label, "pointer:leftDown,pointer:leftUp")
        clear.tap()
        w.tap()
        XCTAssertEqual(result.label, "26d:1048576,26u:1048576")
        release.tap()
        clear.tap()
        w.tap()
        XCTAssertEqual(result.label, "26d:0,26u:0")

        hold.tap()
        clear.tap()
        app.buttons["duo.mode.trackpad"].tap()
        XCTAssertEqual(result.label, "227u:0")
    }
}
