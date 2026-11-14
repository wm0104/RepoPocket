import XCTest

final class SettingsTests: XCTestCase {
    func testProfileAndAboutStayVisibleWhileThemeAndFolderUseNativeMenu() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-settings-style-preview"]
        app.launch()
        let profile = app.staticTexts["设置测试账号"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["@fixture-settings"].exists)
        XCTAssertTrue(app.buttons["settings-social-accounts"].exists)
        XCTAssertTrue(app.staticTexts["关于"].exists)
        XCTAssertFalse(app.staticTexts["账号与安全"].exists)
        XCTAssertFalse(app.buttons["选择文件夹"].exists)
        XCTAssertGreaterThanOrEqual(profile.frame.minY, app.navigationBars["设置"].frame.maxY)
        let options = app.buttons["settings-options"]
        XCTAssertTrue(options.isHittable)
        openTheme(app)
        app.buttons["跟随系统"].tap(); waitForTheme("system", app: app)
        openTheme(app); assertSelectedTheme("跟随系统", app: app)
        for (title, value) in [("深色", "dark"), ("浅色", "light"), ("跟随系统", "system")] {
            app.buttons[title].tap(); waitForTheme(value, app: app)
            openTheme(app); assertSelectedTheme(title, app: app)
            keepScreenshot(app, name: "settings-theme-\(value)-checked")
            app.buttons[title].tap()
            app.terminate()
            app.launch()
            XCTAssertTrue(profile.waitForExistence(timeout: 10))
            waitForTheme(value, app: app)
            openTheme(app); assertSelectedTheme(title, app: app)
        }
        app.buttons["跟随系统"].tap()
        waitForElement(options, matching: "exists == true AND hittable == true AND enabled == true", app: app)
        recordUpdateMenu(app, checkpoint: "before-folder-picker")
        options.tap(); app.buttons["选择文件夹"].tap()
        let cancel = app.buttons["workspace.import.cancel"]
        waitForElement(cancel, matching: "exists == true AND hittable == true AND enabled == true", app: app)
        cancel.tap()
        // The profile can exist behind the root-level directory sheet during dismissal.
        waitForElement(cancel, matching: "exists == false", app: app)
        waitForElement(options, matching: "exists == true AND hittable == true AND enabled == true", app: app)
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        for attempt in 1...2 {
            let updateOptions = updateMenuControl(app, checkpoint: "after-folder-picker-\(attempt)")
            XCTAssertTrue(updateOptions.isHittable); updateOptions.tap()
            let releases = app.buttons["官方发行版页"]
            XCTAssertTrue(releases.waitForExistence(timeout: 5)); releases.tap()
            // SFSafariViewController's native Done control, not GitHub page content.
            let done = app.buttons.matching(NSPredicate(format: "identifier IN %@ OR label IN %@", ["Done", "完成"], ["Done", "完成"])).firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 10), "The real in-app Safari must present without waiting for GitHub to load")
            XCTAssertTrue(done.isHittable)
            keepScreenshot(app, name: "settings-official-releases-\(attempt)")
            done.tap()
            waitForElement(done, matching: "exists == false", app: app)
            waitForElement(options, matching: "exists == true AND hittable == true AND enabled == true", app: app)
            XCTAssertTrue(profile.waitForExistence(timeout: 5))
            XCTAssertTrue(options.isHittable, "Closing Safari must restore responsive settings")
        }
        openTheme(app); assertSelectedTheme("跟随系统", app: app)
        app.buttons["跟随系统"].tap()
        keepScreenshot(app, name: "settings-compact-native-menu")
    }
    private func recordUpdateMenu(_ app: XCUIApplication, checkpoint: String) {
        let root = app.buttons["settings-update-options"]
        let children = root.descendants(matching: .button).allElementsBoundByIndex
        func state(_ element: XCUIElement) -> String {
            guard element.exists else { return "exists=false" }
            return "id=\(element.identifier) label=\(element.label) enabled=\(element.isEnabled) hittable=\(element.isHittable) frame=\(element.frame)"
        }
        let report = XCTAttachment(string: "root: " + state(root) + "\nchildren:\n" + children.map(state).joined(separator: "\n") + "\n" + app.debugDescription)
        report.name = "settings-update-menu-" + checkpoint
        report.lifetime = .keepAlways; add(report)
    }
    private func updateMenuControl(_ app: XCUIApplication, checkpoint: String) -> XCUIElement {
        let root = app.buttons["settings-update-options"]
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        // SwiftUI Menu can expose a non-actionable AX wrapper around its real Button.
        // Accept only that wrapper's unique enabled, hittable Button, never coordinates.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard root.exists else { return false }
            if root.isEnabled && root.isHittable { return true }
            return root.descendants(matching: .button).allElementsBoundByIndex.filter { $0.exists && $0.isEnabled && $0.isHittable }.count == 1
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 10)
        recordUpdateMenu(app, checkpoint: checkpoint)
        if result != .completed { keepScreenshot(app, name: "settings-state-timeout") }
        XCTAssertEqual(result, .completed, "The actual Menu button must be enabled and hittable")
        if root.exists && root.isEnabled && root.isHittable { return root }
        let actual = root.descendants(matching: .button).allElementsBoundByIndex.filter { $0.exists && $0.isEnabled && $0.isHittable }
        XCTAssertEqual(actual.count, 1, "No arbitrary fallback outside the identified Menu")
        guard actual.count == 1 else { return root }
        XCTAssertTrue(root.frame.contains(actual[0].frame), "The actual Button must belong to the visible Menu bounds")
        return actual[0]
    }
    private func waitForElement(_ element: XCUIElement, matching predicate: String, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        let result = XCTWaiter.wait(for: [ready], timeout: 10)
        if result != .completed {
            keepScreenshot(app, name: "settings-state-timeout")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "settings-state-timeout-ax"
            hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        XCTAssertEqual(result, .completed, "Expected \(element) to match \(predicate)", file: file, line: line)
    }
    private func openTheme(_ app: XCUIApplication) {
        for title in ["settings-options", "通用", "主题"] {
            let item = app.buttons[title]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: item)], timeout: 10), .completed)
            item.tap()
        }
        XCTAssertTrue(app.buttons["跟随系统"].waitForExistence(timeout: 5))
    }
    private func assertSelectedTheme(_ expected: String, app: XCUIApplication) {
        for title in ["跟随系统", "浅色", "深色"] {
            let item = app.buttons[title]
            XCTAssertTrue(item.exists)
            // NativeActionMenu creates UIAction.state .on/.off; require its real AX trait.
            XCTAssertEqual(item.isSelected, title == expected, "Only \(expected) should be checked; AX value: \(String(describing: item.value))")
        }
    }
    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func waitForTheme(_ value: String, app: XCUIApplication) {
        let changed = expectation(for: NSPredicate { _, _ in
            app.staticTexts["settings-theme-probe"].label == value
        }, evaluatedWith: nil)
        wait(for: [changed], timeout: 5)
    }
}
