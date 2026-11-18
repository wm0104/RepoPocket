import XCTest
import CoreGraphics

extension XCTestCase {
    /// Select Safari's native close control and tap its explicit center once.
    func tapNativeSafariDone(_ app: XCUIApplication,
                             failureNames: (screenshot: String, hierarchy: String) = ("settings-state-timeout", "settings-state-timeout-ax"),
                             beforeTap: () -> Void = {}, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement? {
        var trace = ["Native Safari Done center hit target"]
        func fail(_ message: String) -> XCUIElement? {
            let details = (trace + [message, app.debugDescription]).joined(separator: "\n")
            print(details)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = failureNames.screenshot; screenshot.lifetime = .keepAlways; add(screenshot)
            let hierarchy = XCTAttachment(string: details)
            hierarchy.name = failureNames.hierarchy; hierarchy.lifetime = .keepAlways; add(hierarchy)
            XCTFail(message, file: file, line: line)
            return nil
        }
        let bars = app.otherElements.matching(identifier: "TopBrowserBar")
        let bar = bars.firstMatch
        guard bar.waitForExistence(timeout: 10), bars.count == 1 else { return fail("Expected one native TopBrowserBar") }
        let buttons = bar.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成"]))
        let done = buttons.firstMatch
        guard done.waitForExistence(timeout: 10), buttons.count == 1 else { return fail("Expected one native Safari Done button inside TopBrowserBar") }
        guard done.exists, done.isEnabled, done.isHittable else { return fail("Native Safari Done must exist, be enabled and hittable") }
        beforeTap()
        let doneFrame = done.frame, barFrame = bar.frame, viewport = app.frame
        trace.append("Done=\(doneFrame); bar=\(barFrame); viewport=\(viewport)")
        let frames = [doneFrame, barFrame, viewport]
        guard frames.allSatisfy({ !$0.isNull && !$0.isInfinite && !$0.isEmpty &&
            [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy { $0.isFinite } }),
              barFrame.contains(doneFrame), viewport.contains(doneFrame) else {
            return fail("Native Safari Done must have a finite frame fully visible inside its bar and viewport")
        }
        trace.append("One native Done tap at normalized center (0.5, 0.5)")
        print(trace.joined(separator: "\n"))
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return done
    }
}
