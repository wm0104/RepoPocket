import XCTest
import UIKit

final class WorkflowLogTests: XCTestCase {
    func testExplicitLineHighlightsKeepTheCompleteReadOnlyContext() {
        let app = launch()
        let code = app.textViews["代码正文"]
        let text = code.value as? String ?? ""
        XCTAssertTrue(text.contains("准备步骤日志，保留普通上下文"))
        XCTAssertTrue(text.contains("##[error]中文构建失败详情 😀"))
        XCTAssertTrue(text.contains("##[warning]明确警告详情"))
        XCTAssertTrue(text.contains("let error = \"普通源码，不是错误\""))
        XCTAssertTrue(text.contains("完整步骤输出已在 App 内显示"))
        XCTAssertFalse(text.contains("\u{1B}"))
        XCTAssertEqual(app.staticTexts["workflow-log-summary"].label, "错误 1 · 警告 1")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.textFields["替换为"].exists)
        let colors = coloredPixels(app)
        XCTAssertGreaterThan(colors.error, 40, "The real text surface must paint an error-line background")
        XCTAssertGreaterThan(colors.warning, 40, "The real text surface must paint a warning-line background")
        screenshot(app, "workflow-log-highlighted-context")
        assertLongErrorNavigation(app)
    }

    func testRawToggleAndCopyPreserveTheOriginalWithoutChangingTheReadOnlyDocument() {
        let app = launch()
        let code = app.textViews["代码正文"]
        let displayed = code.value as? String
        assertOriginalCopy(app)
        let mode = app.buttons["workflow-log-toggle-raw"]
        mode.tap()
        XCTAssertEqual(mode.value as? String, "原始")
        XCTAssertTrue((code.value as? String ?? "").contains("##[error]中文构建失败详情"))
        XCTAssertTrue((code.value as? String ?? "").contains("完整步骤输出已在 App 内显示"))
        assertOriginalCopy(app)
        let colors = coloredPixels(app)
        XCTAssertEqual(colors.error, 0, "Original mode must not add semantic colors")
        XCTAssertEqual(colors.warning, 0)
        screenshot(app, "workflow-log-raw-original")
        mode.tap()
        XCTAssertEqual(mode.value as? String, "标注")
        XCTAssertEqual(code.value as? String, displayed)
        app.buttons["搜索当前文件"].tap()
        let onboarding = app.buttons["Continue"]
        if onboarding.waitForExistence(timeout: 3) { onboarding.tap() }
        let find = app.textFields["查找"]
        XCTAssertTrue(find.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["替换为"].exists)
        XCTAssertFalse(app.buttons["替换"].exists)
        XCTAssertFalse(app.buttons["替换全部"].exists)
        find.typeText("中文构建失败详情")
        app.buttons["下一处"].tap()
        XCTAssertEqual(code.value as? String, displayed)
        app.buttons["关闭查找"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
            object: app.keyboards.firstMatch)], timeout: 5), .completed)
        XCTAssertEqual(code.value as? String, displayed)
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-workflow-log-style-preview"]
        app.launch()
        let step = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Test build output")).firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 15)); step.tap()
        XCTAssertTrue(app.textViews["代码正文"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["workflow-log-summary"].waitForExistence(timeout: 15))
        return app
    }

    private func assertOriginalCopy(_ app: XCUIApplication) {
        let mode = app.buttons["workflow-log-toggle-raw"].value as? String
        app.buttons["workflow-log-copy-raw"].tap()
        XCTAssertEqual(app.buttons["workflow-log-toggle-raw"].value as? String, mode, "Copy must not invoke the adjacent mode toggle in the same List row")
        app.buttons["workflow-log-check-copy"].tap()
        let report = app.staticTexts["workflow-log-copy-audit"]
        XCTAssertEqual(report.label, "原文副本一致", "The fixture observes the real pasteboard, including original ANSI and newlines")
    }

    private func assertLongErrorNavigation(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments = ["-style-preview", "-workflow-log-style-preview", "-workflow-log-long-preview"]
        app.launch()
        let step = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Test build output")).firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 20)); step.tap()
        let position = app.staticTexts["workflow-error-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 45))
        XCTAssertTrue(position.label.contains(30001.formatted(.number)), position.label)
        XCTAssertTrue(position.label.contains("1/2"), "Exit code is not a concrete root cause: " + position.label)
        var report = logPosition(app)
        XCTAssertEqual(report["selectedVisible"], "1", "The actual error caret must be inside the visible UIKit viewport: \(report)")
        XCTAssertGreaterThan(Int(report["verticalOffset"] ?? "") ?? 0, 1000)
        screenshot(app, "workflow-log-long-located")
        app.buttons["workflow-error-next"].tap()
        XCTAssertTrue(position.label.contains(30010.formatted(.number)), position.label)
        report = logPosition(app)
        XCTAssertEqual(report["selectedVisible"], "1", "Next error must be visible: \(report)")
        app.buttons["workflow-error-previous"].tap()
        XCTAssertTrue(position.label.contains(30001.formatted(.number)), position.label)
        app.buttons["workflow-log-toggle-raw"].tap()
        app.buttons["workflow-error-next"].tap()
        XCTAssertEqual(logPosition(app)["selectedVisible"], "1")
        let code = app.textViews["代码正文"]
        code.swipeDown()
        let before = Int(logPosition(app)["verticalOffset"] ?? "") ?? -1
        app.buttons["workflow-log-append"].tap()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "background update"), object: code)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 30), .completed)
        let after = Int(logPosition(app)["verticalOffset"] ?? "") ?? -100
        XCTAssertLessThanOrEqual(abs(after - before), 3, "Background refresh must preserve the reader's manual scroll position")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    private func logPosition(_ app: XCUIApplication) -> [String: String] {
        let report = app.staticTexts["workflow-log-position-audit"]
        let previous = report.label
        app.buttons["workflow-log-check-position"].tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", previous), object: report)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15), .completed)
        return Dictionary(uniqueKeysWithValues: report.label.split(separator: "|").compactMap {
            let item = $0.split(separator: "=", maxSplits: 1).map(String.init)
            return item.count == 2 ? (item[0], item[1]) : nil
        })
    }

    private func coloredPixels(_ app: XCUIApplication) -> (error: Int, warning: Int) {
        guard let image = app.screenshot().image.cgImage else { XCTFail("Missing log screenshot"); return (0, 0) }
        let scale = CGFloat(image.width) / app.frame.width
        let frame = app.textViews["代码正文"].frame
            .intersection(app.scrollViews["代码横向滚动"].frame).intersection(app.frame)
        // Sample the timestamp's left edge, not colored emoji glyphs later in the line.
        let region = CGRect(x: (frame.minX + 10) * scale, y: frame.minY * scale,
            width: 3 * scale, height: frame.height * scale).integral
        guard let crop = image.cropping(to: region) else { XCTFail("Log surface is outside the actual screenshot"); return (0, 0) }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8,
                bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        var errors = 0, warnings = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
            if r > g + 12 && r > b + 12 && abs(g - b) < 12 { errors += 1 }
            if r > b + 24 && g > b + 12 && r > g + 5 { warnings += 1 }
        }
        return (errors, warnings)
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
