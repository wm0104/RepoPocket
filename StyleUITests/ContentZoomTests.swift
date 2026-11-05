import XCTest
import UIKit

final class ContentZoomTests: XCTestCase {
    func testSourceZoomRemeasuresTextWithoutChangingDocumentOrControls() {
        let app = launch(["-source-style-preview"])
        let code = app.textViews["代码正文"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        let original = code.value as? String
        let baseline = report(app)
        let controls = app.buttons["content-zoom-in"].frame
        let navigation = app.navigationBars.firstMatch.frame
        for _ in 0..<10 { app.buttons["content-zoom-in"].tap() }
        XCTAssertEqual(app.buttons["content-zoom-reset"].value as? String, "200%")
        XCTAssertFalse(app.buttons["content-zoom-in"].isEnabled)
        let enlarged = report(app)
        XCTAssertEqual(number(enlarged, "font"), number(baseline, "font") * 2, accuracy: 0.1)
        XCTAssertGreaterThan(number(enlarged, "lineHeight"), number(baseline, "lineHeight") * 1.9)
        XCTAssertGreaterThan(number(enlarged, "width"), number(baseline, "width") * 1.9)
        XCTAssertEqual(enlarged["hardLines"], enlarged["fragments"])
        XCTAssertEqual(code.value as? String, original)
        XCTAssertEqual(app.buttons["content-zoom-in"].frame, controls)
        XCTAssertEqual(app.navigationBars.firstMatch.frame, navigation)
        screenshot(app, "source-zoom-200")
        for _ in 0..<14 { app.buttons["content-zoom-out"].tap() }
        XCTAssertEqual(app.buttons["content-zoom-reset"].value as? String, "60%")
        XCTAssertFalse(app.buttons["content-zoom-out"].isEnabled)
        XCTAssertEqual(number(report(app), "font"), number(baseline, "font") * 0.6, accuracy: 0.1)
        app.buttons["content-zoom-reset"].tap()
        XCTAssertEqual(number(report(app), "font"), number(baseline, "font"), accuracy: 0.1)
        XCTAssertEqual(code.value as? String, original)
    }

    func testEditorZoomPreservesSelectionKeyboardAndTypedText() {
        let app = launch(["-source-style-preview"])
        app.buttons["切换到编辑"].tap()
        let code = app.textViews["代码正文"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.08)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        code.typeText("zoom_probe")
        let text = code.value as? String
        let baseline = report(app)
        let keyboard = app.keyboards.firstMatch.frame
        for _ in 0..<3 { app.buttons["content-zoom-in"].tap() }
        let enlarged = report(app)
        XCTAssertEqual(enlarged["selection"], baseline["selection"])
        XCTAssertEqual(code.value as? String, text)
        XCTAssertGreaterThan(number(enlarged, "font"), number(baseline, "font"))
        XCTAssertEqual(app.keyboards.firstMatch.frame, keyboard)
        XCTAssertEqual(enlarged["fragments"], enlarged["hardLines"])
        screenshot(app, "editor-zoom-keyboard")
        code.typeText("_after")
        XCTAssertTrue((code.value as? String ?? "").contains("zoom_probe_after"))
    }

    func testCommitPatchZoomKeepsHighlightAndRawViewsScrollable() {
        let app = launch(["-patch-style-preview"])
        app.buttons["打开提交差异"].tap()
        assertDiffZoom(app, name: "commit-highlight")
        let toggle = app.switches["原始 patch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        assertDiffZoom(app, name: "commit-raw")
    }

    func testLocalDiffZoomKeepsDiffAndOriginalTextScrollable() {
        let app = launch(["-patch-style-preview", "-local-diff-style-preview"])
        app.buttons["打开提交差异"].tap()
        assertDiffZoom(app, name: "local-diff")
        app.segmentedControls.buttons["全文"].tap()
        assertDiffZoom(app, name: "local-original")
    }

    func testBudgetExceededShowsOriginalTextWithoutFabricatedCounts() {
        let app = launch(["-patch-style-preview", "-local-diff-style-preview", "-budget-diff-style-preview"])
        app.buttons["打开提交差异"].tap()
        XCTAssertTrue(app.staticTexts["变化范围超过计算预算，无法精确计算差异，已显示原文对照。"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["基线文本"].exists)
        XCTAssertFalse(app.staticTexts["+2  −2"].exists)
        XCTAssertFalse(app.staticTexts["+1001  −1001"].exists)
        XCTAssertFalse(app.staticTexts["文本内容相同（或两侧均为空文件）"].exists)
        app.buttons["content-zoom-in"].tap()
        XCTAssertEqual(app.buttons["content-zoom-reset"].value as? String, "110%")
        screenshot(app, "local-budget-original")
    }

    private func assertDiffZoom(_ app: XCUIApplication, name: String) {
        app.buttons["content-zoom-reset"].tap()
        let line = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "AFTER_TAIL")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        let baseline = report(app)
        let height = line.frame.height
        let controls = app.buttons["content-zoom-in"].frame
        let navigation = app.navigationBars.firstMatch.frame
        for _ in 0..<10 { app.buttons["content-zoom-in"].tap() }
        let enlarged = report(app)
        XCTAssertGreaterThan(number(enlarged, "width"), number(baseline, "width") * 1.8)
        XCTAssertGreaterThan(line.frame.height, height * 1.5)
        XCTAssertEqual(app.buttons["content-zoom-in"].frame, controls)
        XCTAssertEqual(app.navigationBars.firstMatch.frame, navigation)
        XCTAssertGreaterThanOrEqual(controls.width, 44 - 0.000001)
        XCTAssertGreaterThanOrEqual(controls.height, 44 - 0.000001)
        screenshot(app, name + "-zoom-200")
        let y = min(line.frame.midY, app.frame.height - 120)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width - 30, dy: y))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: y)))
        XCTAssertGreaterThan(number(report(app), "offset"), 0)
        app.buttons["content-zoom-reset"].tap()
        XCTAssertEqual(number(report(app), "width"), number(baseline, "width"), accuracy: 2)
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview"] + arguments
        app.launch()
        return app
    }

    private func report(_ app: XCUIApplication) -> [String: String] {
        let label = app.staticTexts["source-layout-report"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        let previous = label.label
        app.buttons["检查代码布局"].tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in label.label != previous }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        let values = Dictionary(uniqueKeysWithValues: label.label.split(separator: "|").compactMap { field -> (String, String)? in
            let pair = field.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        })
        XCTAssertNil(values["error"], label.label)
        return values
    }

    private func number(_ report: [String: String], _ key: String) -> Double { Double(report[key] ?? "") ?? 0 }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
