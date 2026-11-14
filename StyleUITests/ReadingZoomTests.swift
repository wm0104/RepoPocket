import XCTest
import UIKit

final class ReadingZoomTests: XCTestCase {
    func testHTMLPageZoomChangesContentWithoutReloadingOrResettingScroll() {
        let app = launch()
        app.buttons["HTML 正文"].tap()
        let ready = app.staticTexts["reading-zoom-report"]
        XCTAssertTrue(ready.waitForExistence(timeout: 10))
        // Hosted WebContent cold starts measured 30s; wait for native readiness before querying its AX tree.
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "loads=1|"), object: ready)], timeout: 60), .completed)
        let navigation = app.navigationBars.firstMatch.frame
        let controls = app.buttons["content-zoom-in"].frame
        let web = app.webViews["reading-zoom-web"]
        let sentinel = web.staticTexts["ZOOM_SENTINEL"]
        let bodySentinel = web.staticTexts["BODY_SENTINEL"]
        XCTAssertTrue(sentinel.waitForExistence(timeout: 10))
        XCTAssertEqual(web.staticTexts.matching(identifier: "ZOOM_SENTINEL").count, 1)
        let baseline = stableFrame(sentinel)
        let bodyBaseline = stableFrame(bodySentinel)
        let baselineInk = glyphSize(app, within: baseline)
        let baselineReport = report(app)
        XCTAssertNil(baselineReport["domError"])
        screenshot(app, "readme-zoom-100")
        web.swipeUp()
        XCTAssertGreaterThan(number(report(app), "offset"), 0)
        web.pinch(withScale: 1.4, velocity: 1)
        let pinched = report(app)
        XCTAssertGreaterThan(number(pinched, "zoom"), 1.15, "Pinch report: \(pinched)")
        XCTAssertEqual(pinched["loads"], "1")
        XCTAssertGreaterThan(number(pinched, "offset"), 0)
        XCTAssertEqual(app.buttons["content-zoom-reset"].value as? String, "\(Int((number(pinched, "zoom") * 100).rounded()))%")
        XCTAssertEqual(app.navigationBars.firstMatch.frame, navigation)
        XCTAssertEqual(app.buttons["content-zoom-in"].frame, controls)
        app.buttons["content-zoom-reset"].tap()
        for _ in 0..<10 { app.buttons["content-zoom-in"].tap() }
        let enlarged = report(app)
        XCTAssertEqual(number(enlarged, "zoom"), 2, accuracy: 0.001)
        XCTAssertEqual(number(enlarged, "pageZoom"), 1, accuracy: 0.001)
        XCTAssertEqual(number(enlarged, "scrollZoom"), 1, accuracy: 0.001)
        XCTAssertEqual(enlarged["fontSize"], baselineReport["fontSize"])
        XCTAssertEqual(enlarged["loads"], "1")
        XCTAssertNil(enlarged["domError"])
        XCTAssertGreaterThan(number(enlarged, "offset"), 0)
        reveal(sentinel, in: web)
        let visibleEnlarged = report(app)
        XCTAssertEqual(number(visibleEnlarged, "zoom"), 2, accuracy: 0.001, "Scrolling or a diagnostic layout update must not reset the actual content scale")
        let geometry = XCTAttachment(string: "baseline=\(baseline)|report=\(baselineReport)\nenlarged=\(sentinel.frame)|report=\(enlarged)\nvisible=\(visibleEnlarged)")
        geometry.name = "readme-zoom-native-dom-ax"; geometry.lifetime = .keepAlways
        add(geometry)
        screenshot(app, "readme-zoom-200-before-size-check")
        let enlargedText = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            sentinel.frame.width > baseline.width * 1.8 && sentinel.frame.height > baseline.height * 1.8
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [enlargedText], timeout: 10), .completed)
        let enlargedFrame = stableFrame(sentinel)
        let enlargedInk = glyphSize(app, within: enlargedFrame)
        XCTAssertEqual(sentinel.label, "ZOOM_SENTINEL")
        XCTAssertEqual(enlargedFrame.width, baseline.width * 2, accuracy: 1)
        // Font ascent/descent round independently at each size; verify its actual DOM box projection.
        XCTAssertEqual(enlargedFrame.height, number(visibleEnlarged, "domHeight") * 2, accuracy: 1)
        XCTAssertEqual(enlargedInk.width, baselineInk.width * 2, accuracy: 1)
        XCTAssertEqual(enlargedInk.height, baselineInk.height * 2, accuracy: 1)
        XCTAssertGreaterThan(bodySentinel.frame.width, bodyBaseline.width * 1.8)
        XCTAssertGreaterThan(bodySentinel.frame.height, bodyBaseline.height * 1.8)
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
        let resetInk = glyphSize(app, within: resetFrame)
        XCTAssertEqual(sentinel.label, "ZOOM_SENTINEL")
        XCTAssertEqual(resetFrame.width, baseline.width, accuracy: 1)
        XCTAssertEqual(resetFrame.height, baseline.height, accuracy: 1)
        XCTAssertEqual(resetInk.width, baselineInk.width, accuracy: 1)
        XCTAssertEqual(resetInk.height, baselineInk.height, accuracy: 1)
        XCTAssertEqual(bodySentinel.frame.width, bodyBaseline.width, accuracy: 1)
        XCTAssertEqual(bodySentinel.frame.height, bodyBaseline.height, accuracy: 1)
        XCTAssertEqual(app.navigationBars.firstMatch.frame, navigation)
        XCTAssertEqual(app.buttons["content-zoom-in"].frame, controls)
        for _ in 0..<4 { app.buttons["content-zoom-out"].tap() }
        let reduced = report(app)
        XCTAssertEqual(number(reduced, "zoom"), 0.6, accuracy: 0.001)
        XCTAssertEqual(number(reduced, "pageZoom"), 1, accuracy: 0.001)
        XCTAssertEqual(number(reduced, "scrollZoom"), 1, accuracy: 0.001)
        XCTAssertEqual(reduced["loads"], "1")
        reveal(sentinel, in: web)
        let reducedFrame = stableFrame(sentinel)
        let reducedInk = glyphSize(app, within: reducedFrame)
        XCTAssertEqual(reducedFrame.width, baseline.width * 0.6, accuracy: 1)
        // AX text bounds include line metrics; measure the actual painted glyphs instead.
        XCTAssertEqual(reducedInk.width, baselineInk.width * 0.6, accuracy: 1)
        XCTAssertEqual(reducedInk.height, baselineInk.height * 0.6, accuracy: 1)
        XCTAssertLessThan(bodySentinel.frame.width, bodyBaseline.width * 0.7)
        XCTAssertLessThan(bodySentinel.frame.height, bodyBaseline.height * 0.75)
        XCTAssertEqual(app.navigationBars.firstMatch.frame, navigation)
        XCTAssertEqual(app.buttons["content-zoom-in"].frame, controls)
        let ink = XCTAttachment(string: "100%=\(baselineInk)|200%=\(enlargedInk)|reset=\(resetInk)|60%=\(reducedInk)|AX60%=\(reducedFrame)|report=\(reduced)")
        ink.name = "readme-zoom-painted-glyphs"; ink.lifetime = .keepAlways
        add(ink)
        screenshot(app, "readme-zoom-60")
        web.pinch(withScale: 1.5, velocity: 1)
        XCTAssertGreaterThan(number(report(app), "zoom"), 0.65)
        web.pinch(withScale: 0.5, velocity: -1)
        XCTAssertEqual(number(report(app), "zoom"), 0.6, accuracy: 0.02)
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
        let original = text.label
        let done = app.navigationBars["正文"].buttons["完成"]
        let doneFrame = done.frame
        text.pinch(withScale: 1.4, velocity: 1)
        let pinched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in text.frame.height > baseline * 1.1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pinched], timeout: 5), .completed)
        XCTAssertNotEqual(reader.buttons["content-zoom-reset"].value as? String, "100%")
        XCTAssertEqual(text.label, original)
        XCTAssertEqual(done.frame, doneFrame)
        reader.buttons["content-zoom-reset"].tap()
        for _ in 0..<10 { reader.buttons["content-zoom-in"].tap() }
        XCTAssertEqual(reader.buttons["content-zoom-reset"].value as? String, "200%")
        XCTAssertGreaterThan(text.frame.height, baseline * 1.5)
        XCTAssertEqual(text.label, original)
        XCTAssertEqual(done.frame, doneFrame)
        screenshot(app, "markdown-reader-zoom-200")
        reader.buttons["content-zoom-reset"].tap()
        XCTAssertEqual(reader.buttons["content-zoom-reset"].value as? String, "100%")
        XCTAssertEqual(text.frame.height, baseline, accuracy: 0.5)
        XCTAssertEqual(text.label, original)
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
    private func glyphSize(_ app: XCUIApplication, within frame: CGRect) -> CGSize {
        guard let image = app.screenshot().image.cgImage else { XCTFail("Missing screenshot"); return .zero }
        let sx = CGFloat(image.width) / app.frame.width, sy = CGFloat(image.height) / app.frame.height
        let bounds = frame.insetBy(dx: -1, dy: -1)
        let region = CGRect(x: bounds.minX * sx, y: bounds.minY * sy, width: bounds.width * sx, height: bounds.height * sy).integral
        guard let crop = image.cropping(to: region) else { XCTFail("Glyphs are outside the actual screenshot"); return .zero }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        let background = pixels.prefix(3).map(Int.init)
        var left = crop.width, right = -1, top = crop.height, bottom = -1
        for y in 0..<crop.height {
            for x in 0..<crop.width {
                let offset = (y * crop.width + x) * 4
                let contrast = (0..<3).reduce(0) { $0 + abs(Int(pixels[offset + $1]) - background[$1]) }
                if contrast > 240 {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
        }
        guard right >= left, bottom >= top else { XCTFail("No visible glyph pixels in the actual screenshot"); return .zero }
        return CGSize(width: CGFloat(right - left + 1) / sx, height: CGFloat(bottom - top + 1) / sy)
    }
    private func number(_ report: [String: String], _ key: String) -> Double { Double(report[key] ?? "") ?? 0 }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
