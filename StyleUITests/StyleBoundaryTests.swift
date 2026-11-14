import XCTest

final class StyleBoundaryTests: XCTestCase {
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
