import XCTest

final class SourceFindTests: XCTestCase {
    func testEditableFilaLayoutReplacesAndUndoesWithoutLosingText() {
        continueAfterFailure = false
        let app = launch()
        app.buttons["切换到编辑"].tap()
        let code = app.textViews["代码正文"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        let original = code.value as? String
        XCTAssertNotNil(original)
        app.buttons["查找与替换"].tap()
        let query = app.textFields["查找"], replacement = app.textFields["替换为"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertTrue(replacement.exists)
        XCTAssertGreaterThan(query.frame.width, app.frame.width * 0.4, "The input, not the buttons, must take the available row width")
        XCTAssertGreaterThanOrEqual(replacement.frame.width, query.frame.width)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        query.typeText("TAIL_MARKER")
        app.buttons["下一处"].tap()
        let matches = app.staticTexts["查找结果"]
        let found = expectation(for: NSPredicate(format: "value == %@", "1/1"), evaluatedWith: matches)
        wait(for: [found], timeout: 10)
        replacement.tap(); replacement.typeText("REPLACED_MARKER")
        app.buttons["替换"].tap()
        let replaced = expectation(for: NSPredicate { _, _ in
            let text = code.value as? String ?? ""
            return text.contains("REPLACED_MARKER") && !text.contains("TAIL_MARKER")
        }, evaluatedWith: nil)
        wait(for: [replaced], timeout: 10)
        let undo = app.buttons["撤销"].firstMatch
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        let restored = expectation(for: NSPredicate { _, _ in (code.value as? String) == original }, evaluatedWith: nil)
        wait(for: [restored], timeout: 10)
        screenshot(app, "source-fila-find-replace")
        app.buttons["关闭查找"].tap()
        XCTAssertFalse(query.exists)
        XCTAssertEqual(code.value as? String, original)
    }

    func testReadOnlyFindHasNoReplacementOrUndoAndDoesNotEdit() {
        continueAfterFailure = false
        let app = launch(), code = app.textViews["代码正文"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        let original = code.value as? String
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["搜索当前文件"].tap()
        let query = app.textFields["查找"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(query.frame.width, app.frame.width * 0.5)
        XCTAssertFalse(app.textFields["替换为"].exists)
        XCTAssertFalse(app.buttons["替换"].exists)
        XCTAssertFalse(app.buttons["替换全部"].exists)
        XCTAssertFalse(app.buttons["撤销"].exists)
        query.typeText("TAIL_MARKER"); app.buttons["下一处"].tap()
        XCTAssertEqual(code.value as? String, original)
        app.buttons["关闭查找"].tap()
        XCTAssertFalse(query.exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(code.value as? String, original)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-source-style-preview"]
        app.launch(); return app
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
