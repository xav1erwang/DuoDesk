// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import XCTest

final class KeyboardUITests: XCTestCase {
    @MainActor
    private func dismissSlideToTypeTip(_ app: XCUIApplication) -> Bool {
        let tip = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Speed up your typing")).firstMatch
        let next = app.buttons["Continue"]
        guard tip.exists, next.exists else { return false }
        next.tap()
        return true
    }

    @MainActor
    private func typePinyin(_ text: String, in app: XCUIApplication) {
        _ = dismissSlideToTypeTip(app)
        for character in text {
            let key = app.keyboards.keys[String(character)]
            XCTAssertTrue(key.waitForExistence(timeout: 3), "Expected a visible Pinyin QWERTY key")
            key.tap()
            // The first letter can open the system's ordinary typing tutorial instead of typing.
            if dismissSlideToTypeTip(app) { key.tap() }
        }
    }

    @MainActor
    func testChineseComposition() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["ime.start"].waitForExistence(timeout: 10))
        app.buttons["ime.start"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["ime.focus"].label, "editing")
        XCTAssertTrue(app.staticTexts["ime.source"].label.hasPrefix("zh-Hans"), "This owned-device test requires an already enabled native Chinese keyboard")
        let before = XCTAttachment(string: app.debugDescription)
        before.name = "System keyboard hierarchy before input"; before.lifetime = .keepAlways
        add(before)
        typePinyin("nihao", in: app)
        let after = XCTAttachment(string: app.debugDescription)
        after.name = "System keyboard hierarchy after input"; after.lifetime = .keepAlways
        add(after)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "System keyboard and production responder"; shot.lifetime = .keepAlways
        add(shot)
        let marked = NSPredicate(format: "label != '<none>'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: marked, object: app.staticTexts["ime.preedit"])], timeout: 3), .completed)
        XCTAssertEqual(app.staticTexts["ime.received"].label, "<empty>", "Provisional Pinyin must not be sent")
        app.keyboards.keys["space"].tap()
        let confirmed = NSPredicate(format: "label == '你好'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: confirmed, object: app.staticTexts["ime.received"])], timeout: 3), .completed)
        typePinyin("zhong", in: app)
        XCTAssertNotEqual(app.staticTexts["ime.preedit"].label, "<none>")
        app.buttons["ime.close"].tap()
        XCTAssertEqual(app.staticTexts["ime.focus"].label, "idle")
        XCTAssertEqual(app.staticTexts["ime.received"].label, "你好", "Closing the keyboard must discard unfinished text")
    }

    @MainActor
    func testCompositionDoesNotCrossVideoGeneration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["ime.start"].waitForExistence(timeout: 10))
        app.buttons["ime.start"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["ime.source"].label.hasPrefix("zh-Hans"))
        typePinyin("nihao", in: app)
        XCTAssertNotEqual(app.staticTexts["ime.preedit"].label, "<none>")
        XCTAssertEqual(app.staticTexts["ime.received"].label, "<empty>")
        app.buttons["ime.epoch"].tap()
        XCTAssertEqual(app.staticTexts["ime.received"].label, "<empty>")
        app.keyboards.keys["space"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Stale system candidate after generation change"; shot.lifetime = .keepAlways
        add(shot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Stale system candidate hierarchy"; hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertEqual(app.staticTexts["ime.received"].label, "<empty>", "An old candidate must not reach the new video generation")
        XCTAssertEqual(app.staticTexts["ime.preedit"].label, "<none>")
    }
}
