import XCTest

final class PickerUITests: XCTestCase {
    func testTapPreviewImmediatelyChoosesOneScreen() {
        let app = XCUIApplication()
        app.launch()
        let main = app.buttons["display-5"]
        XCTAssertTrue(main.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["开始串流"].exists)
        XCTAssertFalse(app.buttons["切换显示器"].exists)
        main.tap()
        XCTAssertTrue(app.staticTexts["Selected: 5"].waitForExistence(timeout: 5))
        app.buttons["显示器"].tap()
        let side = app.buttons["display-3"]
        XCTAssertTrue(side.waitForExistence(timeout: 5))
        side.tap()
        XCTAssertTrue(app.staticTexts["Selected: 3"].waitForExistence(timeout: 5))
        app.buttons["显示器"].tap()
        XCTAssertTrue(app.buttons["display-3"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["Selected: 3"].waitForExistence(timeout: 5))
    }
}
