import XCTest

final class RepositoryOperationsTests: XCTestCase {
    func testActionsManualRefreshRetainsFailuresAndAutomaticallyFollowsTheSameRun() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-workflow-selection-style-preview", "-workflow-refresh-preview"]
        app.launch()
        let run = app.buttons["workflow-run-3"]
        XCTAssertTrue(run.waitForExistence(timeout: 15))
        waitForLabel(run, containing: "等待运行")
        // Selection pauses automatic polling, so the next read is the real manual refresh.
        XCTAssertTrue(app.buttons["多选"].waitForExistence(timeout: 10)); waitForEnabled(app.buttons["多选"]); app.buttons["多选"].tap()
        app.buttons["模拟运行中"].tap(); app.buttons["workflow-refresh"].tap()
        waitForLabel(run, containing: "运行中")
        let done = app.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 10)); waitForEnabled(done); done.tap()
        XCTAssertTrue(app.buttons["多选"].waitForExistence(timeout: 10))
        app.buttons["模拟刷新失败"].tap(); app.buttons["workflow-refresh"].tap()
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "模拟刷新失败")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(run.label.contains("运行中"), "Refresh failure must not clear the previously loaded run")
        app.buttons["模拟完成"].tap()
        waitForLabel(run, containing: "成功", timeout: 25)
        XCTAssertFalse(error.exists)
        screenshot(app, "workflow-refresh-preserves-and-updates")
    }
    func testVersionGroupsPreviewTheirFinalSnapshotsWithoutWriting() {
        let app = launch()
        app.buttons["fixture-open-history"].tap()
        let base = app.buttons["history-cleanup-" + String(repeating: "a", count: 40)]
        XCTAssertTrue(base.waitForExistence(timeout: 15))
        app.buttons["历史整理操作"].tap()
        app.buttons["整理方式"].tap()
        app.buttons["按版本整理"].tap()
        reveal(base, app: app); base.tap()
        let add = app.buttons["history-version-add"]
        reveal(add, app: app, upward: false); add.tap()
        fill(app.textFields.matching(NSPredicate(format: "label == %@", "第1版版本号")).firstMatch, with: "6.0", app: app, upward: false)
        fill(app.textViews.matching(NSPredicate(format: "label == %@", "第1版更新要点")).firstMatch, with: "- Keep the final feature", app: app)
        reveal(add, app: app); add.tap()
        fill(app.textFields.matching(NSPredicate(format: "label == %@", "第2版版本号")).firstMatch, with: "6.1", app: app, upward: false)
        fill(app.textViews.matching(NSPredicate(format: "label == %@", "第2版更新要点")).firstMatch, with: "- Fix the final issue", app: app)
        let select = app.buttons.matching(NSPredicate(format: "label == %@", "第1版选择最终快照")).firstMatch
        reveal(select, app: app, upward: false); select.tap()
        let first = app.buttons["history-cleanup-" + String(repeating: "b", count: 40)]
        reveal(first, app: app); first.tap()
        let preview = app.buttons["history-version-preview"]
        reveal(preview, app: app); preview.tap()
        let heading = app.staticTexts["按版本整理预览"]
        reveal(heading, app: app)
        XCTAssertTrue(heading.exists)
        for note in ["- Keep the final feature", "- Fix the final issue"] {
            let text = app.staticTexts[note]; reveal(text, app: app); XCTAssertTrue(text.exists)
        }
        screenshot(app, "remote-version-history-preview")
        let confirm = app.buttons["history-cleanup-confirm"]
        reveal(confirm, app: app); confirm.tap()
        XCTAssertTrue(app.buttons["确认整理"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertEqual(app.staticTexts["fixture-repository-writes"].label, "写入请求：0")
    }

    func testThreePullRequestMergeMethodsFreezeTheSelectedPreviewAndCanCancel() {
        let app = launch()
        app.buttons["fixture-open-pr-merge"].tap()
        let method = app.buttons["pr-merge-method"]
        XCTAssertTrue(method.waitForExistence(timeout: 15))
        for title in ["普通合并", "压缩合并", "Rebase 合并"] {
            method.tap(); app.buttons["合并方式"].tap()
            for allowed in ["普通合并", "压缩合并", "Rebase 合并"] { XCTAssertTrue(app.buttons[allowed].isEnabled) }
            if title == "压缩合并" { screenshot(app, "pr-three-merge-methods-native-menu") }
            app.buttons[title].tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", title), object: method)], timeout: 5), .completed)
            if title == "Rebase 合并" { XCTAssertFalse(app.textFields["提交标题（留空使用GitHub默认）"].exists) }
            app.buttons["pr-merge-preview"].tap()
            XCTAssertTrue(app.buttons["确认" + title].waitForExistence(timeout: 5))
            app.buttons["取消"].tap()
            XCTAssertEqual(app.staticTexts["fixture-repository-writes"].label, "写入请求：0")
        }
    }

    func testBlockedPullRequestExplainsTheGateAndDoesNotOfferAMerge() {
        let app = launch(["-pr-merge-blocked-preview"])
        app.buttons["fixture-open-pr-merge"].tap()
        let preview = app.buttons["pr-merge-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        XCTAssertFalse(preview.isEnabled)
        let reason = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "GitHub尚未允许合并（BLOCKED）")).firstMatch
        reveal(reason, app: app); XCTAssertTrue(reason.exists)
        screenshot(app, "pr-merge-blocked-reason")
        XCTAssertEqual(app.staticTexts["fixture-repository-writes"].label, "写入请求：0")
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-repository-operations-style-preview"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["fixture-open-history"].waitForExistence(timeout: 15))
        return app
    }
    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 10) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)], timeout: timeout), .completed)
    }
    private func waitForEnabled(_ element: XCUIElement) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)], timeout: 10), .completed)
    }
    private func fill(_ field: XCUIElement, with value: String, app: XCUIApplication, upward: Bool = true) {
        reveal(field, app: app, upward: upward); field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText(value)
        app.buttons["完成输入"].tap()
        XCTAssertEqual(field.value as? String, value)
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<10 where !element.isHittable {
            if upward { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.exists); XCTAssertTrue(element.isHittable)
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
