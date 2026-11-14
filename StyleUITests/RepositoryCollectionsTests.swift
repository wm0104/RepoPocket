import XCTest

final class RepositoryCollectionsTests: XCTestCase {
    func testHomeFavoritesPersistAcrossRestartAndStaySeparateFromStarsAndAccounts() {
        let app = launch()
        screenshot(app, "home-favorites-entry")
        app.buttons["home-collection-favorites"].tap()
        addFavorite(1, app: app)
        let first = app.buttons["favorite-repository-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        addFavorite(1, app: app)
        XCTAssertEqual(app.buttons.matching(identifier: "favorite-repository-1").count, 1)
        addFavorite(2, app: app)
        XCTAssertTrue(app.buttons["favorite-repository-2"].waitForExistence(timeout: 10))
        app.buttons["收藏夹操作"].tap(); app.buttons["管理收藏"].tap()
        screenshot(app, "favorites-native-management")
        app.buttons["收藏夹操作"].tap(); app.buttons["完成管理"].tap()
        XCTAssertEqual(app.staticTexts["collection-preview-writes"].label, "分类写入：0")
        app.terminate()
        app.launchArguments.append("-keep-collection-favorites"); app.launch()
        XCTAssertTrue(app.buttons["home-collection-favorites"].waitForExistence(timeout: 15)); app.buttons["home-collection-favorites"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        XCTAssertTrue(app.buttons["更多操作"].waitForExistence(timeout: 15)); app.buttons["更多操作"].tap()
        XCTAssertTrue(app.buttons["移出收藏夹"].waitForExistence(timeout: 5)); app.buttons["移出收藏夹"].tap()
        app.navigationBars.buttons["收藏夹"].tap()
        XCTAssertFalse(first.exists)
        XCTAssertTrue(app.buttons["favorite-repository-2"].exists)
        screenshot(app, "favorites-persisted-repositories")
        app.navigationBars.buttons["RepoPocket"].tap()
        app.buttons["切换测试账号"].tap()
        XCTAssertTrue(app.buttons["home-collection-favorites"].waitForExistence(timeout: 10)); app.buttons["home-collection-favorites"].tap()
        XCTAssertFalse(app.buttons["favorite-repository-2"].exists)
        app.navigationBars.buttons["RepoPocket"].tap(); app.buttons["切换测试账号"].tap()
        XCTAssertTrue(app.buttons["home-collection-favorites"].waitForExistence(timeout: 10)); app.buttons["home-collection-favorites"].tap()
        XCTAssertTrue(app.buttons["favorite-repository-2"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["collection-preview-writes"].label, "分类写入：0")
    }

    func testOfficialStarListsCreateRenameAddRemoveAndDeleteWithoutUnstarring() {
        let app = launch()
        app.buttons["home-collection-starred"].tap()
        XCTAssertTrue(app.buttons["star-list-all"].waitForExistence(timeout: 15))
        screenshot(app, "star-lists-official-home")
        app.buttons["Star分类操作"].tap(); app.buttons["新建分类"].tap()
        editName("Custom tools", app: app)
        let created = app.buttons["star-list-C"]
        XCTAssertTrue(created.waitForExistence(timeout: 15)); created.tap()
        XCTAssertTrue(app.buttons["分类仓库操作"].waitForExistence(timeout: 10)); app.buttons["分类仓库操作"].tap()
        app.buttons["添加已加星标的仓库"].tap()
        let item = app.buttons["star-list-add-1"]
        XCTAssertTrue(item.waitForExistence(timeout: 15)); item.tap()
        let member = app.buttons["star-list-repository-R1"]
        XCTAssertTrue(member.waitForExistence(timeout: 20))
        screenshot(app, "star-list-member-preserves-other-lists")
        member.swipeLeft(); app.buttons["移出分类"].tap()
        let confirm = app.buttons["移出分类"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: member)], timeout: 20), .completed)
        app.navigationBars.buttons["已加星标"].tap()
        app.buttons["分类操作：Custom tools"].tap(); app.buttons["重命名"].tap()
        editName("Renamed tools", app: app, replacing: "Custom tools")
        let options = app.buttons["分类操作：Renamed tools"]
        XCTAssertTrue(options.waitForExistence(timeout: 15)); options.tap(); app.buttons["删除分类"].tap()
        app.buttons["确认删除分类"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: created)], timeout: 15), .completed)
        app.buttons["star-list-B"].tap()
        XCTAssertTrue(member.waitForExistence(timeout: 15))
        app.navigationBars.buttons["已加星标"].tap(); app.buttons["star-list-all"].tap()
        XCTAssertTrue(app.buttons["collection-repository-1"].waitForExistence(timeout: 15))
        screenshot(app, "star-list-deleted-still-starred")
        XCTAssertEqual(app.staticTexts["collection-preview-writes"].label, "分类写入：5")
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-style-preview", "-repository-collections-style-preview"]; app.launch()
        XCTAssertTrue(app.buttons["home-collection-favorites"].waitForExistence(timeout: 20))
        return app
    }
    private func addFavorite(_ id: Int, app: XCUIApplication) {
        app.buttons["收藏夹操作"].tap(); app.buttons["添加收藏"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("collection-fixture\n")
        let result = app.buttons["favorite-add-\(id)"]
        XCTAssertTrue(result.waitForExistence(timeout: 15)); result.tap()
        XCTAssertTrue(app.buttons["favorite-repository-\(id)"].waitForExistence(timeout: 10))
    }
    private func editName(_ value: String, app: XCUIApplication, replacing old: String = "") {
        let field = app.textFields["star-list-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        if !old.isEmpty { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        field.typeText(value)
        app.buttons["保存"].tap()
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
