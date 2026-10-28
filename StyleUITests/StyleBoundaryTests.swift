import XCTest
import UIKit

final class StyleBoundaryTests: XCTestCase {
    func testSettingsSocialAccountsAddEditDeleteAndPermissionRecovery() {
        continueAfterFailure = false
        let app = XCUIApplication()
        func openAccounts(_ flags: [String] = []) {
            app.launchArguments = ["-style-preview", "-user-connections-style-preview", "-social-account-settings-preview"] + flags
            app.launch()
            let entry = app.buttons["settings-social-accounts"]
            XCTAssertTrue(entry.waitForExistence(timeout: 20)); entry.tap()
            XCTAssertTrue(app.buttons["social-account-https://t.me/fixture_owner"].waitForExistence(timeout: 15))
        }
        func fill(_ text: String) {
            let field = app.textFields["social-account-url"]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            reveal(field, in: app); field.tap()
            if let value = field.value as? String, value.hasPrefix("https://") {
                field.press(forDuration: 1)
                let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label IN {'Select All', '全选'}")).firstMatch
                XCTAssertTrue(selectAll.waitForExistence(timeout: 5)); selectAll.tap()
                field.typeText(XCUIKeyboardKey.delete.rawValue)
            }
            field.typeText(text + "\n")
            XCTAssertEqual(field.value as? String, text)
            let save = app.buttons["social-account-save"]
            reveal(save, in: app); save.tap()
        }
        openAccounts()
        let original = app.buttons["social-account-https://t.me/fixture_owner"]
        XCTAssertFalse(app.textFields["social-account-url"].exists, "Keep the main list compact until adding or editing")
        app.buttons["social-account-add"].tap()
        XCTAssertTrue(app.textFields["social-account-url"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["social-account-url"].placeholderValue, "社交账号或网站链接")
        fill("https://example.invalid/new")
        let added = app.buttons["social-account-https://example.invalid/new"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.textFields["social-account-url"])], timeout: 15), .completed)
        XCTAssertTrue(added.waitForExistence(timeout: 15)); XCTAssertTrue(original.exists)
        reveal(added, in: app); added.tap(); fill("https://example.invalid/edited")
        let edited = app.buttons["social-account-https://example.invalid/edited"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.textFields["social-account-url"])], timeout: 15), .completed)
        XCTAssertTrue(edited.waitForExistence(timeout: 15)); XCTAssertFalse(added.exists)
        reveal(edited, in: app); edited.press(forDuration: 1)
        let remove = app.buttons["social-account-context-delete"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        keepScreenshot(app, name: "social-accounts-long-press")
        remove.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == '删除' AND identifier != 'social-account-context-delete'")).firstMatch
        guard confirm.waitForExistence(timeout: 10) else {
            XCTFail("Show the native social-account deletion confirmation: " + app.debugDescription); return
        }
        let cancelDeletion = app.buttons.matching(NSPredicate(format: "label == '取消' AND identifier != 'social-account-cancel'")).firstMatch
        guard cancelDeletion.waitForExistence(timeout: 5) else {
            XCTFail("The deletion confirmation needs its own cancel button: " + app.debugDescription); return
        }
        cancelDeletion.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: confirm)], timeout: 5), .completed)
        XCTAssertTrue(edited.exists, "Cancelling must keep the selected social account")
        XCTAssertTrue(original.exists)
        XCTAssertFalse(app.textFields["social-account-url"].exists, "Long press must not open the editor")
        reveal(edited, in: app); edited.press(forDuration: 1)
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap()
        guard confirm.waitForExistence(timeout: 10) else {
            XCTFail("Show the deletion confirmation again after cancelling: " + app.debugDescription); return
        }
        confirm.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: edited)], timeout: 15), .completed)
        XCTAssertTrue(original.exists)
        keepScreenshot(app, name: "social-accounts-managed")
        app.terminate(); openAccounts(["-social-accounts-denied"])
        app.buttons["social-account-add"].tap()
        fill("https://example.invalid/denied")
        let error = app.staticTexts["social-account-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertEqual(app.textFields["social-account-url"].value as? String, "https://example.invalid/denied")
        XCTAssertFalse(app.buttons["social-account-https://example.invalid/denied"].exists)
        let authorize = app.buttons["social-account-authorize-editor"]
        guard authorize.waitForExistence(timeout: 10) else {
            XCTFail("The editor must offer authorization after a permission error: " + app.debugDescription); return
        }
        for _ in 0..<6 {
            if authorize.isHittable { break }
            app.swipeUp()
        }
        guard authorize.isHittable else {
            XCTFail("The editor authorization link must be tappable: " + app.debugDescription); return
        }
        authorize.tap()
        let permission = app.switches["oauth-write-profile"]
        XCTAssertTrue(permission.waitForExistence(timeout: 10)); XCTAssertEqual(permission.value as? String, "1")
        keepScreenshot(app, name: "social-accounts-permission")
    }

    func testProfileContactsOpenWebFallbackAndRetryWithoutLosingProfile() {
        continueAfterFailure = false
        let app = XCUIApplication()
        func openAuthor(_ flags: [String] = []) {
            app.launchArguments = ["-style-preview", "-user-connections-style-preview", "-profile-contacts-preview"] + flags
            app.launch()
            let issue = app.buttons["home-issue-4"]
            XCTAssertTrue(issue.waitForExistence(timeout: 20)); issue.tap()
            let author = app.buttons["issue-author"]
            XCTAssertTrue(author.waitForExistence(timeout: 15)); author.tap()
            XCTAssertTrue(app.navigationBars["fixture-follower"].waitForExistence(timeout: 10))
        }
        func tapContact(_ element: XCUIElement) {
            guard element.waitForExistence(timeout: 15) else {
                XCTFail("The profile contact must remain available: " + app.debugDescription); return
            }
            for _ in 0..<12 {
                if element.isHittable { element.tap(); return }
                // Small, reversible drags cannot skip a row and keep scrolling away from it.
                let direction: CGFloat = !element.frame.isEmpty && element.frame.midY < app.frame.midY ? 1 : -1
                let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: direction * 130)))
            }
            XCTFail("The profile contact must be tappable: " + app.debugDescription)
        }
        openAuthor()
        let contact = app.buttons["profile-social-https://mastodon.example.invalid/@author"]
        XCTAssertTrue(contact.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["profile-website"].exists)
        XCTAssertTrue(app.buttons["profile-social-https://bsky.app/profile/author.example.invalid"].exists)
        XCTAssertTrue(app.buttons["profile-social-https://threads.net/fixture-author"].exists)
        XCTAssertFalse(app.buttons["profile-github"].exists, "The native author profile must not repeat an external GitHub profile entry")
        XCTAssertEqual(contact.value as? String, "https://mastodon.example.invalid/@author")
        keepScreenshot(app, name: "profile-public-contacts")
        tapContact(contact)
        let done = app.buttons.matching(NSPredicate(format: "label IN {'Done', '完成'}")).firstMatch
        guard done.waitForExistence(timeout: 10) else {
            XCTFail("Without an associated app, keep the author page inside Safari: " + app.debugDescription); return
        }
        XCTAssertFalse(app.buttons["reading-link-close"].exists, "Use Safari's existing Done button without a second close bar")
        done.tap()
        let safariClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: done)
        if XCTWaiter.wait(for: [safariClosed], timeout: 3) != .completed {
            // Remote Safari controls can ignore Simulator taps; also exercise native sheet dismissal.
            let browser = app.descendants(matching: .other).matching(NSPredicate(format: "identifier BEGINSWITH 'BrowserView?'")).firstMatch
            let frame = app.frame
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let top = browser.exists ? browser.frame.minY + 4 : frame.minY + 75
            origin.withOffset(CGVector(dx: frame.midX, dy: top)).press(forDuration: 0.1,
                thenDragTo: origin.withOffset(CGVector(dx: frame.midX, dy: frame.maxY - 90)))
        }
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: done)
        guard XCTWaiter.wait(for: [closed], timeout: 10) == .completed else {
            XCTFail("Closing the web page must dismiss its presentation: " + app.debugDescription); return
        }
        XCTAssertTrue(contact.waitForExistence(timeout: 10))
        let unsupported = app.buttons["profile-social-fixtureapp://author"]
        tapContact(unsupported)
        let alert = app.alerts["无法打开此链接"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["复制链接"].exists)
        alert.buttons["取消"].tap()
        app.terminate(); openAuthor(["-profile-contacts-error"])
        let retry = app.buttons["重试联系方式"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["user-follow-action"].exists)
        XCTAssertTrue(app.buttons["profile-website"].exists)
        reveal(retry, in: app); keepScreenshot(app, name: "profile-contacts-retry")
        retry.tap()
        XCTAssertTrue(contact.waitForExistence(timeout: 15))
        XCTAssertFalse(retry.exists)
    }

    func testWorkflowFiltersAndSelectionKeepGroupedRows() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-workflow-selection-style-preview"]; app.launch()
        XCTAssertTrue(app.buttons["workflow-run-1"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.switches["仅当前分支"].exists)
        XCTAssertTrue(app.switches["仅看失败记录"].exists)
        keepScreenshot(app, name: "workflow-runs-normal")
        app.switches["仅当前分支"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["仅当前分支"].value as? String, "1")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["workflow-run-4"])], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["workflow-run-1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["workflow-run-4"].exists)
        app.switches["仅看失败记录"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["workflow-run-3"])], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["workflow-run-2"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["workflow-run-3"].exists)
        let multiple = app.buttons["多选"]
        XCTAssertTrue(multiple.waitForExistence(timeout: 10)); multiple.tap()
        app.buttons["workflow-run-1"].tap()
        XCTAssertEqual(app.buttons["workflow-run-1"].value as? String, "已选中")
        XCTAssertTrue(app.buttons["删除（1）"].isEnabled)
        keepScreenshot(app, name: "workflow-runs-selection")
        app.buttons["全选已加载"].tap()
        XCTAssertTrue(app.buttons["删除（2）"].isEnabled)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["多选"].exists)
    }
    func testWorkflowBatchDeleteKeepsOtherRowsAndRetriesFailures() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-workflow-selection-style-preview"]; app.launch()
        let multiple = app.buttons["多选"]
        XCTAssertTrue(multiple.waitForExistence(timeout: 20)); multiple.tap()
        let first = app.buttons["workflow-run-1"], second = app.buttons["workflow-run-2"]
        XCTAssertTrue(first.waitForExistence(timeout: 10)); first.tap(); second.tap()
        let running = app.buttons["workflow-run-3"]
        reveal(running, in: app)
        XCTAssertFalse(running.isEnabled, "An unfinished run cannot be selected for deletion")
        app.buttons["删除（2）"].tap()
        let confirm = app.buttons["永久删除 2 条运行"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'fixture-owner/sample' AND label CONTAINS '2'")).firstMatch.exists)
        app.buttons["取消"].tap()
        XCTAssertTrue(first.exists, "Cancelling must keep every selected run")
        app.buttons["删除（2）"].tap(); confirm.tap()
        let result = app.staticTexts["workflow-selection-result"]
        reveal(result, in: app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '已删除 1 条，失败 1 条。'"), object: result)], timeout: 15), .completed)
        XCTAssertFalse(first.exists); XCTAssertTrue(second.exists)
        XCTAssertTrue(app.buttons["workflow-run-3"].exists)
        XCTAssertTrue(app.buttons["workflow-run-4"].exists)
        XCTAssertTrue(app.buttons["删除（1）"].isEnabled)
        keepScreenshot(app, name: "workflow-runs-partial-failure")
        app.buttons["删除（1）"].tap()
        let retry = app.buttons["永久删除 1 条运行"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5)); retry.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: second)], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["workflow-run-3"].exists)
        XCTAssertTrue(app.buttons["workflow-run-4"].exists)
    }
    func testRepositoryZIPCompletionIsNativeDismissibleAndReusable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-download-completion-style-preview"]; app.launch()
        let completed = app.buttons["模拟 ZIP 保存完成"]
        XCTAssertTrue(completed.waitForExistence(timeout: 20))
        for attempt in 0..<2 {
            completed.tap()
            let alert = app.alerts["下载完成"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'my-python.zip' AND label CONTAINS 'RepoPocket'")).firstMatch.exists)
            XCTAssertFalse(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS '/private/'")).firstMatch.exists)
            if attempt == 0 { keepScreenshot(app, name: "repository-zip-completion") }
            alert.buttons["好"].tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: alert)], timeout: 5), .completed)
        }
    }
    func testProjectFilesUseLongPressDeletionAndKeepPreview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-local-git-style-preview"]; app.launch()
        let browse = app.buttons["浏览与编辑项目文件"]
        XCTAssertTrue(browse.waitForExistence(timeout: 40)); reveal(browse, in: app); browse.tap()
        let file = app.buttons["local-project-file-示例.py"]
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["更多操作：示例.py"].exists)
        file.tap()
        XCTAssertTrue(app.textViews["代码正文"].waitForExistence(timeout: 15))
        app.buttons["关闭"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.press(forDuration: 1)
        let remove = app.buttons["删除此文件"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap()
        XCTAssertTrue(app.buttons["确认删除此文件"].waitForExistence(timeout: 15))
        keepScreenshot(app, name: "local-project-files-long-press")
        app.buttons["关闭"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10), "Cancelling must keep the project file")
        app.buttons["debs"].tap()
        let deb = app.buttons["local-project-file-debs/package-01.deb"]
        XCTAssertTrue(deb.waitForExistence(timeout: 10)); deb.tap()
        XCTAssertTrue(app.textFields["Version"].waitForExistence(timeout: 15), "Tapping DEB still opens the established editor")
    }
    func testLocalFileSheetStaysClosedAfterInteractiveDismissal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-local-git-style-preview"]; app.launch()
        let browse = app.buttons["浏览与编辑项目文件"]
        XCTAssertTrue(browse.waitForExistence(timeout: 40)); reveal(browse, in: app); browse.tap()
        let file = app.buttons["local-project-file-示例.py"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            file.tap(withNumberOfTaps: 2, numberOfTouches: 1)
            let editor = app.navigationBars["示例.py"]
            XCTAssertTrue(app.textViews["代码正文"].waitForExistence(timeout: 10))
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: editor)], timeout: 10), .completed)
            let reappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: editor)
            reappeared.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [reappeared], timeout: 1), .completed)
            XCTAssertTrue(file.isEnabled)
        }
        keepScreenshot(app, name: "local-file-sheet-dismissed")
    }
    func testReleaseAttachmentsUseNativeActionsAndInlineDownloadStates() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-release-download-style-preview", "-release-download-failure"]; app.launch()
        let file = app.buttons["release-asset-1"]
        XCTAssertTrue(file.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["release-asset-3"].exists)
        XCTAssertFalse(app.buttons["下载并保存"].exists)
        keepScreenshot(app, name: "release-compact-attachments")
        file.tap()
        XCTAssertTrue(app.buttons["下载并保存"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["复制下载链接"].exists)
        XCTAssertTrue(app.buttons["删除附件"].exists)
        // Dismiss the menu, then reopen by tapping its empty trailing area, not the filename.
        // A native menu deliberately makes the navigation bar non-hittable to AX.
        // Tap its background coordinate as a user would to dismiss the menu.
        app.navigationBars["发行版详情"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["下载并保存"])], timeout: 5), .completed)
        file.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.7)).tap()
        XCTAssertTrue(app.buttons["删除附件"].waitForExistence(timeout: 5)); app.buttons["删除附件"].tap()
        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 5)); app.buttons["取消"].tap()
        // Copy alert and delete cancellation must not lock the next presentation.
        file.tap(); app.buttons["复制下载链接"].tap()
        XCTAssertTrue(app.buttons["好"].waitForExistence(timeout: 5)); app.buttons["好"].tap()
        let third = app.buttons["release-asset-3"]
        third.tap(); app.buttons["删除附件"].tap()
        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 5)); app.buttons["删除"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: third)], timeout: 10), .completed)
        file.tap(); app.buttons["下载并保存"].tap()
        let retry = app.buttons["release-download-retry-1"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        let status = app.staticTexts["release-download-status-1"]
        XCTAssertTrue(status.label.contains("下载失败"))
        retry.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '40%'"), object: status)], timeout: 10), .completed)
        keepScreenshot(app, name: "release-inline-progress")
        app.buttons["取消下载"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '下载已取消'"), object: status)], timeout: 5), .completed)
        retry.tap()
        let completion = app.alerts["下载完成"]
        XCTAssertTrue(completion.waitForExistence(timeout: 15))
        completion.buttons["好"].tap()
        XCTAssertFalse(status.exists, "Success must not leave a permanent saved-path row")
    }
    func testSharedProfileFollowStateAndFailureHandling() {
        continueAfterFailure = false
        let app = XCUIApplication()
        func openAuthor(_ flags: [String] = []) {
            app.launchArguments = ["-style-preview", "-user-connections-style-preview"] + flags; app.launch()
            let issue = app.buttons["home-issue-4"]
            XCTAssertTrue(issue.waitForExistence(timeout: 20)); issue.tap()
            let author = app.buttons["issue-author"]
            XCTAssertTrue(author.waitForExistence(timeout: 15)); author.tap()
            XCTAssertTrue(app.navigationBars["fixture-follower"].waitForExistence(timeout: 10))
        }
        openAuthor()
        let action = app.buttons["user-follow-action"]
        XCTAssertTrue(action.waitForExistence(timeout: 10)); XCTAssertEqual(action.label, "关注")
        action.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '取消关注' AND enabled == true"), object: action)], timeout: 10), .completed)
        keepScreenshot(app, name: "profile-following-action")
        app.navigationBars.buttons["Issue #4"].tap()
        app.buttons["讨论评论"].tap()
        let commenter = app.buttons["discussion-author-71"]
        XCTAssertTrue(commenter.waitForExistence(timeout: 10)); commenter.tap()
        XCTAssertTrue(action.waitForExistence(timeout: 10)); XCTAssertEqual(action.label, "取消关注")
        action.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '关注' AND enabled == true"), object: action)], timeout: 10), .completed)
        app.navigationBars.buttons["讨论"].tap()
        app.buttons["discussion-author-72"].tap()
        XCTAssertTrue(action.waitForExistence(timeout: 10)); XCTAssertEqual(action.label, "取消关注", "An existing relationship must load from the server")
        app.terminate(); openAuthor(["-follow-status-error"])
        XCTAssertTrue(app.staticTexts["user-follow-error"].waitForExistence(timeout: 10))
        XCTAssertFalse(action.exists, "Failed relationship reads must never guess an unfollowed state")
        keepScreenshot(app, name: "profile-follow-status-error")
        app.terminate(); openAuthor(["-follow-write-denied"])
        XCTAssertTrue(action.waitForExistence(timeout: 10)); action.tap()
        XCTAssertTrue(app.staticTexts["user-follow-error"].waitForExistence(timeout: 10))
        XCTAssertEqual(action.label, "关注", "Rejected writes must not change the relationship")
    }
    func testDirectRepositorySearchAndTypedUserNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-user-connections-style-preview", "-search-style-preview"]; app.launch()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20)); field.tap(); field.typeText("https://github.com/fixture-owner/sample\n")
        let owner = app.buttons["repository-owner-link"]
        XCTAssertTrue(owner.waitForExistence(timeout: 20)); owner.tap()
        XCTAssertTrue(app.navigationBars["fixture-owner"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["user-follow-action"].exists, "Self profiles have no follow action")
        keepScreenshot(app, name: "repository-owner-profile")
        app.terminate(); app.launch()
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("sample\n")
        let resultOwner = app.buttons["repository-owner-link"].firstMatch
        XCTAssertTrue(resultOwner.waitForExistence(timeout: 15)); resultOwner.tap()
        XCTAssertTrue(app.navigationBars["fixture-owner"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["关闭"].exists, "Card owner must open the profile sheet, not the repository")
        app.buttons["关闭"].tap()
        app.terminate(); app.launch()
        app.segmentedControls.buttons["用户"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("fixture-follower\n")
        let person = app.buttons["search-user-fixture-follower"]
        XCTAssertTrue(person.waitForExistence(timeout: 15)); person.tap()
        XCTAssertTrue(app.navigationBars["fixture-follower"].waitForExistence(timeout: 10))
    }
    func testIssueAndCommentAuthorsOpenTheirProfiles() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-user-connections-style-preview"]; app.launch()
        let issue = app.buttons["home-issue-4"]
        XCTAssertTrue(issue.waitForExistence(timeout: 20)); issue.tap()
        let author = app.buttons["issue-author"]
        XCTAssertTrue(author.waitForExistence(timeout: 15)); author.tap()
        XCTAssertTrue(app.navigationBars["fixture-follower"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Issue #4"].tap()
        XCTAssertTrue(app.staticTexts["Issue fixture body"].waitForExistence(timeout: 15))
        app.buttons["讨论评论"].tap()
        let commenter = app.buttons["discussion-author-72"]
        XCTAssertTrue(commenter.waitForExistence(timeout: 15)); commenter.tap()
        XCTAssertTrue(app.navigationBars["fixture-second"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments.append("-issue-deletion-repository-preview"); app.launch()
        let listAuthor = app.buttons["issue-list-author-4"]
        XCTAssertTrue(listAuthor.waitForExistence(timeout: 20)); listAuthor.tap()
        XCTAssertTrue(app.navigationBars["fixture-follower"].waitForExistence(timeout: 10))
        keepScreenshot(app, name: "profile-issue-list")
        app.navigationBars["fixture-follower"].buttons["关闭"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["fixture-follower"])], timeout: 10), .completed)
        app.buttons["repository-issue-4"].tap()
        XCTAssertTrue(app.navigationBars["Issue #4"].waitForExistence(timeout: 10))
        for (argument, identity, destination) in [
            ("-fork-author-preview", "fork-author-505", "fork-repository-505"),
            ("-event-author-preview", "event-author-1-0", "event-repository-1-0")
        ] {
            app.terminate()
            app.launchArguments = ["-style-preview", "-user-connections-style-preview", argument]; app.launch()
            let author = app.buttons[identity]
            XCTAssertTrue(author.waitForExistence(timeout: 20)); author.tap()
            XCTAssertTrue(app.navigationBars["fixture-follower"].waitForExistence(timeout: 10))
            keepScreenshot(app, name: argument == "-fork-author-preview" ? "profile-fork" : "profile-activity")
            app.navigationBars["fixture-follower"].buttons["关闭"].tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["fixture-follower"])], timeout: 10), .completed)
            app.buttons[destination].firstMatch.tap()
            keepScreenshot(app, name: argument == "-fork-author-preview" ? "profile-fork-repository" : "profile-activity-repository")
            if argument == "-fork-author-preview" {
                XCTAssertTrue(app.buttons["浏览复刻仓库"].waitForExistence(timeout: 10))
            } else {
                XCTAssertTrue(app.buttons["repository-owner-link"].waitForExistence(timeout: 10))
            }
        }
    }
    func testIssueDeletionRequiresConfirmationOnHomeAndRepositoryList() {
        continueAfterFailure = false
        for (extra, identifier, empty) in [
            ("", "home-issue-4", "暂无相关议题"),
            ("-issue-deletion-repository-preview", "repository-issue-4", "当前页没有符合条件的 Issue。"),
            ("personal", "personal-issue-4", "没有符合条件的议题")
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["-style-preview", "-user-connections-style-preview"] + (extra.hasPrefix("-") ? [extra] : [])
            app.launch()
            if extra == "personal" {
                let all = app.buttons["home-personal-issues"]
                XCTAssertTrue(all.waitForExistence(timeout: 20)); all.tap()
            }
            let issue = app.buttons[identifier]
            XCTAssertTrue(issue.waitForExistence(timeout: 20))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == '可删除议题'"), object: issue)], timeout: 15), .completed)
            issue.press(forDuration: 1.2)
            let menu = app.buttons["删除议题"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
            XCTAssertTrue(app.buttons["永久删除议题"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'fixture-owner/sample #4'")).firstMatch.exists)
            keepScreenshot(app, name: "issue-delete-confirmation-" + identifier)
            app.buttons["取消"].tap()
            XCTAssertTrue(issue.exists, "Cancelling must leave the issue in the list")
            issue.press(forDuration: 1.2); app.buttons["删除议题"].tap()
            app.buttons["永久删除议题"].tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: issue)], timeout: 15), .completed)
            // Confirm the server-backed fixture also stays deleted after refresh.
            if !extra.isEmpty {
                app.buttons["刷新"].tap()
                XCTAssertTrue(app.staticTexts[empty].waitForExistence(timeout: 15))
            } else { XCTAssertTrue(app.staticTexts[empty].waitForExistence(timeout: 15)) }
            app.terminate()
        }
    }
    func testHomeCollectionsAndPeopleUseSearchDestinations() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-user-connections-style-preview"]; app.launch()
        for (entry, title, empty) in [
            ("home-collection-owned", "我的仓库", "没有匹配仓库"),
            ("home-collection-starred", "已加星标", "没有匹配仓库"),
            ("account-connections-followers", "关注者", "没有匹配用户"),
            ("account-connections-following", "正在关注", "没有匹配用户")
        ] {
            let link = app.buttons[entry]
            XCTAssertTrue(link.waitForExistence(timeout: 20)); link.tap()
            let search = app.buttons["list-search-button"]
            XCTAssertTrue(search.waitForExistence(timeout: 15)); search.tap()
            let field = app.textFields["list-search-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("no-such-person-or-repo")
            XCTAssertTrue(app.staticTexts[empty].waitForExistence(timeout: 10))
            search.tap()
            XCTAssertFalse(app.textFields["list-search-field"].exists)
            if title == "我的仓库" { keepScreenshot(app, name: "home-owned-destination") }
            app.navigationBars.buttons["RepoPocket"].tap()
        }
        keepScreenshot(app, name: "home-grouped-navigation")
    }
    func testIssueReplyCarriesRecipientQuoteAndConfirmedText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-user-connections-style-preview"]; app.launch()
        let issue = app.buttons["home-issue-4"]
        XCTAssertTrue(issue.waitForExistence(timeout: 20)); issue.tap()
        let comments = app.buttons["讨论评论"]
        XCTAssertTrue(comments.waitForExistence(timeout: 15))
        // Markdown finishes asynchronously and changes the rows below its height.
        // Wait for that content before computing the navigation button's tap point.
        XCTAssertTrue(app.staticTexts["Issue fixture body"].waitForExistence(timeout: 15))
        comments.tap()
        XCTAssertTrue(app.navigationBars["讨论"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["请增加英文支持"].waitForExistence(timeout: 15))
        let reply = app.buttons["reply-comment-71"]
        XCTAssertTrue(reply.waitForExistence(timeout: 15)); reply.tap()
        XCTAssertTrue(app.staticTexts["reply-recipient"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["reply-recipient"].label, "回复 @fixture-follower")
        XCTAssertTrue(app.staticTexts["请增加英文支持"].exists)
        XCTAssertFalse(app.buttons["发送"].isEnabled)
        let editor = app.textViews["Markdown 正文"]
        editor.tap(); editor.typeText("confirmed reply")
        keepScreenshot(app, name: "issue-quoted-reply")
        app.buttons["发送"].tap(); app.buttons["确认发送"].tap()
        XCTAssertTrue(app.navigationBars["讨论"].waitForExistence(timeout: 20)); app.swipeUp()
        let delivered = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'confirmed reply'")).firstMatch
        XCTAssertTrue(delivered.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["reply-comment-73"].exists)
    }
    func testActivityCalendarSelectsDayAndShowsEvents() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-user-connections-style-preview"]; app.launch()
        let followers = app.buttons["account-connections-followers"]
        XCTAssertTrue(followers.waitForExistence(timeout: 20)); followers.tap()
        let person = app.buttons["connection-person-fixture-follower"]
        XCTAssertTrue(person.waitForExistence(timeout: 15)); person.tap()
        let chart = app.buttons["活动图表"]
        XCTAssertTrue(chart.waitForExistence(timeout: 15)); chart.tap()
        XCTAssertTrue(app.staticTexts["已加载 90 条公开活动"].waitForExistence(timeout: 20))
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        let cell = app.buttons["activity-day-" + formatter.string(from: Date())]
        XCTAssertTrue(cell.waitForExistence(timeout: 10)); cell.tap()
        keepScreenshot(app, name: "activity-daily-calendar")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts.matching(identifier: "推送了提交").firstMatch.waitForExistence(timeout: 10))
    }
    func testCurrentAccountConnectionsOpenPeopleAndProfiles() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-user-connections-style-preview"]
        app.launch()
        let followers = app.buttons["account-connections-followers"]
        XCTAssertTrue(followers.waitForExistence(timeout: 20))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS '2'"), object: followers)], timeout: 15), .completed)
        keepScreenshot(app, name: "account-connections-home")
        followers.tap()
        let follower = app.buttons["connection-person-fixture-follower"]
        XCTAssertTrue(follower.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["connection-person-fixture-second"].exists)
        keepScreenshot(app, name: "account-followers-list")
        follower.tap()
        XCTAssertTrue(app.staticTexts["关注列表测试用户"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["fixture-follower"].exists)
        app.navigationBars.buttons["关注者"].tap()
        XCTAssertTrue(follower.waitForExistence(timeout: 5))
        app.navigationBars.buttons["RepoPocket"].tap()
        let following = app.buttons["account-connections-following"]
        XCTAssertTrue(following.waitForExistence(timeout: 5)); following.tap()
        let person = app.buttons["connection-person-fixture-following"]
        XCTAssertTrue(person.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["connection-person-fixture-follower"].exists)
        person.tap()
        XCTAssertTrue(app.staticTexts["关注列表测试用户"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["fixture-following"].exists)
        keepScreenshot(app, name: "account-following-user-profile")
    }
    func testAccountTokenAdditionWorksWithoutSwitching() {
        exerciseAccountAddition(switchFirst: false)
    }
    func testAccountTokenAdditionStillWorksAfterSwitching() {
        exerciseAccountAddition(switchFirst: true)
    }
    private func exerciseAccountAddition(switchFirst: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-account-session-style-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture-active-account"].waitForExistence(timeout: 20))
        app.buttons["打开账号管理"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 10))
        if switchFirst {
            app.buttons["切换"].tap()
            XCTAssertFalse(app.buttons["移除本机账号"].exists)
        }
        app.buttons["添加 / 更新 GitHub 账号"].tap()
        let token = app.secureTextFields["粘贴你自己的 Token"]
        XCTAssertTrue(token.waitForExistence(timeout: 5))
        token.tap(); token.typeText("fixture-charlie")
        app.buttons["验证并安全保存"].tap()
        let active = app.staticTexts["fixture-active-account"]
        let completed = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '303' AND hittable == true"), object: active)], timeout: 20) == .completed
        if !completed {
            app.navigationBars.buttons["账号管理"].tap()
            keepScreenshot(app, name: switchFirst ? "account-switch-failure" : "account-control-failure")
        }
        XCTAssertTrue(completed,
                      "The current account session must verify and save the new account after switching")
        if switchFirst { keepScreenshot(app, name: "account-session-after-switch") }
    }
    func testLocalChangeDeletionUsesGuardedConfirmationAndCanCancel() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-local-git-style-preview"]
        app.launch()
        let folder = app.buttons["localgit.folder.debs"]
        XCTAssertTrue(folder.waitForExistence(timeout: 40)); folder.tap()
        let file = app.staticTexts["package-01.deb"]
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.press(forDuration: 1)
        app.buttons["删除文件"].tap()
        XCTAssertTrue(app.buttons["确认删除此文件"].waitForExistence(timeout: 15))
        keepScreenshot(app, name: "local-delete-confirmation")
        app.buttons["关闭"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10), "Cancelling confirmation must retain the selected file")
    }
    func testLocalImportDestinationClosesAtNestedFolder() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-local-git-style-preview"]
        app.launch()
        let choose = app.buttons["导入位置：根目录"]
        XCTAssertTrue(app.buttons["localgit.folder.debs"].waitForExistence(timeout: 40))
        reveal(choose, in: app); choose.tap()
        for name in ["目标", "子目录"] {
            let matches = app.buttons.matching(identifier: name)
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in matches.allElementsBoundByIndex.contains { $0.isHittable } }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
            matches.allElementsBoundByIndex.first(where: { $0.isHittable })!.tap()
        }
        app.buttons["选择此文件夹"].tap()
        let selected = app.buttons["导入位置：目标/子目录"]
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: selected)], timeout: 10) == .completed,
                      "Choosing a nested import destination must dismiss the entire picker")
        keepScreenshot(app, name: "local-import-destination")
    }
    func testLocalDEBUsesExistingEditorAndSavesToProject() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-local-git-style-preview"]
        app.launch()
        let folder = app.buttons["localgit.folder.debs"]
        XCTAssertTrue(folder.waitForExistence(timeout: 40)); folder.tap()
        let menu = app.buttons["更多操作：package-01.deb"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
        app.buttons["编辑包信息"].tap()
        let version = app.textFields["Version"]
        XCTAssertTrue(version.waitForExistence(timeout: 20))
        XCTAssertEqual(version.value as? String, "1.0")
        version.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        // Wait for each edit to reach the SwiftUI field before sending the next
        // phase; batching deletes with replacement text can race keyboard focus.
        version.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            // XCUITest may expose the placeholder as value when actual text is empty.
            predicate: NSPredicate { _, _ in
                let value = version.value as? String
                return value == nil || value == "" || value == version.placeholderValue
            }, object: version)], timeout: 10), .completed,
            "Cleared field: value=\(String(describing: version.value)), placeholder=\(String(describing: version.placeholderValue))")
        version.typeText("2.0")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == '2.0'"), object: version)], timeout: 10), .completed)
        XCTAssertEqual(version.value as? String, "2.0")
        let returnKey = app.keyboards.buttons["return"]
        if returnKey.exists { returnKey.tap() }
        let form = app.collectionViews["deb-editor-form"]
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        let generate = app.buttons["生成新的 deb（验证后保存）"]
        reveal(generate, in: app, scroll: form); generate.tap()
        let save = app.buttons["保存到本地项目"]
        reveal(save, in: app, scroll: form)
        keepScreenshot(app, name: "local-deb-editor")
        save.tap()
        XCTAssertTrue(folder.waitForExistence(timeout: 20))
        menu.tap(); app.buttons["编辑包信息"].tap()
        XCTAssertTrue(version.waitForExistence(timeout: 20))
        XCTAssertEqual(version.value as? String, "2.0", "The edited DEB must be saved to its original project path")
        app.buttons["关闭"].tap()
    }

    func testLocalWholeFolderImportsAllChildrenAndSelectsThem() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-local-git-style-preview", "-folder-import-style-preview"]
        app.launch()
        let add = app.buttons["导入文件夹"]
        XCTAssertTrue(add.waitForExistence(timeout: 40)); add.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: search)], timeout: 15) == .completed)
        let candidates = app.collectionViews.cells.containing(.staticText, identifier: "debs")
        // Files may restore the previous browser location instead of honoring
        // directoryURL. Navigate the real picker from either observed location.
        let fixtureParent = app.collectionViews.cells.containing(.staticText, identifier: "导入测试")
        let browserReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (fixtureParent.allElementsBoundByIndex + candidates.allElementsBoundByIndex).contains { $0.isHittable }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [browserReady], timeout: 30), .completed)
        if let parent = fixtureParent.allElementsBoundByIndex.first(where: { $0.isHittable }) { parent.tap() }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in candidates.allElementsBoundByIndex.contains { $0.isHittable } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        guard let source = candidates.allElementsBoundByIndex.first(where: { $0.isHittable }) else { XCTFail("Missing actual Files folder cell"); return }
        source.tap()
        XCTAssertTrue(app.staticTexts["插件甲.deb"].waitForExistence(timeout: 15), "Enter the selected folder before choosing Open")
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        let importAll = app.buttons["导入全部，更新同名文件"]
        XCTAssertTrue(importAll.waitForExistence(timeout: 15)); importAll.tap()
        XCTAssertTrue(app.staticTexts["已选 3"].waitForExistence(timeout: 30), "One folder selection must select all three imported files, including the nested DEB")
        let folder = app.buttons["localgit.folder.debs"]
        reveal(folder, in: app); folder.tap()
        let nested = app.buttons["localgit.folder.debs/nested"]
        XCTAssertTrue(nested.waitForExistence(timeout: 5)); nested.tap()
        XCTAssertTrue(app.staticTexts["插件乙.deb"].waitForExistence(timeout: 5), "Folder import must preserve the nested directory and its DEB")
        keepScreenshot(app, name: "local-whole-folder-import")
    }

    func testLocalFolderChangesAndSelectAll() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-local-git-style-preview"]
        app.launch()
        let folder = app.buttons["localgit.folder.debs"]
        XCTAssertTrue(folder.waitForExistence(timeout: 40), "Changes must show the containing folder")
        XCTAssertFalse(app.staticTexts["package-01.deb"].exists, "Collapsed folders must not flatten their files")
        app.buttons["全选"].tap()
        XCTAssertTrue(app.staticTexts["已选 45"].exists)
        XCTAssertFalse(app.buttons["全选"].exists, "Bulk selection must use one toggling button")
        app.buttons["取消全选"].tap()
        XCTAssertTrue(app.staticTexts["已选 0"].exists)
        folder.tap()
        XCTAssertTrue(app.staticTexts["package-01.deb"].waitForExistence(timeout: 5))
        app.buttons["debs 全选"].tap()
        XCTAssertTrue(app.staticTexts["已选 44"].exists)
        keepScreenshot(app, name: "local-folder-selection")
    }

    func testLocalGitHasFileAndFolderImport() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-local-git-style-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["导入文件"].waitForExistence(timeout: 40))
        XCTAssertTrue(app.buttons["导入文件夹"].exists)
        app.buttons["导入文件"].tap()
        XCTAssertTrue(app.buttons["取消导入"].waitForExistence(timeout: 10))
        // The app-owned Cancel appears before the remote Files service finishes
        // loading. Require the system browser itself, not just the sheet shell.
        let filesSearch = app.searchFields.firstMatch
        XCTAssertTrue(filesSearch.waitForExistence(timeout: 30), "The system Files browser must finish loading")
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: filesSearch)], timeout: 15) == .completed)
        keepScreenshot(app, name: "local-import-picker")
        app.buttons["取消导入"].tap()
        XCTAssertTrue(app.buttons["导入文件夹"].exists)
    }

    func testLongCommitPatchStartsAtLeadingEdge() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-patch-style-preview", "-long-patch-style-preview"]
        app.launch()
        app.buttons["打开提交差异"].tap()
        XCTAssertTrue(app.staticTexts["仅显示本次提交的变化"].waitForExistence(timeout: 10))
        var report = sourceReport(app)
        XCTAssertEqual(Int(report["offset"] ?? "-999"), 0, "A long patch must open at the start of each line")
        setSwitch(app, label: "显示空白（· 空格 / ⇥ Tab）", enabled: false)
        report = sourceReport(app)
        XCTAssertEqual(Int(report["offset"] ?? "-999"), 0, "Reformatting whitespace must retain the leading origin")
        keepScreenshot(app, name: "long-patch-leading")
    }

    func testRecordedCommitPatchStartsAtLeadingEdgeAfterReopening() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-patch-style-preview", "-recorded-patch-style-preview"]
        app.launch()
        app.buttons["打开提交差异"].tap()
        XCTAssertTrue(app.staticTexts["仅显示本次提交的变化"].waitForExistence(timeout: 10))
        var report = sourceReport(app)
        XCTAssertEqual(Int(report["offset"] ?? "-999"), 0)
        app.scrollViews.firstMatch.swipeLeft()
        report = sourceReport(app)
        XCTAssertGreaterThan(Int(report["offset"] ?? "0") ?? 0, 0)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["打开提交差异"].tap()
        XCTAssertTrue(app.staticTexts["仅显示本次提交的变化"].waitForExistence(timeout: 10))
        report = sourceReport(app)
        XCTAssertEqual(Int(report["offset"] ?? "-999"), 0, "Reopening a real commit file must start from its leading edge")
        keepScreenshot(app, name: "recorded-patch-leading")
    }

    func testWorkflowStepOpensActualOutputInline() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-workflow-log-style-preview"]
        app.launch()
        let step = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Test build output")).firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 10))
        step.tap()
        let text = app.textViews["代码正文"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue((text.value as? String ?? "").contains("中文构建失败详情"))
        XCTAssertFalse(app.staticTexts["完整输出见任务日志"].exists)
        keepScreenshot(app, name: "workflow-step-output")
        app.buttons["全屏查看此步骤日志"].tap()
        XCTAssertTrue(app.textViews["代码正文"].waitForExistence(timeout: 10))
        XCTAssertTrue((app.textViews["代码正文"].value as? String ?? "").contains("完整步骤输出已在 App 内显示"))
    }
    func testPatchHighlightAndRawHorizontalScrolling() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-patch-style-preview"]
        app.launch()
        app.buttons["打开提交差异"].tap()
        for mode in ["highlight", "raw"] {
            let line = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "AFTER_TAIL")).firstMatch
            XCTAssertTrue(line.waitForExistence(timeout: 10))
            var report = sourceReport(app)
            XCTAssertGreaterThan(Int(report["width"] ?? "0") ?? 0, Int(report["viewport"] ?? "0") ?? 0)
            XCTAssertEqual(Int(report["offset"] ?? "-999"), 0)
            keepScreenshot(app, name: "patch-" + mode + "-left")
            for _ in 0..<8 {
                let offset = Int(report["offset"] ?? "0") ?? 0
                let remaining = (Int(report["width"] ?? "0") ?? 0) - (Int(report["viewport"] ?? "0") ?? 0) - offset
                if remaining <= 10 { break }
                let y = line.frame.midY / app.frame.height
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: y)).press(forDuration: 0.05,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: y)))
                report = sourceReport(app)
            }
            XCTAssertGreaterThan(Int(report["offset"] ?? "0") ?? 0, 0)
            XCTAssertLessThanOrEqual((Int(report["width"] ?? "0") ?? 0) - (Int(report["viewport"] ?? "0") ?? 0) - (Int(report["offset"] ?? "0") ?? 0), 10)
            keepScreenshot(app, name: "patch-" + mode + "-right")
            if mode == "highlight" { setSwitch(app, label: "原始 patch", enabled: true) }
        }
    }

    func testRemoteFileEditorConfirmationDoesNotRestoreKeyboard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-user-connections-style-preview", "-remote-file-editor-preview"]
        app.launch()
        let edit = app.buttons["编辑"]
        XCTAssertTrue(edit.waitForExistence(timeout: 20)); edit.tap()
        let editor = app.navigationBars["编辑 editor.py"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let surfaces = app.textViews.matching(identifier: "代码正文")
        XCTAssertTrue(surfaces.firstMatch.waitForExistence(timeout: 10))
        // The reading surface can remain behind the presented editor.
        let code = surfaces.element(boundBy: surfaces.count - 1)
        XCTAssertTrue(code.isHittable)
        let original = code.value as? String ?? ""
        XCTAssertTrue(original.hasSuffix("END_MARKER"))
        XCTAssertEqual(original.components(separatedBy: "\n").count, 80)
        for _ in 0..<6 { code.swipeUp() }
        let viewport = code.frame.intersection(app.frame)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: viewport.maxX - 24, dy: viewport.maxY - 24)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Setup must focus the shipping code editor")
        code.typeText("x" + XCUIKeyboardKey.delete.rawValue + "_EDIT")
        let draft = code.value as? String ?? ""
        XCTAssertEqual(draft, original + "_EDIT", "Setup must edit and delete at the actual document end")
        let message = app.textFields["提交说明"]
        XCTAssertTrue(message.exists)
        var commitMessage = message.value as? String ?? ""
        var restoredFocus: [String] = []
        for focus in ["source", "commit-message"] {
            if focus == "commit-message" {
                message.tap(); message.typeText(" fixture")
                commitMessage = message.value as? String ?? ""
                XCTAssertTrue(commitMessage.contains("fixture"), "Setup must edit the commit message")
            }
            XCTAssertTrue(app.keyboards.firstMatch.exists, "Setup must begin confirmation with \(focus) focused")
            editor.buttons["提交"].tap()
            let confirm = app.buttons["确认提交"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "The real FileView confirmation must open: " + app.debugDescription)
            keepScreenshot(app, name: "remote-file-editor-confirmation-" + focus)
            let cancel = app.buttons.matching(NSPredicate(format: "label == '取消' OR label == 'Cancel'"))
                .allElementsBoundByIndex.last(where: { $0.isHittable })
            guard let cancel else { XCTFail("Missing confirmation cancel: " + app.debugDescription); return }
            cancel.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: confirm)], timeout: 5), .completed)
            XCTAssertTrue(editor.exists, "Cancelling confirmation must keep the editor sheet")
            XCTAssertEqual(code.value as? String, draft, "Cancelling must preserve the edited body")
            XCTAssertEqual(message.value as? String, commitMessage, "Cancelling must preserve the commit message")
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
            if XCTWaiter.wait(for: [hidden], timeout: 3) != .completed { restoredFocus.append(focus) }
            else {
                let reappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: app.keyboards.firstMatch)
                reappeared.isInverted = true
                if XCTWaiter.wait(for: [reappeared], timeout: 1) != .completed { restoredFocus.append(focus) }
            }
        }
        keepScreenshot(app, name: "remote-file-editor-cancelled")
        XCTAssertTrue(restoredFocus.isEmpty, "Cancelling confirmation must not reopen the keyboard; restored focus: \(restoredFocus)")
    }

    func testSourcePreviewAndEditorHorizontalScrolling() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-source-style-preview"]
        app.launch()
        for (mode, editable) in [("preview", "0"), ("editor", "1")] {
            let code = app.textViews["代码正文"]
            XCTAssertTrue(code.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["自动换行"].exists)
            XCTAssertFalse(app.buttons["取消换行"].exists)
            let original = code.value as? String
            var report = sourceReport(app)
            XCTAssertEqual(report["editable"], editable)
            XCTAssertGreaterThan(Int(report["width"] ?? "0") ?? 0, Int(report["viewport"] ?? "0") ?? 0)
            XCTAssertEqual(report["tail"], "0")
            XCTAssertEqual(report["fragments"], "3", "Each hard line must remain one visual line")
            XCTAssertEqual(report["hardLines"], "3")
            let gutterX = report["gutterX"], gutterWidth = report["gutterWidth"]
            keepScreenshot(app, name: "source-" + mode + "-left")
            for _ in 0..<8 {
                if report["tail"] == "1" { break }
                let viewport = app.scrollViews["代码横向滚动"].frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.maxX - 20, dy: viewport.minY + 50))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.minX + 20, dy: viewport.minY + 50)))
                report = sourceReport(app)
            }
            XCTAssertEqual(report["tail"], "1", "A real horizontal gesture must bring the tail glyph into view")
            assertTailIsRendered(app, report: report)
            XCTAssertGreaterThan(Int(report["offset"] ?? "0") ?? 0, 0)
            XCTAssertEqual(report["fragments"], "3")
            XCTAssertEqual(report["gutterX"], gutterX)
            XCTAssertEqual(report["gutterWidth"], gutterWidth)
            XCTAssertEqual(code.value as? String, original, "Scrolling must preserve hard newlines and content")
            keepScreenshot(app, name: "source-" + mode + "-right")
            for _ in 0..<8 {
                if (Int(report["offset"] ?? "0") ?? 0) <= 0 { break }
                let viewport = app.scrollViews["代码横向滚动"].frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.minX + 20, dy: viewport.minY + 50))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.maxX - 20, dy: viewport.minY + 50)))
                report = sourceReport(app)
            }
            XCTAssertLessThanOrEqual(Int(report["offset"] ?? "999") ?? 999, 0)
            XCTAssertEqual(report["gutterX"], gutterX)
            if mode == "preview" { app.buttons["切换到编辑"].tap() }
        }
    }

    private func setSwitch(_ app: XCUIApplication, label: String, enabled: Bool) {
        let control = app.switches[label]
        let expected = enabled ? "1" : "0"
        if control.value as? String != expected {
            // SwiftUI exposes the label row as a switch too. Tap the native
            // thumb instead of the row center, which can be noninteractive.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        }
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: control)], timeout: 5) == .completed, "The actual switch must change state")
    }

    private func sourceReport(_ app: XCUIApplication) -> [String: String] {
        let report = app.staticTexts["source-layout-report"]
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        let previous = report.label
        app.buttons["检查代码布局"].tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in report.label != previous }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        return Dictionary(uniqueKeysWithValues: report.label.split(separator: "|").compactMap { field in
            let pair = field.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        })
    }

    private func assertTailIsRendered(_ app: XCUIApplication, report: [String: String]) {
        guard let image = app.screenshot().image.cgImage else { XCTFail("Missing screen image"); return }
        let scale = CGFloat(image.width) / app.frame.width
        func value(_ key: String) -> CGFloat { CGFloat(Int(report[key] ?? "0") ?? 0) }
        let region = CGRect(x: value("tailX") * scale, y: value("tailY") * scale,
                            width: value("tailWidth") * scale, height: value("tailHeight") * scale).integral
        guard let crop = image.cropping(to: region), crop.width > 0, crop.height > 0 else { XCTFail("Tail is outside the actual screenshot"); return }
        var pixels = [UInt8](repeating: 255, count: crop.width * crop.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(crop.width), height: CGFloat(crop.height)))
        }
        let ink = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 220 || pixels[$0 + 1] < 220 || pixels[$0 + 2] < 220 }.count
        XCTAssertGreaterThan(ink, 20, "The tail must be drawn on screen, not only have a visible TextKit rectangle")
    }

    func testLocalHistoryCommitDetailAndFolding() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-local-git-style-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["没有可比较的远端分支"].waitForExistence(timeout: 15))

        let disclosure = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "本地提交历史")).firstMatch
        reveal(disclosure, in: app)
        XCTAssertEqual(disclosure.value as? String, "已折叠")
        keepScreenshot(app, name: "local-history-collapsed")
        disclosure.tap()
        XCTAssertEqual(disclosure.value as? String, "已展开")
        let latest = app.staticTexts["新增 Python 输出"]
        reveal(latest, in: app)
        keepScreenshot(app, name: "local-history-expanded")
        latest.tap()

        // Require decoded native values, not only a pushed navigation title.
        let file = app.staticTexts["示例.py"]
        XCTAssertTrue(file.waitForExistence(timeout: 15), "Native commit JSON must decode into the shipping Swift model")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "新增 Python 输出")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["+1  −1"].exists)
        XCTAssertFalse(app.buttons["重试"].exists)
        keepScreenshot(app, name: "local-commit-detail")
        file.tap()
        XCTAssertTrue(app.staticTexts["仅显示本次提交的变化"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["print(\"before\")"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["print(\"after\")"].exists)
        keepScreenshot(app, name: "local-commit-patch")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let collapse = app.buttons["收起提交记录"]
        reveal(collapse, in: app)
        collapse.tap()
        XCTAssertFalse(latest.exists)
        reveal(disclosure, in: app)
        XCTAssertEqual(disclosure.value as? String, "已折叠")
        for _ in 0..<3 {
            disclosure.tap()
            XCTAssertTrue(latest.waitForExistence(timeout: 5))
            XCTAssertEqual(disclosure.value as? String, "已展开")
            disclosure.tap()
            XCTAssertFalse(latest.exists, "Collapsed history must leave no detached commit rows")
            XCTAssertFalse(collapse.exists)
            XCTAssertEqual(disclosure.value as? String, "已折叠")
        }
        keepScreenshot(app, name: "local-history-after-folding")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, scroll: XCUIElement? = nil) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            if let scroll {
                // A form extends beneath the software keyboard. Its default swipe
                // starts on the keyboard, so drag within the visible form area.
                let viewport = scroll.frame.intersection(app.frame)
                let keyboard = app.keyboards.firstMatch
                // Keyboard.frame omits the predictive-input accessory on iOS 17.
                let bottom = keyboard.exists ? min(viewport.maxY, keyboard.frame.minY - 100) : viewport.maxY
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(CGVector(dx: viewport.midX, dy: bottom - 24))
                let end = origin.withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + 60))
                start.press(forDuration: 0.05, thenDragTo: end)
            } else { app.swipeUp() }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        XCTAssertTrue(element.isHittable)
    }

    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testReadmeBadgesAndInAppLink() {
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-readme-style-preview"]
        app.launch()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 15))
        // WebKit can expose its accessibility tree before navigation finishes.
        // A tap during that interval is ignored despite the link already existing.
        XCTAssertTrue(app.staticTexts["readme-document-ready"].waitForExistence(timeout: 30))
        XCTAssertTrue(web.images["累计下载次数"].waitForExistence(timeout: 30))
        XCTAssertTrue(web.images["最新版本"].waitForExistence(timeout: 10))
        XCTAssertLessThan(web.frame.height, 750, "Short README must not grow to the viewport/inline height cap")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "readme-badges"; attachment.lifetime = .keepAlways; add(attachment)
        let link = web.links["在 App 内打开仓库"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: link)], timeout: 10), .completed)
        link.tap()
        XCTAssertTrue(app.staticTexts["readme-link-opened"].waitForExistence(timeout: 15))
    }
    func testNativeSwipeBoundaries() {
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-swipe-style-preview"]
        app.launch()
        for id in ["first", "middle", "last"] {
            let row = app.buttons["row-" + id]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.swipeLeft()
            XCTAssertTrue(app.buttons["删除"].firstMatch.waitForExistence(timeout: 5))
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "swipe-" + id
            attachment.lifetime = .keepAlways
            add(attachment)
            row.swipeRight()
        }
    }
}
