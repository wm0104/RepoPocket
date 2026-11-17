import XCTest

final class CommitFileTests: XCTestCase {
    func testCommitDiffAndCompleteFileOpenInLightAndDarkWithoutCrashing() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-style-preview", "-commit-file-style-preview", "-appearance.mode", appearance]
            app.launch()
            let file = app.staticTexts["目录/历史.swift"]
            XCTAssertTrue(file.waitForExistence(timeout: 20), app.debugDescription)
            file.tap()
            let full = app.buttons["commit-full-file"]
            XCTAssertTrue(full.waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertEqual(app.state, .runningForeground)
            screenshot(app, "commit-diff-" + appearance)
            full.tap()
            let text = app.textViews["代码正文"]
            XCTAssertTrue(text.waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertTrue((text.value as? String ?? "").contains("历史完整内容"))
            XCTAssertEqual(app.state, .runningForeground)
            screenshot(app, "commit-full-file-" + appearance)
            app.terminate()
        }
    }

    func testRenamedFileUsesExactCommitAndReadOnlySurface() {
        let app = launch()
        let text = app.textViews["代码正文"]
        XCTAssertTrue(text.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue((text.value as? String ?? "").contains("不只是差异片段"))
        XCTAssertFalse(app.buttons["编辑"].exists)
        text.tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.buttons["搜索当前文件"].exists)
        screenshot(app, "commit-complete-file-readonly")
        audit(app, fileReads: 1)
        app.buttons["切换账号"].tap()
        XCTAssertTrue(app.staticTexts["账号已切换，请返回重新打开。"].waitForExistence(timeout: 5))
        XCTAssertFalse(text.exists)
    }

    func testRemovedFileDoesNotRequestAnotherVersion() {
        let app = launch(mode: "removed")
        XCTAssertTrue(app.staticTexts["该文件已在此提交中删除，此版本没有完整文件；仍可返回查看删除差异。"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["重试"].exists)
        audit(app, fileReads: 0)
    }

    func testMissingHistoricalFileHasRetryWithoutBranchFallback() {
        let app = launch(mode: "missing")
        let message = app.staticTexts["此提交中的文件不存在或当前账号无权读取；未切换到最新分支。"]
        XCTAssertTrue(message.waitForExistence(timeout: 15))
        audit(app, fileReads: 1)
        app.buttons["重试"].tap()
        XCTAssertTrue(message.waitForExistence(timeout: 15))
        audit(app, fileReads: 2)
    }

    func testEmptyFileIsStillACompleteReadOnlyDocument() {
        let app = launch(mode: "empty")
        let text = app.textViews["代码正文"]
        XCTAssertTrue(text.waitForExistence(timeout: 15))
        XCTAssertEqual(text.value as? String ?? "", "")
        audit(app, fileReads: 1)
    }

    private func launch(mode: String = "renamed") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-commit-file-style-preview", "-commit-file-" + mode]
        app.launch()
        let file = app.staticTexts["目录/历史.swift"]
        XCTAssertTrue(file.waitForExistence(timeout: 20), app.debugDescription)
        file.tap()
        let full = app.buttons["commit-full-file"]
        XCTAssertTrue(full.waitForExistence(timeout: 10), app.debugDescription)
        full.tap()
        return app
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func audit(_ app: XCUIApplication, fileReads: Int) {
        app.buttons["检查请求"].tap()
        XCTAssertEqual(app.staticTexts["commit-file-audit"].label, "fileReads=\(fileReads); rejected=0")
    }
}
