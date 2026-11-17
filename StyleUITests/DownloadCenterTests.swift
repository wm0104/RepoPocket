import XCTest
import UIKit

final class DownloadCenterTests: XCTestCase {
    func testCompletedFilesAndInterruptedRecordsRemainAfterRelaunch() {
        let app = launch()
        XCTAssertTrue(app.buttons["插件.deb"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["应用.tipa"].exists)
        XCTAssertTrue(app.staticTexts["已中断，点重试重新下载"].exists)
        XCTAssertTrue(app.buttons["重试"].exists)
        for name in ["插件.deb", "应用.tipa"] {
            let completed = waitForFileReady(in: app, name: name)
            XCTAssertEqual(completed.label, name, "Completed rows show only the filename")
            XCTAssertEqual(completed.value as? String, "已完成，13 字节", "VoiceOver retains completion and the actual local byte count")
            let size = completed.staticTexts["13 字节"], filename = completed.staticTexts[name]
            XCTAssertTrue(size.exists)
            XCTAssertTrue(filename.exists)
            XCTAssertFalse(size.frame.isEmpty)
            XCTAssertTrue(completed.frame.contains(size.frame), "Visible size stays inside its completed file row")
            assertVisibleCompletedFileText(app, filename: filename, size: size, row: completed)
            XCTAssertGreaterThanOrEqual(completed.frame.height, 44, "Compact rows keep a tappable target")
            let cell = app.cells.containing(.button, identifier: name).firstMatch
            XCTAssertTrue(cell.exists)
            XCTAssertLessThanOrEqual(cell.frame.height, 56, "Short completed rows must lose the previous 66pt padding")
        }
        XCTAssertFalse(app.staticTexts["已完成"].exists)
        XCTAssertFalse(app.staticTexts["fixture/download"].exists)
        screenshot(app, "download-center-records")
        app.terminate()
        app.launchArguments.append("-download-keep-history")
        app.launch()
        let persisted = waitForFileReady(in: app, name: "插件.deb")
        XCTAssertEqual(persisted.value as? String, "已完成，13 字节")
        XCTAssertTrue(app.staticTexts["已中断，点重试重新下载"].exists)
        app.buttons["切换账号"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "暂无下载。")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["插件.deb"].exists)
    }

    func testCompletedPreviewClosesReopensAndShareCancelKeepsRecord() {
        let app = launch()
        let file = waitForFileReady(in: app, name: "插件.deb")
        let identifier = file.identifier, label = file.label
        let records = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "download-record-"))
        let count = records.count
        let done = app.buttons["download-preview-done"]
        file.tap()
        waitForButton(done, in: app)
        XCTAssertEqual(app.navigationBars.containing(.button, identifier: "download-preview-done").count, 1)
        screenshot(app, "download-preview-native-done")
        done.tap()
        let returned = waitForFileReady(in: app, name: "插件.deb", context: "dismiss")
        XCTAssertEqual(returned.identifier, identifier)
        XCTAssertFalse(done.exists)
        XCTAssertTrue(app.navigationBars["下载中心"].exists)
        screenshot(app, "download-preview-returned-to-center")

        // Reopening goes through the production store.file check again, not a fake preview.
        returned.tap()
        waitForButton(done, in: app)
        done.tap()
        let reopened = waitForFileReady(in: app, name: "插件.deb", context: "dismiss")
        XCTAssertEqual(reopened.label, label)
        XCTAssertEqual(records.count, count)

        openFileMenu(in: app, row: reopened, action: "分享")
        app.buttons["分享"].tap()
        let cancelShare = app.buttons.matching(NSPredicate(format:
            "identifier == 'Close' OR label IN {'Close', '关闭', 'Cancel', '取消'}")).firstMatch
        waitForButton(cancelShare, in: app)
        screenshot(app, "download-preview-share-cancel")
        cancelShare.tap()
        let shared = waitForFileReady(in: app, name: "插件.deb", context: "dismiss")
        XCTAssertEqual(shared.identifier, identifier)
        XCTAssertEqual(shared.label, label)
        XCTAssertEqual(records.count, count)

        shared.tap()
        waitForButton(done, in: app)
        // Interactive dismissal must succeed without tapping Done.
        let previewBar = app.navigationBars.containing(.button, identifier: "download-preview-done").firstMatch
        let start = previewBar.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: done)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed,
                       "The downward gesture must dismiss Quick Look without a Done fallback")
        let dismissedFile = waitForFileReady(in: app, name: "插件.deb", context: "dismiss")
        XCTAssertFalse(done.exists)
        dismissedFile.tap()
        waitForButton(done, in: app)
        done.tap()
        _ = waitForFileReady(in: app, name: "插件.deb", context: "dismiss")

        app.terminate()
        app.launchArguments.append("-download-keep-history")
        app.launch()
        let persisted = waitForFileReady(in: app, name: "插件.deb")
        XCTAssertEqual(persisted.identifier, identifier)
        XCTAssertEqual(persisted.label, label)
        XCTAssertEqual(records.count, count)
        XCTAssertTrue(app.buttons["应用.tipa"].exists)
        XCTAssertTrue(app.staticTexts["已中断，点重试重新下载"].exists)
        persisted.tap()
        waitForButton(done, in: app)
        done.tap()
        _ = waitForFileReady(in: app, name: "插件.deb", context: "dismiss")
        screenshot(app, "download-preview-records-retained")
    }

    func testDeleteKeepsTheIndependentPendingUploadCopy() {
        let app = launch()
        let file = waitForFileReady(in: app, name: "插件.deb")
        openFileMenu(in: app, row: file, action: "加入待上传文件")
        XCTAssertFalse(app.buttons["编辑包信息"].exists)
        app.buttons["加入待上传文件"].tap()
        XCTAssertTrue(app.staticTexts["已加入待上传文件；上传时仍需选择仓库和目标位置。"].waitForExistence(timeout: 10))
        app.buttons["好"].tap()
        app.buttons["检查副本"].tap()
        XCTAssertEqual(app.staticTexts["download-audit"].label, "待上传副本存在")
        openFileMenu(in: app, row: waitForFileReady(in: app, name: "插件.deb", context: "dismiss"), action: "删除文件")
        app.buttons["删除文件"].tap()
        waitForButton(app.buttons["取消"], in: app)
        app.buttons["取消"].tap()
        let retained = waitForFileReady(in: app, name: "插件.deb", context: "dismiss")
        XCTAssertTrue(file.exists)
        openFileMenu(in: app, row: retained, action: "删除文件")
        app.buttons["删除文件"].tap()
        waitForButton(app.buttons["确认删除"], in: app)
        app.buttons["确认删除"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: file)], timeout: 5), .completed)
        app.buttons["检查副本"].tap()
        XCTAssertEqual(app.staticTexts["download-audit"].label, "待上传副本存在")
        screenshot(app, "download-center-deleted-copy-retained")
    }

    func testCompletedPackagesOnlyOfferFileActionsAndKeepOriginalOnCancel() {
        let app = launch()
        let records = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "download-record-"))
        _ = waitForFileReady(in: app, name: "插件.deb")
        let count = records.count
        for name in ["插件.deb", "应用.ipa", "应用.tipa"] {
            let file = waitForFileReady(in: app, name: name)
            let original = file.identifier, label = file.label
            file.tap()
            let done = app.buttons["download-preview-done"]
            waitForButton(done, in: app)
            done.tap()
            openFileMenu(in: app, row: waitForFileReady(in: app, name: name, context: "dismiss"), action: "分享")
            XCTAssertTrue(app.buttons["分享"].exists)
            XCTAssertTrue(app.buttons["加入待上传文件"].exists)
            XCTAssertTrue(app.buttons["删除文件"].exists)
            XCTAssertFalse(app.buttons["用 TrollStore 安装"].exists)
            XCTAssertFalse(app.staticTexts["用 TrollStore 安装？"].exists)
            XCTAssertFalse(app.otherElements["ActivityListView"].exists)
            if name == "应用.tipa" { screenshot(app, "download-center-completed-file-actions") }
            app.buttons["分享"].tap()
            let cancelShare = app.buttons.matching(NSPredicate(format:
                "identifier == 'Close' OR label IN {'Close', '关闭', 'Cancel', '取消'}")).firstMatch
            waitForButton(cancelShare, in: app)
            cancelShare.tap()
            let retained = waitForFileReady(in: app, name: name, context: "dismiss")
            XCTAssertEqual(retained.identifier, original)
            openFileMenu(in: app, row: retained, action: "删除文件")
            app.buttons["删除文件"].tap()
            waitForButton(app.buttons["取消"], in: app)
            app.buttons["取消"].tap()
            XCTAssertEqual(waitForFileReady(in: app, name: name, context: "dismiss").identifier, original)
            XCTAssertEqual(records.count, count)
            app.terminate()
            app.launchArguments.append("-download-keep-history")
            app.launch()
            let persisted = waitForFileReady(in: app, name: name)
            XCTAssertEqual(persisted.identifier, original)
            XCTAssertEqual(persisted.label, label)
            XCTAssertEqual(records.count, count)
        }
    }
    private func assertVisibleCompletedFileText(_ app: XCUIApplication, filename: XCUIElement,
                                                size: XCUIElement, row: XCUIElement) {
        let shot = app.screenshot()
        let nameFrame = filename.frame, sizeFrame = size.frame, rowFrame = row.frame, appFrame = app.frame
        var detail = "filename=\(nameFrame); size=\(sizeFrame); row=\(rowFrame); app=\(appFrame)"
        var textCrop: CGImage?
        func fail(_ reason: String) {
            var attachments = [("screen", XCTAttachment(screenshot: shot)),
                               ("frames-and-ink", XCTAttachment(string: detail + "; " + reason))]
            if let crop = textCrop { attachments.append(("crop", XCTAttachment(image: UIImage(cgImage: crop)))) }
            for (kind, attachment) in attachments {
                attachment.name = "download-text-" + kind + "-" + filename.label
                attachment.lifetime = .keepAlways; add(attachment)
            }
            XCTFail(reason + "; " + detail)
        }
        guard let image = shot.image.cgImage, !appFrame.isEmpty,
              !nameFrame.isEmpty, !sizeFrame.isEmpty else { return fail("Missing text screenshot or AX bounds") }
        let sx = CGFloat(image.width) / appFrame.width, sy = CGFloat(image.height) / appFrame.height
        // AX filename maxX includes blank layout space. Scan the WHOLE text strip,
        // including the size, so primary glyphs entering/covering the size cannot be hidden.
        let strip = CGRect(x: nameFrame.minX, y: min(nameFrame.minY, sizeFrame.minY),
                           width: sizeFrame.maxX - nameFrame.minX,
                           height: max(nameFrame.maxY, sizeFrame.maxY) - min(nameFrame.minY, sizeFrame.minY))
        guard !strip.isEmpty, rowFrame.contains(strip), appFrame.contains(strip) else {
            return fail("Text strip must be nonempty and contained in the visible row")
        }
        let region = CGRect(x: (strip.minX - appFrame.minX) * sx, y: (strip.minY - appFrame.minY) * sy,
                            width: strip.width * sx, height: strip.height * sy).integral
        guard let crop = image.cropping(to: region) else { return fail("Missing text crop") }
        textCrop = crop
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            return true
        }
        guard rendered else { return fail("Cannot read screenshot pixels") }
        let background = pixels.prefix(3).map(Int.init).reduce(0, +) / 3
        let sizeLeft = (sizeFrame.minX - appFrame.minX) * sx - region.minX
        let sizeRight = (sizeFrame.maxX - appFrame.minX) * sx - region.minX
        var primary = 0, secondary = 0, primaryRight = -1, leadingRight = -1
        var secondaryLeft = crop.width, secondaryRight = -1
        // shortcut: neutral primary/secondary text in this fixed Chinese fixture only;
        // recalibrate against screenshots before extending to other typography or RTL.
        // Real light screenshot: primary contrast 255, secondary core 128. Inversion
        // fixtures also separate at 180; 55 retains AA ink, 8pt² rejects empty/noise.
        for y in 0..<crop.height {
            for x in 0..<crop.width {
                let i = (y * crop.width + x) * 4
                let rgb = pixels[i..<(i + 3)].map(Int.init)
                let contrast = abs(rgb.reduce(0, +) / 3 - background)
                guard rgb.max()! - rgb.min()! <= 20, contrast >= 55 else { continue }
                if contrast >= 180 { primary += 1; primaryRight = max(primaryRight, x) }
                if CGFloat(x) < sizeLeft { leadingRight = max(leadingRight, x) }
                if CGFloat(x) >= sizeLeft && CGFloat(x) < sizeRight && contrast < 180 {
                    secondary += 1; secondaryLeft = min(secondaryLeft, x); secondaryRight = max(secondaryRight, x)
                }
            }
        }
        let gap = CGFloat(secondaryLeft - max(primaryRight, leadingRight) - 1) / sx
        let sizeCoverage = CGFloat(max(0, secondaryRight - secondaryLeft + 1)) / (sizeRight - sizeLeft)
        detail += "; region=\(region); sx=\(sx); sy=\(sy); background=\(background); primary=\(primary); secondary=\(secondary); primaryRight=\(primaryRight); leadingRight=\(leadingRight); secondaryX=\(secondaryLeft)...\(secondaryRight); gapPt=\(gap); sizeCoverage=\(sizeCoverage)"
        guard CGFloat(primary) >= 8 * sx * sy, CGFloat(secondary) >= 8 * sx * sy,
              sizeCoverage >= 0.6, gap >= 2 else {
            return fail("Filename and visible size must paint distinct ink with a real gap")
        }
    }

    private func openFileMenu(in app: XCUIApplication, row: XCUIElement, action: String) {
        row.press(forDuration: 1)
        waitForButton(app.buttons[action], in: app)
    }
    private func waitForButton(_ button: XCUIElement, in app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            button.exists && button.isEnabled && button.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, app.debugDescription)
    }
    private func waitForFileReady(in app: XCUIApplication, name: String, context: String = "enter") -> XCUIElement {
        // A context-preview StaticText can still exist while dismissal has no valid hit point.
        let row = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "download-record-", name)).firstMatch
        let started = Date()
        var previous = CGRect.zero, frame = CGRect.zero, appFrame = CGRect.zero
        var stableSamples = 0, blocker = "", rounds = [String]()
        func record(_ phase: String, since began: Date) {
            rounds.append("context=\(context) phase=\(phase) frame=\(frame) appFrame=\(appFrame) stableSamples=\(stableSamples) elapsed=\(Date().timeIntervalSince(started)) queryElapsed=\(Date().timeIntervalSince(began)) blocker=\(blocker)")
        }
        func rowIsUnobstructed() -> Bool {
            blocker = "quick-look"; guard !app.buttons["download-preview-done"].exists else { return false }
            blocker = "cancel"; guard !app.buttons["取消"].exists else { return false }
            blocker = "delete"; guard !app.buttons["确认删除"].exists else { return false }
            blocker = "sheet"; guard !app.sheets.firstMatch.exists else { return false }
            blocker = "alert"; guard !app.alerts.firstMatch.exists else { return false }
            blocker = "missing-row"; guard row.exists else { return false }
            blocker = "disabled-row"; guard row.isEnabled else { return false }
            blocker = "unhittable-row"; guard row.isHittable else { return false }
            blocker = ""; return true
        }
        func diagnose(_ result: XCTWaiter.Result) {
            let diagnostics = "File row readiness: \(name); context=\(context); result=\(result)\n" + rounds.joined(separator: "\n")
            if result != .completed {
                let attachment = XCTAttachment(string: diagnostics)
                attachment.name = "download-readiness-timing-and-ax"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTAssertEqual(result, .completed, diagnostics)
        }
        // Give modal dismissal/interaction readiness its own budget; do not charge its
        // serial AX queries three times against the frame sampling budget (CI saw 1–2 rounds).
        let transition = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let began = Date()
            let ready = rowIsUnobstructed()
            record("transition", since: began)
            return ready
        }, object: nil)
        let transitionResult = XCTWaiter.wait(for: [transition], timeout: 10)
        guard transitionResult == .completed else {
            diagnose(transitionResult)
            return row
        }
        let geometry = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let began = Date()
            frame = row.frame
            appFrame = app.frame
            if !frame.isEmpty && appFrame.contains(frame) {
                stableSamples = frame == previous ? stableSamples + 1 : 1
                blocker = ""
            } else {
                stableSamples = 0
                blocker = "empty-or-outside-app"
            }
            previous = frame
            record("geometry", since: began)
            guard stableSamples >= 3 else { return false }
            let verification = Date()
            // Only after three exact, contained samples, recheck every modal/hit guard.
            guard rowIsUnobstructed() else {
                stableSamples = 0; previous = .zero
                record("verify", since: verification)
                return false
            }
            let verifiedFrame = row.frame, verifiedAppFrame = app.frame
            let unchanged = verifiedFrame == frame && verifiedAppFrame.contains(verifiedFrame)
            frame = verifiedFrame; appFrame = verifiedAppFrame
            if !unchanged {
                stableSamples = 0; previous = .zero; blocker = "frame-changed-during-verification"
            }
            record("verify", since: verification)
            return unchanged
        }, object: nil)
        diagnose(XCTWaiter.wait(for: [geometry], timeout: 10))
        return row
    }
    override func tearDownWithError() throws {
        if let testRun = testRun, testRun.failureCount > 0 {
            let app = XCUIApplication()
            screenshot(app, "download-failure-" + name)
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "download-failure-ax-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        try super.tearDownWithError()
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-download-center-style-preview",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
