import XCTest

final class SettingsTests: XCTestCase {
    func testProductionRootThemeCheckmarksAndSchemePersistWithoutPreviewProbe() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // No -style-preview: exercise RepoPocketApp -> AccountRootView -> SettingsView.
        app.launchArguments = []
        app.launch()
        app.tabBars.buttons["设置"].tap()
        openTheme(app)
        keepScreenshot(app, name: "settings-production-root-menu-ready")
        closeTheme(app)
        var lightBrightness = 0
        for (title, value) in [("浅色", "light"), ("深色", "dark"), ("跟随系统", "system")] {
            openTheme(app)
            app.buttons[title].tap()
            waitForElement(app.buttons["跟随系统"], matching: "exists == false", app: app)
            openTheme(app)
            assertSelectedTheme(title, app: app)
            assertVisibleThemeCheckmark(app, selectedTitle: title)
            keepScreenshot(app, name: "settings-production-root-\(value)-checked")
            closeTheme(app)
            assertSettingsLayout(app)
            let brightness = disclosureHeaderBrightness(app, header: app.otherElements["settings-profile-card"])
            if value == "light" { lightBrightness = brightness }
            if value == "dark" { XCTAssertGreaterThan(lightBrightness - brightness, 60, "The actual production window must change color scheme") }
            // Leaving the tab and relaunching must not mask a stale visible checkmark.
            app.tabBars.buttons["主页"].tap()
            app.tabBars.buttons["设置"].tap()
            openTheme(app); assertSelectedTheme(title, app: app)
            assertVisibleThemeCheckmark(app, selectedTitle: title)
            closeTheme(app)
            app.terminate(); app.launch()
            app.tabBars.buttons["设置"].tap()
            openTheme(app); assertSelectedTheme(title, app: app)
            assertVisibleThemeCheckmark(app, selectedTitle: title)
            closeTheme(app)
        }
        for _ in 0..<3 {
            openTheme(app); assertSelectedTheme("跟随系统", app: app)
            assertVisibleThemeCheckmark(app, selectedTitle: "跟随系统")
            closeTheme(app)
            XCTAssertTrue(app.staticTexts["关于"].isHittable)
            assertSettingsLayout(app)
        }
        openTheme(app); assertSelectedTheme("跟随系统", app: app)
        keepScreenshot(app, name: "settings-production-root-menu-reopened")
        closeTheme(app)
    }

    func testProfileAndAboutStayVisibleWithNativeMenu() {
        let app = checkAppearanceAndPersistence()
        keepScreenshot(app, name: "settings-compact-native-menu")
    }

    private func checkAppearanceAndPersistence() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-settings-style-preview", "-safari-presentation-diagnostics"]
        addTeardownBlock { [weak self] in
            guard let self, (self.testRun?.failureCount ?? 0) > 0 else { return }
            self.keepScreenshot(app, name: "settings-state-timeout")
            let hierarchy = app.debugDescription
            print("Settings appearance failure hierarchy:\n" + hierarchy)
            let attachment = XCTAttachment(string: hierarchy)
            attachment.name = "settings-state-timeout-ax"
            attachment.lifetime = .keepAlways; self.add(attachment)
        }
        app.launch()
        let profile = app.staticTexts["设置测试账号"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["@fixture-settings"].exists)
        XCTAssertTrue(app.buttons["settings-social-accounts"].exists)
        XCTAssertTrue(app.staticTexts["关于"].exists)
        XCTAssertFalse(app.staticTexts["账号与安全"].exists)
        XCTAssertGreaterThanOrEqual(profile.frame.minY, app.navigationBars["设置"].frame.maxY)
        let options = app.buttons["settings-options"]
        XCTAssertTrue(options.isHittable)
        XCTAssertGreaterThanOrEqual(options.frame.width, 44)
        XCTAssertGreaterThanOrEqual(options.frame.height, 44)
        assertSettingsLayout(app)
        openTheme(app)
        app.buttons["跟随系统"].tap()
        waitForElement(app.buttons["跟随系统"], matching: "exists == false", app: app)
        waitForElement(options, matching: "exists == true AND hittable == true AND enabled == true", app: app)
        waitForTheme("system", app: app)
        for (title, value) in [("深色", "dark"), ("浅色", "light"), ("跟随系统", "system")] {
            openTheme(app)
            app.buttons[title].tap()
            waitForElement(app.buttons["跟随系统"], matching: "exists == false", app: app)
            waitForElement(options, matching: "exists == true AND hittable == true AND enabled == true", app: app)
            waitForTheme(value, app: app)
            openTheme(app); assertSelectedTheme(title, app: app)
            assertVisibleThemeCheckmark(app, selectedTitle: title)
            keepScreenshot(app, name: "settings-theme-\(value)-checked")
            closeTheme(app)
            assertSettingsLayout(app)
            app.terminate()
            app.launch()
            XCTAssertTrue(profile.waitForExistence(timeout: 10))
            waitForTheme(value, app: app)
            openTheme(app); assertSelectedTheme(title, app: app)
            assertVisibleThemeCheckmark(app, selectedTitle: title)
            closeTheme(app)
        }
        waitForElement(options, matching: "exists == true AND hittable == true AND enabled == true", app: app)
        return app
    }

    func testFolderAuthorizationPresentsAboveExistingSheet() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-settings-style-preview", "-settings-folder-sheet-preview"]
        app.launch()
        let open = app.buttons["settings-open-modal-authorization"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        let parent = app.staticTexts["settings-modal-parent"]
        XCTAssertTrue(parent.waitForExistence(timeout: 10))
        let request = app.buttons["settings-modal-request-folder"]
        for attempt in 1...2 {
            XCTAssertTrue(request.isEnabled && request.isHittable); request.tap()
            let cancel = app.buttons["workspace.import.cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Files must finish presenting before checking its controls")
            waitForElement(cancel, matching: "exists == true AND hittable == true AND enabled == true", app: app)
            XCTAssertTrue(cancel.isHittable)
            keepScreenshot(app, name: "settings-folder-over-existing-sheet-\(attempt)")
            cancel.tap()
            waitForElement(cancel, matching: "exists == false", app: app)
            waitForElement(app.staticTexts["settings-modal-authorization-state"], matching: "label == '已取消'", app: app)
            XCTAssertTrue(parent.exists)
            XCTAssertTrue(parent.isHittable)
            waitForElement(request, matching: "exists == true AND hittable == true AND enabled == true", app: app)
        }
        app.buttons["关闭父模态"].tap()
        waitForElement(parent, matching: "exists == false", app: app)
    }

    func testFolderPickerCancelsAndSettingsRemainResponsive() {
        let app = checkAppearanceAndPersistence()
        for attempt in 1...2 {
            app.buttons["settings-options"].tap()
            let folder = app.buttons["选择文件夹"]
            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["通用"].exists, "Folder choice must be a sibling of General")
            XCTAssertFalse(app.buttons["跟随系统"].exists)
            folder.tap()
            let cancel = app.buttons["workspace.import.cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 10))
            XCTAssertTrue(cancel.isHittable)
            keepScreenshot(app, name: "settings-folder-picker-\(attempt)")
            cancel.tap()
            waitForElement(cancel, matching: "exists == false", app: app)
            waitForElement(app.buttons["settings-options"], matching: "exists == true AND hittable == true AND enabled == true", app: app)
            openTheme(app); assertSelectedTheme("跟随系统", app: app)
            closeTheme(app)
        }
    }

    // Keep the separately accepted device check available without blocking appearance regressions.
    func testUpdateMenuReturnsFromOfficialReleasesAfterThemeChanges() {
        let app = checkAppearanceAndPersistence()
        let options = app.buttons["settings-options"], profile = app.staticTexts["设置测试账号"]
        recordUpdateMenu(app, checkpoint: "after-appearance-toggle")
        for attempt in 1...2 {
            let updateOptions = updateMenuControl(app, checkpoint: "after-appearance-toggle-\(attempt)")
            XCTAssertTrue(updateOptions.isHittable); updateOptions.tap()
            let releases = app.buttons["官方发行版页"]
            XCTAssertTrue(releases.waitForExistence(timeout: 5)); releases.tap()
            // SFSafariViewController's native Done control, not GitHub page content.
            guard let done = tapNativeSafariDone(app, beforeTap: {
                keepScreenshot(app, name: "settings-official-releases-\(attempt)")
            }) else { return }
            waitForElement(done, matching: "exists == false", app: app)
            waitForElement(options, matching: "exists == true AND hittable == true AND enabled == true", app: app)
            XCTAssertTrue(profile.waitForExistence(timeout: 5))
            XCTAssertTrue(options.isHittable, "Closing Safari must restore responsive settings")
        }
        openTheme(app); assertSelectedTheme("跟随系统", app: app)
        assertVisibleThemeCheckmark(app, selectedTitle: "跟随系统")
        closeTheme(app)
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
            print("Settings native timeout hierarchy:\n" + app.debugDescription)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "settings-state-timeout-ax"
            hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        XCTAssertEqual(result, .completed, "Expected \(element) to match \(predicate)", file: file, line: line)
    }
    private func openTheme(_ app: XCUIApplication) {
        let options = app.buttons["settings-options"]
        waitForElement(options, matching: "exists == true AND hittable == true AND enabled == true", app: app)
        options.tap()
        let general = app.buttons["通用"]
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["选择文件夹"].exists)
        general.tap()
        let theme = app.buttons["主题"]
        XCTAssertTrue(theme.waitForExistence(timeout: 5)); theme.tap()
        XCTAssertTrue(app.buttons["跟随系统"].waitForExistence(timeout: 5))
    }
    private func closeTheme(_ app: XCUIApplication) {
        guard let selected = ["跟随系统", "浅色", "深色"].map({ app.buttons[$0] }).first(where: { $0.exists && $0.isSelected })
        else { return XCTFail("Native theme menu must have exactly one selected action") }
        selected.tap()
        waitForElement(app.buttons["跟随系统"], matching: "exists == false", app: app)
    }
    private func assertSettingsLayout(_ app: XCUIApplication) {
        let card = app.otherElements["settings-profile-card"]
        XCTAssertTrue(card.exists)
        let about = app.staticTexts["关于"]
        XCTAssertTrue(about.exists)
        XCTAssertTrue(about.isHittable, "About must remain visible after closing the native settings menu")
        let aboutCell = app.otherElements["settings-about-card"]
        XCTAssertTrue(aboutCell.frame.contains(about.frame), "About text must move with its own card")
        // Both AX card bounds and painted pixels must agree on the 10pt gap.
        assertPaintedCardGap(app, before: card, after: aboutCell, expected: 10)
    }

    private func assertSelectedTheme(_ expected: String, app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ["跟随系统", "浅色", "深色"].allSatisfy { title in
                let item = app.buttons[title]
                return item.exists && item.isSelected == (title == expected)
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        for title in ["跟随系统", "浅色", "深色"] {
            let item = app.buttons[title]
            XCTAssertTrue(item.exists)
            // Inspect the real UIKit action state, not the preview's stored-value probe.
            XCTAssertEqual(item.isSelected, title == expected, "Only \(expected) should be checked; AX value: \(String(describing: item.value))")
        }
    }
    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func waitForTheme(_ value: String, app: XCUIApplication) {
        let changed = expectation(for: NSPredicate { _, _ in
            let probe = app.staticTexts["settings-theme-probe"]
            return probe.exists && probe.label == value
        }, evaluatedWith: nil)
        wait(for: [changed], timeout: 5)
    }
}
