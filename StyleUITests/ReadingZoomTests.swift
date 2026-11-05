import XCTest
import UIKit

final class ReadingZoomTests: XCTestCase {
    func testHTMLPageZoomChangesContentWithoutReloadingOrResettingScroll() {
        let app = launch()
        app.buttons["HTML 正文"].tap()
        let ready = app.staticTexts["reading-zoom-report"]
        XCTAssertTrue(ready.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "loads=1|"), object: ready)], timeout: 10), .completed)
        let navigation = app.navigationBars.firstMatch.frame
        let controls = app.buttons["content-zoom-in"].frame
        let web = app.webViews["reading-zoom-web"]
        let sentinel = web.staticTexts["ZOOM_SENTINEL"]
        XCTAssertTrue(sentinel.waitForExistence(timeout: 10))
        XCTAssertEqual(web.staticTexts.matching(identifier: "ZOOM_SENTINEL").count, 1)
        let baseline = stableFrame(sentinel)
        web.swipeUp()
        XCTAssertGreaterThan(number(report(app), "offset"), 0)
        for _ in 0..<10 { app.buttons["content-zoom-in"].tap() }
        let enlarged = report(app)
        XCTAssertEqual(number(enlarged, "zoom"), 2, accuracy: 0.001)
        XCTAssertEqual(enlarged["loads"], "1")
        XCTAssertGreaterThan(number(enlarged, "offset"), 0)
        reveal(sentinel, in: web)
        let enlargedText = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            sentinel.frame.width > baseline.width * 1.8 && sentinel.frame.height > baseline.height * 1.8
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [enlargedText], timeout: 10), .completed)
        let enlargedFrame = stableFrame(sentinel)
        XCTAssertEqual(enlargedFrame.width, baseline.width * 2, accuracy: 1)
        XCTAssertEqual(enlargedFrame.height, baseline.height * 2, accuracy: 1)
        XCTAssertEqual(app.navigationBars.firstMatch.frame, navigation)
        XCTAssertEqual(app.buttons["content-zoom-in"].frame, controls)
        screenshot(app, "readme-zoom-200")
        web.swipeUp()
        XCTAssertGreaterThan(number(report(app), "offset"), 0)
        app.buttons["content-zoom-reset"].tap()
        let reset = report(app)
        XCTAssertEqual(number(reset, "zoom"), 1, accuracy: 0.001)
        XCTAssertEqual(reset["loads"], "1")
        XCTAssertGreaterThan(number(reset, "offset"), 0)
        reveal(sentinel, in: web)
        let restoredText = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(sentinel.frame.width - baseline.width) <= 1 && abs(sentinel.frame.height - baseline.height) <= 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restoredText], timeout: 10), .completed)
        let resetFrame = stableFrame(sentinel)
        XCTAssertEqual(resetFrame.width, baseline.width, accuracy: 1)
        XCTAssertEqual(resetFrame.height, baseline.height, accuracy: 1)
        XCTAssertEqual(app.navigationBars.firstMatch.frame, navigation)
        XCTAssertEqual(app.buttons["content-zoom-in"].frame, controls)
    }

    func testLongMarkdownOpensZoomableReaderWithoutChangingInlineComment() {
        let app = launch()
        app.buttons["Markdown 正文"].tap()
        XCTAssertTrue(app.buttons["放大阅读"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["content-zoom-in"].exists)
        let inlineHeight = app.staticTexts["这是一段用于正文缩放回归的文字。"].frame.height
        app.buttons["放大阅读"].tap()
        let reader = app.scrollViews["community-markdown-reader"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        let text = reader.staticTexts["这是一段用于正文缩放回归的文字。"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertEqual(reader.staticTexts.matching(identifier: "这是一段用于正文缩放回归的文字。").count, 1)
        let baseline = text.frame.height
        let done = app.navigationBars["正文"].buttons["完成"]
        let doneFrame = done.frame
        for _ in 0..<10 { reader.buttons["content-zoom-in"].tap() }
        XCTAssertEqual(reader.buttons["content-zoom-reset"].value as? String, "200%")
        XCTAssertGreaterThan(text.frame.height, baseline * 1.5)
        XCTAssertEqual(done.frame, doneFrame)
        screenshot(app, "markdown-reader-zoom-200")
        done.tap()
        XCTAssertTrue(app.buttons["放大阅读"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["content-zoom-in"].exists)
        XCTAssertEqual(app.staticTexts["这是一段用于正文缩放回归的文字。"].frame.height, inlineHeight, accuracy: 0.01)
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
    private func reveal(_ sentinel: XCUIElement, in web: XCUIElement) {
        for _ in 0..<6 {
            if sentinel.isHittable && web.frame.contains(sentinel.frame) { break }
            web.swipeDown()
        }
        XCTAssertTrue(sentinel.isHittable)
        XCTAssertTrue(web.frame.contains(sentinel.frame), "Measure the complete visible text, not a clipped AX frame")
    }
    private func stableFrame(_ element: XCUIElement) -> CGRect {
        var previous = CGRect.zero, stableSamples = 0
        let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = element.frame
            stableSamples = frame.width > 0 && frame.height > 0 && frame == previous ? stableSamples + 1 : 0
            previous = frame
            return stableSamples >= 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 10), .completed)
        return previous
    }
    private func number(_ report: [String: String], _ key: String) -> Double { Double(report[key] ?? "") ?? 0 }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
