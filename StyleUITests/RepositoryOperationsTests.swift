import XCTest
import UIKit

final class RepositoryOperationsTests: XCTestCase {
    func testRepositoryActionsRowShowsLatestRunAndReusesRunningBadge() {
        let app = launch(["-repository-workflow-row-preview"])
        app.buttons["fixture-open-community"].tap()
        let row = app.buttons["repository-actions"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        waitForLabel(row, containing: "运行中")
        XCTAssertFalse(row.label.contains("失败"), "Use the first all-branch run, not the old main-branch result")
        let motion = app.staticTexts["fixture-workflow-motion"].label
        XCTAssertTrue(["动效开启", "动效关闭"].contains(motion))
        let initial = row.screenshot()
        guard let image = initial.image.cgImage else { return XCTFail("Missing production row pixels") }
        let iconRect = runningIconRect(image)
        let scale = CGFloat(image.width) / row.frame.width
        if motion == "动效开启" {
            XCTAssertEqual(iconRect.width / scale, 14, accuracy: 2, "Sample the existing 14pt badge, not the Actions icon or title")
        }
        var samples: [Data] = []
        for index in 0..<3 {
            let sample = index == 0 ? initial : row.screenshot()
            guard let crop = sample.image.cgImage?.cropping(to: iconRect) else { return XCTFail("Missing fixed badge crop") }
            samples.append(Data(rgba(crop)))
            let attachment = XCTAttachment(image: UIImage(cgImage: crop))
            attachment.name = "repository-actions-running-frame-\(index)"; attachment.lifetime = .keepAlways; add(attachment)
            let advanced = expectation(description: "Native running badge advances")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { advanced.fulfill() }
            wait(for: [advanced], timeout: 2)
        }
        if motion == "动效开启" {
            XCTAssertGreaterThan(Set(samples).count, 1, "The real production badge must animate, not show a static copied icon")
        } else { XCTAssertEqual(Set(samples).count, 1, "Reduce Motion must retain the shared static symbol") }
        let first = [UInt8](samples[0]), width = Int(iconRect.width), height = Int(iconRect.height)
        var changedArcPixels = 0, changedCenterPixels = 0
        for sample in samples.dropFirst() {
            let bytes = [UInt8](sample)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let delta = (0..<3).map { abs(Int(bytes[offset + $0]) - Int(first[offset + $0])) }.max()!
                    let radius = hypot(Double(x) - Double(width - 1) / 2, Double(y) - Double(height - 1) / 2)
                    if delta > 8 {
                        if radius < Double(width) * 0.15 { changedCenterPixels += 1 }
                        if radius > Double(width) * 0.32 { changedArcPixels += 1 }
                    }
                }
            }
        }
        XCTAssertEqual(changedCenterPixels, 0, "The center dot must remain still")
        if motion == "动效开启" {
            XCTAssertGreaterThan(changedArcPixels, 0, "Only sampling the fixed icon crop must still detect the moving outer arc")
        } else { XCTAssertEqual(changedArcPixels, 0) }
        screenshot(app, "repository-actions-row-running")
        app.buttons["模拟最近运行完成"].tap()
        waitForLabel(row, containing: "成功", timeout: 25)
        screenshot(app, "repository-actions-row-completed")
        XCTAssertTrue(row.isEnabled && row.isHittable)
        row.tap()
        XCTAssertTrue(app.navigationBars["Actions"].waitForExistence(timeout: 10))
    }

    func testRepositoryActionsRowWithoutRunsStillNavigates() {
        let app = launch(["-repository-workflow-row-empty-preview"])
        app.buttons["fixture-open-community"].tap()
        let row = app.buttons["repository-actions"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(row.label.contains("成功"))
        XCTAssertFalse(app.descendants(matching: .any)["repository-workflow-status"].firstMatch.exists)
        row.tap()
        XCTAssertTrue(app.navigationBars["Actions"].waitForExistence(timeout: 10))
    }

    func testActionsManualRefreshRetainsFailuresAndAutomaticallyFollowsTheSameRun() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-workflow-selection-style-preview", "-workflow-refresh-preview"]
        app.launch()
        let run = app.buttons["workflow-run-3"]
        XCTAssertTrue(run.waitForExistence(timeout: 15))
        waitForLabel(run, containing: "等待运行")
        // Selection pauses automatic polling, so the next read is the real manual refresh.
        chooseWorkflowAction("多选", in: app)
        app.buttons["模拟运行中"].tap(); chooseWorkflowAction("刷新", in: app)
        waitForLabel(run, containing: "运行中")
        chooseWorkflowAction("完成", in: app)
        app.buttons["模拟刷新失败"].tap(); chooseWorkflowAction("刷新", in: app)
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "模拟刷新失败")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(run.label.contains("运行中"), "Refresh failure must not clear the previously loaded run")
        app.buttons["模拟完成"].tap()
        waitForLabel(run, containing: "成功", timeout: 25)
        XCTAssertFalse(error.exists)
        screenshot(app, "workflow-refresh-preserves-and-updates")
    }
    func testVersionGroupsPreviewTheirFinalSnapshotsWithoutWriting() {
        let app = launch()
        app.buttons["fixture-open-history"].tap()
        let base = app.buttons["history-cleanup-" + String(repeating: "a", count: 40)]
        XCTAssertTrue(base.waitForExistence(timeout: 15))
        app.buttons["历史整理操作"].tap()
        app.buttons["整理方式"].tap()
        app.buttons["按版本整理"].tap()
        reveal(base, app: app); base.tap()
        let add = app.buttons["history-version-add"]
        reveal(add, app: app, upward: false); add.tap()
        fill(app.textFields.matching(NSPredicate(format: "label == %@", "第1版版本号")).firstMatch, with: "6.0", app: app, upward: false)
        fill(app.textViews.matching(NSPredicate(format: "label == %@", "第1版更新要点")).firstMatch, with: "- Keep the final feature", app: app)
        reveal(add, app: app); add.tap()
        fill(app.textFields.matching(NSPredicate(format: "label == %@", "第2版版本号")).firstMatch, with: "6.1", app: app, upward: false)
        fill(app.textViews.matching(NSPredicate(format: "label == %@", "第2版更新要点")).firstMatch, with: "- Fix the final issue", app: app)
        let select = app.buttons.matching(NSPredicate(format: "label == %@", "第1版选择最终快照")).firstMatch
        reveal(select, app: app, upward: false); select.tap()
        let first = app.buttons["history-cleanup-" + String(repeating: "b", count: 40)]
        reveal(first, app: app); first.tap()
        let preview = app.buttons["history-version-preview"]
        reveal(preview, app: app); preview.tap()
        let heading = app.staticTexts["按版本整理预览"]
        reveal(heading, app: app)
        XCTAssertTrue(heading.exists)
        for note in ["- Keep the final feature", "- Fix the final issue"] {
            let text = app.staticTexts[note]; reveal(text, app: app); XCTAssertTrue(text.exists)
        }
        screenshot(app, "remote-version-history-preview")
        let confirm = app.buttons["history-cleanup-confirm"]
        reveal(confirm, app: app); confirm.tap()
        XCTAssertTrue(app.buttons["确认整理"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertEqual(app.staticTexts["fixture-repository-writes"].label, "写入请求：0")
    }

    func testThreePullRequestMergeMethodsFreezeTheSelectedPreviewAndCanCancel() {
        let app = launch()
        app.buttons["fixture-open-pr-merge"].tap()
        let method = app.buttons["pr-merge-method"]
        XCTAssertTrue(method.waitForExistence(timeout: 15))
        for title in ["普通合并", "压缩合并", "Rebase 合并"] {
            method.tap(); app.buttons["合并方式"].tap()
            for allowed in ["普通合并", "压缩合并", "Rebase 合并"] { XCTAssertTrue(app.buttons[allowed].isEnabled) }
            if title == "压缩合并" { screenshot(app, "pr-three-merge-methods-native-menu") }
            app.buttons[title].tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", title), object: method)], timeout: 5), .completed)
            if title == "Rebase 合并" { XCTAssertFalse(app.textFields["提交标题（留空使用GitHub默认）"].exists) }
            app.buttons["pr-merge-preview"].tap()
            XCTAssertTrue(app.buttons["确认" + title].waitForExistence(timeout: 5))
            app.buttons["取消"].tap()
            XCTAssertEqual(app.staticTexts["fixture-repository-writes"].label, "写入请求：0")
        }
    }

    func testBlockedPullRequestExplainsTheGateAndDoesNotOfferAMerge() {
        let app = launch(["-pr-merge-blocked-preview"])
        app.buttons["fixture-open-pr-merge"].tap()
        let preview = app.buttons["pr-merge-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        XCTAssertFalse(preview.isEnabled)
        let reason = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "GitHub尚未允许合并（BLOCKED）")).firstMatch
        reveal(reason, app: app); XCTAssertTrue(reason.exists)
        screenshot(app, "pr-merge-blocked-reason")
        XCTAssertEqual(app.staticTexts["fixture-repository-writes"].label, "写入请求：0")
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-repository-operations-style-preview"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["fixture-open-history"].waitForExistence(timeout: 15))
        return app
    }
    private func runningIconRect(_ image: CGImage) -> CGRect {
        let bytes = rgba(image)
        var xs: [Int] = [], ys: [Int] = []
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                // The real light-theme attention badge; excludes the orange feature icon and neutral text.
                if r < 245 && r - g > 10 && g - b > 20 { xs.append(x); ys.append(y) }
            }
        }
        guard let left = xs.min(), let right = xs.max(), let top = ys.min(), let bottom = ys.max() else {
            XCTFail("The production running badge must paint yellow pixels"); return .zero
        }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 10) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)], timeout: timeout), .completed)
    }
    private func waitForEnabled(_ element: XCUIElement) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)], timeout: 10), .completed)
    }
    private func fill(_ field: XCUIElement, with value: String, app: XCUIApplication, upward: Bool = true) {
        reveal(field, app: app, upward: upward); field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText(value)
        app.buttons["完成输入"].tap()
        XCTAssertEqual(field.value as? String, value)
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<10 where !element.isHittable {
            if upward { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.exists); XCTAssertTrue(element.isHittable)
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
