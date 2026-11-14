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
        openTheme(app); assertSelectedTheme("跟随系统", app: app)
        app.buttons["深色"].tap(); waitForTheme("dark", app: app)
        openTheme(app); assertSelectedTheme("深色", app: app)
        app.buttons["浅色"].tap(); waitForTheme("light", app: app)
        app.terminate()
        app.launchArguments.append("-preserve-settings-theme-preview")
        app.launch()
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        waitForTheme("light", app: app)
        openTheme(app); assertSelectedTheme("浅色", app: app)
        app.buttons["跟随系统"].tap(); waitForTheme("system", app: app)
        openTheme(app); assertSelectedTheme("跟随系统", app: app)
        app.buttons["跟随系统"].tap()
        options.tap(); app.buttons["选择文件夹"].tap()
        let cancel = app.buttons["取消"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "settings-compact-native-menu"; attachment.lifetime = .keepAlways; add(attachment)
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
            XCTAssertEqual(app.buttons[title].isSelected, title == expected, "Only \(expected) should be checked")
        }
    }
    private func waitForTheme(_ value: String, app: XCUIApplication) {
        let changed = expectation(for: NSPredicate { _, _ in
            app.staticTexts["settings-theme-probe"].label == value
        }, evaluatedWith: nil)
        wait(for: [changed], timeout: 5)
    }
}
