// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import XCTest
final class InitialUITests: XCTestCase {
    @MainActor func testClientLifecycleWithSyntheticFrames() {
        let app = XCUIApplication(); app.launch(); defer { app.terminate() }
        let result = app.staticTexts["fixture.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 12), app.debugDescription)
        let done = NSPredicate(format: "label != 'RUNNING'")
        expectation(for: done, evaluatedWith: result)
        waitForExpectations(timeout: 12)
        XCTAssertEqual(result.label, "PASS")
    }

    @MainActor func testInterruptedSourceRetriesOnce() {
        let app = XCUIApplication(); app.launchArguments = ["-TouchBarRetryOnly"]; app.launch(); defer { app.terminate() }
        let result = app.staticTexts["fixture.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 12), app.debugDescription)
        expectation(for: NSPredicate(format: "label != 'RUNNING'"), evaluatedWith: result)
        waitForExpectations(timeout: 25)
        XCTAssertEqual(result.label, "PASS")
    }
}
