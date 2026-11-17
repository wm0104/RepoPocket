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
        var lightBrightness = 0
        for (title, value) in [("浅色", "light"), ("深色", "dark"), ("跟随系统", "system")] {
            app.buttons["theme-" + value].tap()
            assertSelectedTheme(title, app: app)
            assertVisibleThemeCheckmark(app, selectedID: "theme-" + value)
            assertAppearanceAndAboutLayout(app, phase: "production-theme-" + value)
            let brightness = disclosureHeaderBrightness(app, header: app.buttons["外观"])
            if value == "light" { lightBrightness = brightness }
            if value == "dark" { XCTAssertGreaterThan(lightBrightness - brightness, 60, "The actual production window must change color scheme") }
            keepScreenshot(app, name: "settings-production-root-\(value)-checked")
            // Leaving the tab and relaunching must not mask a stale visible checkmark.
            app.tabBars.buttons["主页"].tap()
            app.tabBars.buttons["设置"].tap()
            openTheme(app); assertSelectedTheme(title, app: app)
            app.terminate(); app.launch()
            app.tabBars.buttons["设置"].tap()
            openTheme(app); assertSelectedTheme(title, app: app)
            assertVisibleThemeCheckmark(app, selectedID: "theme-" + value)
        }
        for cycle in 0..<3 {
            tapNativeDisclosureHeader(app.buttons["外观"], trailing: cycle.isMultiple(of: 2))
            waitForElement(app.buttons["theme-system"], matching: "exists == false", app: app)
            XCTAssertTrue(app.staticTexts["关于"].isHittable)
            assertDisclosureCard(app, headerID: "settings-appearance", childIDs: [], phase: "production-cycle-\(cycle)-collapsed")
            if cycle == 0 { keepScreenshot(app, name: "settings-production-root-collapsed") }
            tapNativeDisclosureHeader(app.buttons["外观"], trailing: !cycle.isMultiple(of: 2))
            XCTAssertTrue(app.buttons["theme-system"].waitForExistence(timeout: 5))
            assertAppearanceAndAboutLayout(app, phase: "production-cycle-\(cycle)-expanded")
        }
        keepScreenshot(app, name: "settings-production-root-expanded-after-folding")
    }

    func testProfileAndAboutStayVisibleWithInlineAppearance() {
        let app = checkAppearanceAndPersistence()
        keepScreenshot(app, name: "settings-compact-native-menu")
    }

    private func checkAppearanceAndPersistence() -> XCUIApplication {
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
        let options = app.buttons["外观"]
        XCTAssertTrue(options.isHittable)
        XCTAssertFalse(app.buttons["theme-system"].exists)
        assertDisclosureCard(app, headerID: "settings-appearance", childIDs: [])
        // Both the text side and the empty trailing side must toggle the native header.
        tapNativeDisclosureHeader(options, trailing: false)
        XCTAssertTrue(app.buttons["theme-system"].waitForExistence(timeout: 5))
        tapNativeDisclosureHeader(options, trailing: true)
        waitForElement(app.buttons["theme-system"], matching: "exists == false", app: app)
        openTheme(app)
        assertAppearanceAndAboutLayout(app)
        app.buttons["跟随系统"].tap(); waitForTheme("system", app: app)
        openTheme(app); assertSelectedTheme("跟随系统", app: app)
        for (title, value) in [("深色", "dark"), ("浅色", "light"), ("跟随系统", "system")] {
            app.buttons[title].tap(); waitForTheme(value, app: app)
            openTheme(app); assertSelectedTheme(title, app: app)
            assertVisibleThemeCheckmark(app, selectedID: "theme-" + value)
            assertAppearanceAndAboutLayout(app)
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
        options.tap()
        waitForElement(app.buttons["theme-system"], matching: "exists == false", app: app)
        XCTAssertFalse(app.buttons["theme-system"].exists)
        openTheme(app); assertSelectedTheme("跟随系统", app: app)
        return app
    }

    // Keep the separately accepted device check available without blocking appearance regressions.
    func testUpdateMenuReturnsFromOfficialReleasesAfterThemeChanges() {
        let app = checkAppearanceAndPersistence()
        let options = app.buttons["外观"], profile = app.staticTexts["设置测试账号"]
        recordUpdateMenu(app, checkpoint: "after-appearance-toggle")
        for attempt in 1...2 {
            let updateOptions = updateMenuControl(app, checkpoint: "after-appearance-toggle-\(attempt)")
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
            print("Settings native timeout hierarchy:\n" + app.debugDescription)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "settings-state-timeout-ax"
            hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        XCTAssertEqual(result, .completed, "Expected \(element) to match \(predicate)", file: file, line: line)
    }
    private func openTheme(_ app: XCUIApplication) {
        if !app.buttons["theme-system"].exists {
            let item = app.buttons["外观"]
            waitForElement(item, matching: "exists == true AND hittable == true AND enabled == true", app: app)
            item.tap()
        }
        XCTAssertTrue(app.buttons["跟随系统"].waitForExistence(timeout: 5))
    }
    private func assertAppearanceAndAboutLayout(_ app: XCUIApplication, phase: String = "settings-layout") {
        assertDisclosureCard(app, headerID: "settings-appearance", childIDs: ["theme-system", "theme-light", "theme-dark"], phase: phase)
        let card = disclosureCard(app, headerID: "settings-appearance")
        let about = app.staticTexts["关于"]
        XCTAssertTrue(about.exists)
        XCTAssertTrue(about.isHittable, "About must remain visible after every native disclosure relayout")
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
            // The inline choice exposes the same state as its visible checkmark.
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
