import XCTest

final class ReadingZoomTests: XCTestCase {
    func testHTMLPageZoomChangesContentWithoutReloadingOrResettingScroll() {
        let app = launch()
        app.buttons["HTML 正文"].tap()
        let ready = app.staticTexts["reading-zoom-report"]
        XCTAssertTrue(ready.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "loads=1|"), object: ready)], timeout: 10), .completed)
        let navigation = app.navigationBars.firstMatch.frame
        let controls = app.buttons["content-zoom-in"].frame
        let baseline = report(app)
        app.webViews.firstMatch.swipeUp()
        XCTAssertGreaterThan(number(report(app), "offset"), 0)
        for _ in 0..<10 { app.buttons["content-zoom-in"].tap() }
        let enlarged = report(app)
        XCTAssertEqual(number(enlarged, "zoom"), 2, accuracy: 0.001)
        XCTAssertEqual(enlarged["loads"], "1")
        XCTAssertGreaterThan(number(enlarged, "offset"), 0)
        XCTAssertGreaterThan(number(enlarged, "height"), number(baseline, "height") * 1.5)
        XCTAssertEqual(app.navigationBars.firstMatch.frame, navigation)
        XCTAssertEqual(app.buttons["content-zoom-in"].frame, controls)
        screenshot(app, "readme-zoom-200")
        app.buttons["content-zoom-reset"].tap()
        let reset = report(app)
        XCTAssertEqual(number(reset, "zoom"), 1, accuracy: 0.001)
        XCTAssertEqual(reset["loads"], "1")
    }

    func testLongMarkdownOpensZoomableReaderWithoutChangingInlineComment() {
        let app = launch()
        app.buttons["Markdown 正文"].tap()
        XCTAssertTrue(app.buttons["放大阅读"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["content-zoom-in"].exists)
        app.buttons["放大阅读"].tap()
        let text = app.staticTexts["这是一段用于正文缩放回归的文字。"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let baseline = text.frame.height
        let done = app.buttons["完成"].frame
        for _ in 0..<10 { app.buttons["content-zoom-in"].tap() }
        XCTAssertEqual(app.buttons["content-zoom-reset"].value as? String, "200%")
        XCTAssertGreaterThan(text.frame.height, baseline * 1.5)
        XCTAssertEqual(app.buttons["完成"].frame, done)
        screenshot(app, "markdown-reader-zoom-200")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["放大阅读"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["content-zoom-in"].exists)
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-reading-zoom-style-preview"]
        app.launch()
        return app
    }
    private func report(_ app: XCUIApplication) -> [String: String] {
        let label = app.staticTexts["reading-zoom-report"]
        let previous = label.label
        app.buttons["检查阅读布局"].tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in label.label != previous }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        return Dictionary(uniqueKeysWithValues: label.label.split(separator: "|").compactMap { field -> (String, String)? in
            let pair = field.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        })
    }
    private func number(_ report: [String: String], _ key: String) -> Double { Double(report[key] ?? "") ?? 0 }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
