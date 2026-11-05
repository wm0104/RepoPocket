import XCTest

final class UploadEditorTests: XCTestCase {
    func testFirstOpenLoadsDebAndEditedCopyKeepsInheritedDestination() {
        let app = launch()
        assertTarget(app, "debs/upload-editor-fixture.deb")
        XCTAssertTrue(app.buttons["upload-branch"].label.contains("test"))
        openEditor(app)
        let version = app.textFields["deb-version"]
        XCTAssertTrue(version.waitForExistence(timeout: 10), "First presentation must load the selected file: " + app.debugDescription)
        XCTAssertEqual(version.value as? String, "1.0")
        XCTAssertEqual(app.textFields["deb-package"].value as? String, "com.example.upload-fixture")
        XCTAssertFalse(app.textFields["deb-author"].exists)
        screenshot(app, "deb-first-open-common-fields")
        version.tap()
        let keyboardIntroduction = app.buttons["Continue"]
        if keyboardIntroduction.waitForExistence(timeout: 2) { keyboardIntroduction.tap() }
        version.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "2.0\n")
        reveal(app.buttons["deb-generate"], in: app)
        app.buttons["deb-generate"].tap()
        let use = app.buttons["使用新 deb 提交 / 发布"]
        reveal(use, in: app); use.tap()
        let notice = app.alerts["提示"]
        if notice.waitForExistence(timeout: 5) { notice.buttons["好"].tap() }
        assertTarget(app, "debs/upload-editor-fixture.deb")
        openEditor(app)
        XCTAssertTrue(version.waitForExistence(timeout: 10))
        XCTAssertEqual(version.value as? String, "2.0", "Only the original queue item should be replaced")
        app.buttons["关闭"].tap()
        reveal(app.buttons["upload-preview"], in: app); app.buttons["upload-preview"].tap()
        XCTAssertTrue(app.navigationBars["确认原子提交"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["新增：debs/upload-editor-fixture.deb"].exists)
        screenshot(app, "upload-inherited-preview")
        app.buttons["取消"].tap()
        assertReadOnly(app)
    }

    func testOriginalAndOptionalFieldsAreCollapsedAndPreserved() {
        let app = launch()
        assertTarget(app, "debs/upload-editor-fixture.deb")
        openEditor(app)
        XCTAssertTrue(app.textFields["deb-version"].waitForExistence(timeout: 10))
        let original = app.buttons["deb-original"]
        reveal(original, in: app); original.tap()
        XCTAssertTrue(app.staticTexts["Upload Fixture"].exists)
        screenshot(app, "deb-original-expanded")
        original.tap()
        let more = app.buttons["deb-more-fields"]
        reveal(more, in: app); more.tap()
        let author = app.textFields["deb-author"]
        reveal(author, in: app)
        XCTAssertEqual(author.value as? String, "Fixture Author")
        screenshot(app, "deb-more-fields-expanded")
        reveal(more, in: app); more.tap()
        XCTAssertFalse(author.exists)
        app.buttons["关闭"].tap()
        assertReadOnly(app)
    }

    func testExistingFilenameRequiresExplicitReplacement() {
        let app = launch(collision: true)
        let replace = app.buttons["确认替换同名文件…"]
        reveal(replace, in: app)
        XCTAssertTrue(replace.waitForExistence(timeout: 15), app.debugDescription)
        replace.tap()
        let confirm = app.buttons["确认替换"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        assertTarget(app, "debs/upload-editor-fixture.deb")
        reveal(app.buttons["upload-preview"], in: app); app.buttons["upload-preview"].tap()
        XCTAssertTrue(app.navigationBars["确认原子提交"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["替换：debs/upload-editor-fixture.deb"].exists)
        XCTAssertTrue(app.staticTexts["原 SHA：cccccccccccccccccccccccccccccccccccccccc"].exists)
        screenshot(app, "upload-explicit-replacement")
        app.buttons["取消"].tap()
        assertReadOnly(app)
    }

    func testMultipleFilesInheritFolderAndOneCanMoveIndependently() {
        let app = launch()
        assertTarget(app, "debs/upload-editor-fixture.deb")
        let inbox = app.buttons["待上传文件"]
        reveal(inbox, in: app); inbox.tap()
        let first = app.staticTexts["upload-fixture-one.txt"]
        XCTAssertTrue(first.waitForExistence(timeout: 10)); first.tap()
        app.staticTexts["upload-fixture-two.txt"].tap()
        app.buttons["选择 2 个文件"].tap()
        let firstTarget = app.staticTexts["upload-target-upload-fixture-one.txt"]
        reveal(firstTarget, in: app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "debs/upload-fixture-one.txt"), object: firstTarget)], timeout: 15), .completed)
        let secondTarget = app.staticTexts["upload-target-upload-fixture-two.txt"]
        reveal(secondTarget, in: app)
        XCTAssertEqual(secondTarget.label, "debs/upload-fixture-two.txt")
        let menu = app.buttons["文件操作：upload-fixture-one.txt"]
        reveal(menu, in: app); menu.tap(); app.buttons["更改位置"].tap()
        let parent = app.buttons["上级目录"]
        XCTAssertTrue(parent.waitForExistence(timeout: 10)); parent.tap()
        app.buttons["上传到此文件夹"].tap()
        reveal(firstTarget, in: app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "upload-fixture-one.txt"), object: firstTarget)], timeout: 10), .completed)
        XCTAssertEqual(secondTarget.label, "debs/upload-fixture-two.txt")
        screenshot(app, "upload-multiple-independent-targets")
        assertReadOnly(app)
    }

    func testChangingBranchInvalidatesPreviouslyBoundTarget() {
        let app = launch()
        assertTarget(app, "debs/upload-editor-fixture.deb")
        let branch = app.buttons["upload-branch"]
        reveal(branch, in: app); branch.tap()
        let input = app.textFields["留空使用默认分支"]
        reveal(input, in: app); input.tap()
        let keyboardIntroduction = app.buttons["Continue"]
        if keyboardIntroduction.waitForExistence(timeout: 2) { keyboardIntroduction.tap() }
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "main\n")
        let target = app.staticTexts["upload-target-upload-editor-fixture.deb"]
        reveal(target, in: app)
        XCTAssertEqual(target.label, "请选择上传目录")
        reveal(app.buttons["upload-preview"], in: app); app.buttons["upload-preview"].tap()
        let notice = app.alerts["提示"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "请先选择目标")).firstMatch.exists)
        notice.buttons["好"].tap()
        XCTAssertFalse(app.navigationBars["确认原子提交"].exists)
        assertReadOnly(app)
    }

    func testCancelledPickerIgnoresDelayedTargetResponse() {
        let app = launch(gated: true)
        assertTarget(app, "debs/upload-editor-fixture.deb")
        let branch = app.buttons["upload-branch"]
        reveal(branch, in: app); branch.tap()
        let input = app.textFields["留空使用默认分支"]
        reveal(input, in: app); input.tap()
        let keyboardIntroduction = app.buttons["Continue"]
        if keyboardIntroduction.waitForExistence(timeout: 2) { keyboardIntroduction.tap() }
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "main\n")
        let directory = app.buttons["upload-directory"]
        reveal(directory, in: app); directory.tap()
        let choose = app.buttons["上传到此文件夹"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10)); choose.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: choose)], timeout: 10), .completed)
        app.buttons["取消"].tap()
        let audit = app.staticTexts["upload-fixture-audit"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "pending=1"), object: audit)], timeout: 10), .completed)
        app.buttons["upload-fixture-resume"].tap()
        let preview = app.buttons["upload-preview"]
        reveal(preview, in: app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: preview)], timeout: 10), .completed)
        let target = app.staticTexts["upload-target-upload-editor-fixture.deb"]
        reveal(target, in: app)
        XCTAssertEqual(target.label, "请选择上传目录", "A dismissed picker must not apply its late HEAD/tree response")
        reveal(directory, in: app)
        XCTAssertTrue(directory.label.contains("请选择"))
        assertReadOnly(app)
    }

    private func launch(collision: Bool = false, gated: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-upload-editor-style-preview"]
        if collision { app.launchArguments.append("-upload-editor-collision") }
        if gated { app.launchArguments.append("-upload-picker-gated") }
        app.launch()
        XCTAssertTrue(app.buttons["upload-directory"].waitForExistence(timeout: 20), app.debugDescription)
        return app
    }
    private func assertTarget(_ app: XCUIApplication, _ path: String) {
        let target = app.staticTexts["upload-target-upload-editor-fixture.deb"]
        reveal(target, in: app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", path), object: target)], timeout: 15), .completed, app.debugDescription)
    }
    private func openEditor(_ app: XCUIApplication) {
        let menu = app.buttons["文件操作：upload-editor-fixture.deb"]
        reveal(menu, in: app); menu.tap()
        app.buttons["编辑包信息"].tap()
    }
    private func assertReadOnly(_ app: XCUIApplication) {
        app.buttons["upload-fixture-check"].tap()
        let audit = app.staticTexts["upload-fixture-audit"]
        let clean = NSPredicate { _, _ in audit.label.hasPrefix("writes=0; rejected=0; reads=") && !audit.label.contains("reads=0;") && audit.label.hasSuffix("pending=0") }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: clean, object: nil)], timeout: 5), .completed, app.debugDescription)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for attempt in 0..<20 {
            let scroll = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
            let frame = scroll.frame.intersection(app.frame)
            let top = max(frame.minY, app.navigationBars.firstMatch.frame.maxY) + 12
            let keyboard = app.keyboards.firstMatch
            let bottom = min(frame.maxY - 30, keyboard.exists ? keyboard.frame.minY - 20 : frame.maxY - 30)
            let viewport = CGRect(x: frame.minX, y: top, width: frame.width, height: max(60, bottom - top))
            if element.exists && element.isHittable && viewport.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let up = element.exists ? element.frame.midY > viewport.midY : attempt < 10
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let high = origin.withOffset(CGVector(dx: viewport.maxX - 12, dy: viewport.minY + 10))
            let low = origin.withOffset(CGVector(dx: viewport.maxX - 12, dy: viewport.maxY - 10))
            (up ? low : high).press(forDuration: 0.05, thenDragTo: up ? high : low)
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
