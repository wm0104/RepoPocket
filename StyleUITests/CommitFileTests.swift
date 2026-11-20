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

    func testLargeHistoricalFileUsesPinnedBlobAndStaysReadOnly() {
        let app = launch(mode: "large")
        let notice = app.staticTexts["仅显示文件开头（最多 1 MiB），不可编辑。"]
        XCTAssertTrue(notice.waitForExistence(timeout: 20), app.debugDescription)
        let text = app.textViews["代码正文"]
        XCTAssertTrue(text.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue((text.value as? String ?? "").contains("历史超大文件开头"))
        XCTAssertFalse(app.buttons["编辑"].exists)
        audit(app, fileReads: 1, blobReads: 1)
    }

    func testRenamedMediaSwitchesSidesWithoutACompareRequestAndKeepsSourcePatch() {
        let app = openPatch(mode: "media-renamed")
        let version = app.staticTexts["commit-media-version"]
        XCTAssertTrue(version.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(version.label, "目录/历史.png · abc1234")
        let afterImage = app.images["历史.png"]
        let beforeImage = app.images["old.png"]
        XCTAssertTrue(afterImage.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["commit-full-file"].exists)
        audit(app, fileReads: 1)
        let picker = app.segmentedControls["commit-media-side-picker"]
        picker.buttons["修改前"].tap()
        XCTAssertTrue(beforeImage.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(afterImage.exists)
        XCTAssertEqual(version.label, "旧目录/old.png · bbbbbbb")
        audit(app, fileReads: 2, beforeReads: 1)
        screenshot(app, "commit-media-before")
        picker.buttons["修改后"].tap()
        XCTAssertTrue(afterImage.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(beforeImage.exists)
        audit(app, fileReads: 3, beforeReads: 1)
        app.buttons["commit-media-source-patch"].tap()
        XCTAssertTrue(app.staticTexts["仅显示本次提交的变化"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["commit-full-file"].exists)
    }

    func testMergeUsesFirstParentComparisonToProveTheOldPath() {
        let app = openPatch(mode: "media-merge")
        let base = "第一父比较基准：" + String(repeating: "b", count: 40)
        XCTAssertTrue(app.staticTexts[base].waitForExistence(timeout: 10), app.debugDescription)
        let picker = app.segmentedControls["commit-media-side-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15), app.debugDescription)
        audit(app, fileReads: 1, compareReads: 1)
        picker.buttons["修改前"].tap()
        XCTAssertTrue(app.images["base.png"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["commit-media-version"].label, "第一父/base.png · bbbbbbb")
        audit(app, fileReads: 2, beforeReads: 1, compareReads: 1)
        app.buttons["切换账号"].tap()
        XCTAssertTrue(app.staticTexts["账号已切换，请返回重新打开。"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["commit-media-version"].exists)
        XCTAssertFalse(picker.exists)
    }

    func testMediaWithoutAnotherProvenVersionOnlyExposesTheKnownSide() {
        for (mode, side, path, beforeReads, compareReads) in [
            ("media-added", "after", "目录/历史.png · abc1234", 0, 0),
            ("media-removed", "before", "目录/历史.png · bbbbbbb", 1, 0),
            ("media-merge-unproven", "after", "目录/历史.png · abc1234", 0, 1)
        ] {
            let app = openPatch(mode: mode)
            XCTAssertTrue(app.staticTexts["commit-media-\(side)-only"].waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertFalse(app.segmentedControls["commit-media-side-picker"].exists)
            XCTAssertEqual(app.staticTexts["commit-media-version"].label, path)
            if compareReads > 0 {
                XCTAssertTrue(app.staticTexts["无法验证修改前版本的提交或路径，未读取其他版本。"].exists)
            }
            audit(app, fileReads: 1, beforeReads: beforeReads, compareReads: compareReads)
            app.terminate()
        }
    }

    private func launch(mode: String = "renamed") -> XCUIApplication {
        let app = openPatch(mode: mode)
        let full = app.buttons["commit-full-file"]
        XCTAssertTrue(full.waitForExistence(timeout: 10), app.debugDescription)
        full.tap()
        return app
    }

    private func openPatch(mode: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-commit-file-style-preview", "-commit-file-" + mode]
        app.launch()
        let file = app.staticTexts[mode.hasPrefix("media-") ? "目录/历史.png" : "目录/历史.swift"]
        XCTAssertTrue(file.waitForExistence(timeout: 20), app.debugDescription)
        file.tap()
        return app
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func audit(_ app: XCUIApplication, fileReads: Int, beforeReads: Int = 0, blobReads: Int = 0, compareReads: Int = 0) {
        let expected = "fileReads=\(fileReads); beforeReads=\(beforeReads); blobReads=\(blobReads); compareReads=\(compareReads); rejected=0"
        let deadline = Date().addingTimeInterval(5)
        let value = app.staticTexts["commit-file-audit"]
        repeat {
            app.buttons["检查请求"].tap()
            if value.label == expected { return }
        } while Date() < deadline
        XCTAssertEqual(value.label, expected)
    }
}
