import XCTest
import UIKit

final class StyleBoundaryTests: XCTestCase {
    func testLocalFolderChangesAndSelectAll() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-local-git-style-preview"]
        app.launch()
        let folder = app.buttons["localgit.folder.debs"]
        XCTAssertTrue(folder.waitForExistence(timeout: 40), "Changes must show the containing folder")
        XCTAssertFalse(app.staticTexts["package-01.deb"].exists, "Collapsed folders must not flatten their files")
        app.buttons["全选"].tap()
        XCTAssertTrue(app.staticTexts["已选 45"].exists)
        app.buttons["取消全选"].tap()
        XCTAssertTrue(app.staticTexts["已选 0"].exists)
        folder.tap()
        XCTAssertTrue(app.staticTexts["package-01.deb"].waitForExistence(timeout: 5))
        app.buttons["debs 全选"].tap()
        XCTAssertTrue(app.staticTexts["已选 44"].exists)
        keepScreenshot(app, name: "local-folder-selection")
    }

    func testLocalGitHasFileAndFolderImport() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-local-git-style-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["导入文件"].waitForExistence(timeout: 40))
        XCTAssertTrue(app.buttons["导入文件夹"].exists)
        app.buttons["导入文件"].tap()
        XCTAssertTrue(app.buttons["取消导入"].waitForExistence(timeout: 10))
        // The app-owned Cancel appears before the remote Files service finishes
        // loading. Require the system browser itself, not just the sheet shell.
        let filesSearch = app.searchFields.firstMatch
        XCTAssertTrue(filesSearch.waitForExistence(timeout: 30), "The system Files browser must finish loading")
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: filesSearch)], timeout: 15) == .completed)
        keepScreenshot(app, name: "local-import-picker")
        app.buttons["取消导入"].tap()
        XCTAssertTrue(app.buttons["导入文件夹"].exists)
    }

    func testLongCommitPatchStartsAtLeadingEdge() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-patch-style-preview", "-long-patch-style-preview"]
        app.launch()
        app.buttons["打开提交差异"].tap()
        XCTAssertTrue(app.staticTexts["仅显示本次提交的变化"].waitForExistence(timeout: 10))
        var report = sourceReport(app)
        XCTAssertEqual(Int(report["offset"] ?? "-999"), 0, "A long patch must open at the start of each line")
        setSwitch(app, label: "显示空白（· 空格 / ⇥ Tab）", enabled: false)
        report = sourceReport(app)
        XCTAssertEqual(Int(report["offset"] ?? "-999"), 0, "Reformatting whitespace must retain the leading origin")
        keepScreenshot(app, name: "long-patch-leading")
    }

    func testRecordedCommitPatchStartsAtLeadingEdgeAfterReopening() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-patch-style-preview", "-recorded-patch-style-preview"]
        app.launch()
        app.buttons["打开提交差异"].tap()
        XCTAssertTrue(app.staticTexts["仅显示本次提交的变化"].waitForExistence(timeout: 10))
        var report = sourceReport(app)
        XCTAssertEqual(Int(report["offset"] ?? "-999"), 0)
        app.scrollViews.firstMatch.swipeLeft()
        report = sourceReport(app)
        XCTAssertGreaterThan(Int(report["offset"] ?? "0") ?? 0, 0)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["打开提交差异"].tap()
        XCTAssertTrue(app.staticTexts["仅显示本次提交的变化"].waitForExistence(timeout: 10))
        report = sourceReport(app)
        XCTAssertEqual(Int(report["offset"] ?? "-999"), 0, "Reopening a real commit file must start from its leading edge")
        keepScreenshot(app, name: "recorded-patch-leading")
    }

    func testWorkflowStepOpensActualOutputInline() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-workflow-log-style-preview"]
        app.launch()
        let step = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Test build output")).firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 10))
        step.tap()
        let text = app.textViews["代码正文"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue((text.value as? String ?? "").contains("中文构建失败详情"))
        XCTAssertFalse(app.staticTexts["完整输出见任务日志"].exists)
        keepScreenshot(app, name: "workflow-step-output")
        app.buttons["全屏查看此步骤日志"].tap()
        XCTAssertTrue(app.textViews["代码正文"].waitForExistence(timeout: 10))
        XCTAssertTrue((app.textViews["代码正文"].value as? String ?? "").contains("完整步骤输出已在 App 内显示"))
    }
    func testPatchHighlightAndRawHorizontalScrolling() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-patch-style-preview"]
        app.launch()
        app.buttons["打开提交差异"].tap()
        for mode in ["highlight", "raw"] {
            let line = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "AFTER_TAIL")).firstMatch
            XCTAssertTrue(line.waitForExistence(timeout: 10))
            var report = sourceReport(app)
            XCTAssertGreaterThan(Int(report["width"] ?? "0") ?? 0, Int(report["viewport"] ?? "0") ?? 0)
            XCTAssertEqual(Int(report["offset"] ?? "-999"), 0)
            keepScreenshot(app, name: "patch-" + mode + "-left")
            for _ in 0..<8 {
                let offset = Int(report["offset"] ?? "0") ?? 0
                let remaining = (Int(report["width"] ?? "0") ?? 0) - (Int(report["viewport"] ?? "0") ?? 0) - offset
                if remaining <= 10 { break }
                let y = line.frame.midY / app.frame.height
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: y)).press(forDuration: 0.05,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: y)))
                report = sourceReport(app)
            }
            XCTAssertGreaterThan(Int(report["offset"] ?? "0") ?? 0, 0)
            XCTAssertLessThanOrEqual((Int(report["width"] ?? "0") ?? 0) - (Int(report["viewport"] ?? "0") ?? 0) - (Int(report["offset"] ?? "0") ?? 0), 10)
            keepScreenshot(app, name: "patch-" + mode + "-right")
            if mode == "highlight" { setSwitch(app, label: "原始 patch", enabled: true) }
        }
    }

    func testSourcePreviewAndEditorHorizontalScrolling() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-source-style-preview"]
        app.launch()
        for (mode, editable) in [("preview", "0"), ("editor", "1")] {
            let code = app.textViews["代码正文"]
            XCTAssertTrue(code.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["自动换行"].exists)
            XCTAssertFalse(app.buttons["取消换行"].exists)
            let original = code.value as? String
            var report = sourceReport(app)
            XCTAssertEqual(report["editable"], editable)
            XCTAssertGreaterThan(Int(report["width"] ?? "0") ?? 0, Int(report["viewport"] ?? "0") ?? 0)
            XCTAssertEqual(report["tail"], "0")
            XCTAssertEqual(report["fragments"], "3", "Each hard line must remain one visual line")
            XCTAssertEqual(report["hardLines"], "3")
            let gutterX = report["gutterX"], gutterWidth = report["gutterWidth"]
            keepScreenshot(app, name: "source-" + mode + "-left")
            for _ in 0..<8 {
                if report["tail"] == "1" { break }
                let viewport = app.scrollViews["代码横向滚动"].frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.maxX - 20, dy: viewport.minY + 50))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.minX + 20, dy: viewport.minY + 50)))
                report = sourceReport(app)
            }
            XCTAssertEqual(report["tail"], "1", "A real horizontal gesture must bring the tail glyph into view")
            assertTailIsRendered(app, report: report)
            XCTAssertGreaterThan(Int(report["offset"] ?? "0") ?? 0, 0)
            XCTAssertEqual(report["fragments"], "3")
            XCTAssertEqual(report["gutterX"], gutterX)
            XCTAssertEqual(report["gutterWidth"], gutterWidth)
            XCTAssertEqual(code.value as? String, original, "Scrolling must preserve hard newlines and content")
            keepScreenshot(app, name: "source-" + mode + "-right")
            for _ in 0..<8 {
                if (Int(report["offset"] ?? "0") ?? 0) <= 0 { break }
                let viewport = app.scrollViews["代码横向滚动"].frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.minX + 20, dy: viewport.minY + 50))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.maxX - 20, dy: viewport.minY + 50)))
                report = sourceReport(app)
            }
            XCTAssertLessThanOrEqual(Int(report["offset"] ?? "999") ?? 999, 0)
            XCTAssertEqual(report["gutterX"], gutterX)
            if mode == "preview" { app.buttons["切换到编辑"].tap() }
        }
    }

    private func setSwitch(_ app: XCUIApplication, label: String, enabled: Bool) {
        let control = app.switches[label]
        let expected = enabled ? "1" : "0"
        if control.value as? String != expected {
            // SwiftUI exposes the label row as a switch too. Tap the native
            // thumb instead of the row center, which can be noninteractive.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        }
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: control)], timeout: 5) == .completed, "The actual switch must change state")
    }

    private func sourceReport(_ app: XCUIApplication) -> [String: String] {
        let report = app.staticTexts["source-layout-report"]
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        let previous = report.label
        app.buttons["检查代码布局"].tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in report.label != previous }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        return Dictionary(uniqueKeysWithValues: report.label.split(separator: "|").compactMap { field in
            let pair = field.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        })
    }

    private func assertTailIsRendered(_ app: XCUIApplication, report: [String: String]) {
        guard let image = app.screenshot().image.cgImage else { XCTFail("Missing screen image"); return }
        let scale = CGFloat(image.width) / app.frame.width
        func value(_ key: String) -> CGFloat { CGFloat(Int(report[key] ?? "0") ?? 0) }
        let region = CGRect(x: value("tailX") * scale, y: value("tailY") * scale,
                            width: value("tailWidth") * scale, height: value("tailHeight") * scale).integral
        guard let crop = image.cropping(to: region), crop.width > 0, crop.height > 0 else { XCTFail("Tail is outside the actual screenshot"); return }
        var pixels = [UInt8](repeating: 255, count: crop.width * crop.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(crop.width), height: CGFloat(crop.height)))
        }
        let ink = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 220 || pixels[$0 + 1] < 220 || pixels[$0 + 2] < 220 }.count
        XCTAssertGreaterThan(ink, 20, "The tail must be drawn on screen, not only have a visible TextKit rectangle")
    }

    func testLocalHistoryCommitDetailAndFolding() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-local-git-style-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["没有可比较的远端分支"].waitForExistence(timeout: 15))

        let disclosure = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "本地提交历史")).firstMatch
        reveal(disclosure, in: app)
        XCTAssertEqual(disclosure.value as? String, "已折叠")
        keepScreenshot(app, name: "local-history-collapsed")
        disclosure.tap()
        XCTAssertEqual(disclosure.value as? String, "已展开")
        let latest = app.staticTexts["新增 Python 输出"]
        reveal(latest, in: app)
        keepScreenshot(app, name: "local-history-expanded")
        latest.tap()

        // Require decoded native values, not only a pushed navigation title.
        let file = app.staticTexts["示例.py"]
        XCTAssertTrue(file.waitForExistence(timeout: 15), "Native commit JSON must decode into the shipping Swift model")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "新增 Python 输出")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["+1  −1"].exists)
        XCTAssertFalse(app.buttons["重试"].exists)
        keepScreenshot(app, name: "local-commit-detail")
        file.tap()
        XCTAssertTrue(app.staticTexts["仅显示本次提交的变化"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["print(\"before\")"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["print(\"after\")"].exists)
        keepScreenshot(app, name: "local-commit-patch")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let collapse = app.buttons["收起提交记录"]
        reveal(collapse, in: app)
        collapse.tap()
        XCTAssertFalse(latest.exists)
        reveal(disclosure, in: app)
        XCTAssertEqual(disclosure.value as? String, "已折叠")
        for _ in 0..<3 {
            disclosure.tap()
            XCTAssertTrue(latest.waitForExistence(timeout: 5))
            XCTAssertEqual(disclosure.value as? String, "已展开")
            disclosure.tap()
            XCTAssertFalse(latest.exists, "Collapsed history must leave no detached commit rows")
            XCTAssertFalse(collapse.exists)
            XCTAssertEqual(disclosure.value as? String, "已折叠")
        }
        keepScreenshot(app, name: "local-history-after-folding")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        XCTAssertTrue(element.isHittable)
    }

    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testReadmeBadgesAndInAppLink() {
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-readme-style-preview"]
        app.launch()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 15))
        XCTAssertTrue(web.images["累计下载次数"].waitForExistence(timeout: 10))
        XCTAssertTrue(web.images["最新版本"].waitForExistence(timeout: 10))
        XCTAssertLessThan(web.frame.height, 750, "Short README must not grow to the viewport/inline height cap")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "readme-badges"; attachment.lifetime = .keepAlways; add(attachment)
        web.links["在 App 内打开仓库"].tap()
        XCTAssertTrue(app.staticTexts["readme-link-opened"].waitForExistence(timeout: 5))
    }
    func testNativeSwipeBoundaries() {
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-swipe-style-preview"]
        app.launch()
        for id in ["first", "middle", "last"] {
            let row = app.buttons["row-" + id]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.swipeLeft()
            XCTAssertTrue(app.buttons["删除"].firstMatch.waitForExistence(timeout: 5))
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "swipe-" + id
            attachment.lifetime = .keepAlways
            add(attachment)
            row.swipeRight()
        }
    }
}
