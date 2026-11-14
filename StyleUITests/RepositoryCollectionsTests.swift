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
        XCTAssertTrue(app.staticTexts["star-list-add-notice"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["star-list-add-notice"].label, "添加成功")
        XCTAssertTrue(item.exists); XCTAssertFalse(item.isEnabled)
        app.buttons["关闭"].tap()
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

    func testOptInMultipleSelectionSurvivesSearchAndCancelDoesNotWrite() {
        let app = launch()
        openTools(app)
        app.buttons["分类仓库操作"].tap(); app.buttons["添加已加星标的仓库"].tap()
        let first = app.buttons["star-list-add-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        app.buttons["star-list-add-multiple"].tap(); first.tap()
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("second")
        let second = app.buttons["star-list-add-2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5)); second.tap()
        XCTAssertEqual(app.buttons["star-list-add-selected"].label, "添加(2)")
        // Active system search hides the sheet's navigation toolbar, including cancel-multiple/close.
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["star-list-add-multiple"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["star-list-add-selected"].label, "添加(2)")
        XCTAssertTrue(first.exists); XCTAssertTrue(second.exists)
        app.buttons["star-list-add-multiple"].tap()
        XCTAssertFalse(app.buttons["star-list-add-selected"].exists)
        app.buttons["star-list-add-multiple"].tap()
        XCTAssertEqual(app.buttons["star-list-add-selected"].label, "添加(0)")
        first.tap(); second.tap()
        XCTAssertEqual(app.buttons["star-list-add-selected"].label, "添加(2)")
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["分类仓库操作"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["collection-preview-writes"].label, "分类写入：0")
        app.buttons["分类仓库操作"].tap(); app.buttons["添加已加星标的仓库"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        app.buttons["star-list-add-multiple"].tap()
        XCTAssertEqual(app.buttons["star-list-add-selected"].label, "添加(0)")
        first.tap(); second.tap()
        app.buttons["star-list-add-selected"].tap()
        let notice = app.staticTexts["star-list-add-notice"]
        waitLabel(notice, contains: "2/2")
        XCTAssertTrue(first.exists); XCTAssertFalse(first.isEnabled); XCTAssertFalse(second.isEnabled)
        XCTAssertFalse(app.buttons["star-list-add-selected"].isEnabled)
        screenshot(app, "star-list-multiple-added-stays-open")
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["star-list-repository-R2"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["collection-preview-writes"].label, "分类写入：2")
    }

    func testPartialBatchRemovalKeepsSuccessAndOffersOnlyRemainingItems() throws {
        let app = launch(["-star-list-seeded-preview", "-star-list-partial-remove-preview"])
        openTools(app)
        XCTAssertTrue(app.buttons["star-list-repository-R2"].waitForExistence(timeout: 15))
        app.buttons["分类仓库操作"].tap()
        guard app.buttons["批量移除"].waitForExistence(timeout: 2) else {
            XCTAssertTrue(app.buttons["编辑排序"].exists)
            throw XCTSkip("本版本暂不开放批量移除；保留该安全场景，不将未验收功能记为通过。")
        }
        app.buttons["批量移除"].tap()
        recordRemovalState(app, checkpoint: "immediate")
        XCTAssertTrue(app.buttons["star-list-edit-done"].waitForExistence(timeout: 5))
        let firstSelection = app.buttons["star-list-select-R1"]
        let appeared = firstSelection.waitForExistence(timeout: 5)
        recordRemovalState(app, checkpoint: "settled")
        XCTAssertTrue(appeared, "Selection must remain an actual Button after the mode transition")
        XCTAssertTrue(app.buttons["star-list-select-R1"].exists)
        XCTAssertTrue(app.buttons["star-list-select-R2"].exists)
        XCTAssertFalse(app.buttons["repository-owner-link"].exists)
        XCTAssertTrue(firstSelection.isHittable); firstSelection.tap()
        XCTAssertEqual(firstSelection.value as? String, "已选择")
        XCTAssertEqual(app.buttons["star-list-remove-selected"].label, "从分类移除(1)")
        app.buttons["star-list-select-R2"].tap()
        XCTAssertEqual(app.buttons["star-list-remove-selected"].label, "从分类移除(2)")
        XCTAssertEqual(app.staticTexts["collection-preview-writes"].label, "分类写入：0")
        app.buttons["star-list-remove-selected"].tap(); app.buttons["确认从分类移除"].tap()
        waitLabel(app.staticTexts["star-list-detail-notice"], contains: "1/2")
        XCTAssertFalse(app.buttons["star-list-select-R1"].exists)
        XCTAssertTrue(app.buttons["star-list-select-R2"].exists)
        XCTAssertEqual(app.buttons["star-list-remove-selected"].label, "从分类移除(1)")
        XCTAssertTrue(app.staticTexts["star-list-detail-error"].exists)
        XCTAssertEqual(app.staticTexts["collection-preview-writes"].label, "分类写入：1")
        screenshot(app, "star-list-partial-removal-remaining")
        app.buttons["star-list-remove-selected"].tap(); app.buttons["确认从分类移除"].tap()
        waitLabel(app.staticTexts["star-list-detail-notice"], contains: "1/1")
        app.buttons["star-list-edit-done"].tap()
        app.navigationBars.buttons["已加星标"].tap(); app.buttons["star-list-B"].tap()
        XCTAssertTrue(app.buttons["star-list-repository-R1"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["collection-preview-writes"].label, "分类写入：2")
    }

    func testUnknownAddBlocksActionsUntilReadOnlyReconciliationWithoutResend() {
        let app = launch(["-star-list-unknown-add-preview"])
        openTools(app)
        app.buttons["分类仓库操作"].tap(); app.buttons["添加已加星标的仓库"].tap()
        let first = app.buttons["star-list-add-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15)); first.tap()
        let retry = app.buttons["重新读取并核对"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20))
        XCTAssertFalse(first.isEnabled)
        XCTAssertFalse(app.staticTexts["star-list-add-notice"].label.contains("添加成功"))
        retry.tap()
        let added = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已添加"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [added], timeout: 20), .completed)
        XCTAssertFalse(first.isEnabled)
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["star-list-repository-R1"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["collection-preview-writes"].label, "分类写入：1")
    }

    func testLongPressOrderPersistsAndOutsideDropDoesNotLeaveHalfState() {
        let app = launch(["-star-list-seeded-preview"])
        openTools(app)
        XCTAssertTrue(app.buttons["star-list-repository-R2"].waitForExistence(timeout: 15))
        app.buttons["分类仓库操作"].tap(); app.buttons["编辑排序"].tap()
        let collection = app.collectionViews["star-list-sort-collection"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))
        let first = collection.cells["star-list-sort-R1"], second = collection.cells["star-list-sort-R2"]
        XCTAssertTrue(first.waitForExistence(timeout: 10)); XCTAssertTrue(second.exists)
        first.press(forDuration: 0.8, thenDragTo: second)
        let reordered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in second.frame.minY < first.frame.minY }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 10), .completed)
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8, thenDragTo: collection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.1)))
        app.buttons["star-list-edit-done"].tap()
        let normalFirst = app.buttons["star-list-repository-R1"], normalSecond = app.buttons["star-list-repository-R2"]
        XCTAssertTrue(normalFirst.waitForExistence(timeout: 10)); XCTAssertLessThan(normalSecond.frame.minY, normalFirst.frame.minY)
        XCTAssertEqual(app.staticTexts["collection-preview-writes"].label, "分类写入：0")
        app.terminate(); app.launchArguments.append("-keep-collection-favorites"); app.launch()
        XCTAssertTrue(app.buttons["home-collection-starred"].waitForExistence(timeout: 20)); openTools(app)
        XCTAssertTrue(normalFirst.waitForExistence(timeout: 15)); XCTAssertLessThan(normalSecond.frame.minY, normalFirst.frame.minY)
        normalFirst.swipeLeft(); app.buttons["移出分类"].tap(); app.buttons["取消"].tap()
        XCTAssertTrue(normalFirst.exists)
    }

    private func recordRemovalState(_ app: XCUIApplication, checkpoint: String) {
        var states: [String] = []
        for id in ["star-list-select-R1", "star-list-select-R2"] {
            let matches = app.descendants(matching: .any).matching(identifier: id).allElementsBoundByIndex
            states.append(id + ": count=\(matches.count)")
            for element in matches where element.exists {
                states.append("type=\(element.elementType) label=\(element.label) value=\(String(describing: element.value)) enabled=\(element.isEnabled) hittable=\(element.isHittable) frame=\(element.frame)")
            }
        }
        let attachment = XCTAttachment(string: states.joined(separator: "\n") + "\n" + app.debugDescription)
        attachment.name = "star-list-removal-" + checkpoint + "-ax"
        attachment.lifetime = .keepAlways; add(attachment)
        screenshot(app, "star-list-removal-" + checkpoint)
    }
    private func openTools(_ app: XCUIApplication) {
        app.buttons["home-collection-starred"].tap()
        XCTAssertTrue(app.buttons["star-list-A"].waitForExistence(timeout: 15)); app.buttons["star-list-A"].tap()
        XCTAssertTrue(app.buttons["分类仓库操作"].waitForExistence(timeout: 15))
    }
    private func waitLabel(_ element: XCUIElement, contains value: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed)
    }
    private func launch(_ extraArguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-style-preview", "-repository-collections-style-preview"] + extraArguments; app.launch()
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
