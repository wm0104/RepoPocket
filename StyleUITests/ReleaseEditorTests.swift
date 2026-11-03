import XCTest
import UIKit

final class ReleaseEditorTests: XCTestCase {
    func testNewReleaseSurvivesScrollingAndInboxReturnWithoutWriting() {
        let app = launch()
        waitForMain(app)
        fillForm(app)
        let publish = app.buttons["release-publish"]
        reveal(publish, in: app)
        XCTAssertFalse(publish.isEnabled, "A new release requires a nonempty attachment")
        screenshot(app, "release-editor-filled")
        attachFromInbox(app, capture: true)
        reveal(publish, in: app)
        waitEnabled(publish, true)
        screenshot(app, "release-editor-attached")
        for _ in 0..<2 {
            scrollToTop(app)
            XCTAssertEqual(app.textFields["release-title"].value as? String, "Native release regression")
            XCTAssertEqual(app.textFields["release-tag"].value as? String, "v0.0.0-ui-fixture")
            waitForMain(app)
            let body = app.textViews["release-body"]
            reveal(body, in: app)
            XCTAssertTrue((body.value as? String)?.contains("Release notes end") == true,
                          "Body must survive attachment return and lazy-row reuse")
            reveal(app.staticTexts["release-editor-fixture.txt"], in: app)
            reveal(publish, in: app)
            waitEnabled(publish, true)
        }
        screenshot(app, "release-editor-scrolled")
        publish.tap()
        let confirmation = app.alerts["发布此发行版？"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "目标：main")).firstMatch.exists)
        screenshot(app, "release-editor-confirmation")
        // Never tap 确认保存: the regression stops at the real native confirmation.
        confirmation.buttons["取消"].tap()
        waitEnabled(publish, true)
        assertReadOnly(app)
    }

    func testAccountChangeDisablesPreparedRelease() {
        let app = launch()
        waitForMain(app)
        fillForm(app)
        attachFromInbox(app)
        let publish = app.buttons["release-publish"]
        reveal(publish, in: app); waitEnabled(publish, true)
        app.buttons["release-fixture-switch"].tap()
        waitEnabled(publish, false)
        // The editor intentionally disables the whole Form after an account change.
        // Do not try to scroll that disabled collection as though it were interactive.
        XCTAssertFalse(app.collectionViews.firstMatch.isEnabled)
        waitEnabled(publish, false)
        screenshot(app, "release-editor-account-changed")
        XCTAssertFalse(app.alerts["发布此发行版？"].exists)
        assertReadOnly(app)
    }

    func testDeniedPermissionKeepsCompleteFormDisabled() {
        let app = launch(denied: true)
        let denial = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "未确认仓库写权限")).firstMatch
        XCTAssertTrue(denial.waitForExistence(timeout: 15), app.debugDescription)
        fillForm(app)
        attachFromInbox(app)
        let publish = app.buttons["release-publish"]
        reveal(publish, in: app); waitEnabled(publish, false)
        scrollToTop(app)
        reveal(publish, in: app); waitEnabled(publish, false)
        screenshot(app, "release-editor-denied")
        assertReadOnly(app)
    }

    private func launch(denied: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-release-editor-style-preview"]
        if denied { app.launchArguments.append("-release-editor-denied") }
        app.launch()
        XCTAssertTrue(app.textFields["release-title"].waitForExistence(timeout: 20), app.debugDescription)
        return app
    }

    private func waitForMain(_ app: XCUIApplication) {
        let target = app.buttons["release-target-row"]
        XCTAssertTrue(target.waitForExistence(timeout: 15))
        // Wait for the real verified main row, without a production test hook.
        // Publish-enabled assertions below also verify readiness after row recycling.
        let ready = NSPredicate { _, _ in
            target.label.contains("main") && target.isEnabled
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 15), .completed,
                       "Target must be verified before scrolling: " + app.debugDescription)
    }

    private func fillForm(_ app: XCUIApplication) {
        let title = app.textFields["release-title"]
        title.tap(); dismissKeyboardIntroduction(app)
        title.typeText("Native release regression\n")
        let tag = app.textFields["release-tag"]
        reveal(tag, in: app); tag.tap(); tag.typeText("v0.0.0-ui-fixture\n")
        let body = app.textViews["release-body"]
        reveal(body, in: app); body.tap()
        let text = "Release notes begin\n" + String(repeating: "Long native release body requires scrolling.\n", count: 24) + "Release notes end"
        body.typeText(text)
        XCTAssertTrue((body.value as? String)?.contains("Release notes end") == true)
    }

    private func attachFromInbox(_ app: XCUIApplication, capture: Bool = false) {
        let choose = app.buttons["从待上传文件选择"]
        // It may be above the current viewport after the disabled-publish assertion.
        scrollToTop(app); reveal(choose, in: app)
        // Tap the actual leading text, not unused trailing space in a full-width AX cell.
        choose.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["待上传文件"].waitForExistence(timeout: 10), app.debugDescription)
        let file = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "release-editor-fixture.txt")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap()
        let selection = app.buttons["选择 1 个文件"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5)); waitEnabled(selection, true)
        if capture { screenshot(app, "release-editor-inbox") }
        selection.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
            object: app.navigationBars["待上传文件"])], timeout: 10), .completed)
        let attachment = app.staticTexts["release-editor-fixture.txt"]
        reveal(attachment, in: app)
        XCTAssertTrue(attachment.waitForExistence(timeout: 15), "Staged attachment must survive sheet dismissal")
    }

    private func waitEnabled(_ element: XCUIElement, _ enabled: Bool) {
        XCTAssertTrue(element.exists)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == %@", NSNumber(value: enabled)),
            object: element)], timeout: 15), .completed)
    }

    private func assertReadOnly(_ app: XCUIApplication) {
        app.buttons["release-fixture-check"].tap()
        let report = app.staticTexts["release-fixture-audit"]
        let clean = NSPredicate { _, _ in
            report.label.hasPrefix("writes=0; rejected=0; reads=") && !report.label.hasSuffix("reads=0")
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: clean, object: nil)], timeout: 5), .completed,
                       "Audit must include real reads and zero attempted writes: " + report.label)
    }

    private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<12 {
            let title = app.textFields["release-title"]
            if title.exists && title.isHittable { return }
            dragForm(app, up: false)
        }
        XCTFail("Could not reveal title: " + app.debugDescription)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        // Do not wait for existence before scrolling: Form lazily instantiates rows.
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            dragForm(app, up: true)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(element.isHittable)
    }

    private func dragForm(_ app: XCUIApplication, up: Bool) {
        let scroll = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        let frame = scroll.frame.intersection(app.frame)
        let keyboard = app.keyboards.firstMatch
        let bottom = keyboard.exists ? min(frame.maxY, keyboard.frame.minY - 100) : frame.maxY - 20
        let navigation = app.navigationBars.firstMatch
        let top = max(frame.minY, navigation.exists ? navigation.frame.maxY : frame.minY) + 35
        // Drag below the navigation bar; dragging at y=65 hits the bar instead of the Form.
        // Stay on the Form's edge, outside the independently scrolling TextEditor.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let high = origin.withOffset(CGVector(dx: frame.maxX - 12, dy: top))
        let low = origin.withOffset(CGVector(dx: frame.maxX - 12, dy: max(top + 40, bottom - 30)))
        (up ? low : high).press(forDuration: 0.05, thenDragTo: up ? high : low)
    }

    private func dismissKeyboardIntroduction(_ app: XCUIApplication) {
        let button = app.buttons["Continue"]
        if button.waitForExistence(timeout: 3) {
            let frame = button.frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: button)], timeout: 5), .completed)
        }
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
