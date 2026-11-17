import XCTest

extension XCTestCase {
    func chooseWorkflowAction(_ title: String, in app: XCUIApplication) {
        let menu = app.buttons["workflow-actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15)); menu.tap()
        let action = app.buttons[title]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: action)], timeout: 15), .completed)
        action.tap()
    }

    func chooseWorkflowFilter(_ title: String, group: String? = nil, in app: XCUIApplication) {
        let menu = app.buttons["workflow-filters"]
        for _ in 0..<8 where !menu.isHittable { app.swipeDown() }
        XCTAssertTrue(menu.waitForExistence(timeout: 15)); menu.tap()
        if let group {
            XCTAssertTrue(app.buttons[group].waitForExistence(timeout: 5)); app.buttons[group].tap()
        }
        XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5)); app.buttons[title].tap()
    }

    func expandHomeIssues(in app: XCUIApplication) {
        let fold = app.buttons["议题"]
        XCTAssertTrue(fold.waitForExistence(timeout: 20))
        for _ in 0..<8 where !fold.isHittable { app.swipeUp() }
        if !app.buttons["home-personal-issues"].exists { fold.tap() }
        XCTAssertTrue(app.buttons["home-personal-issues"].waitForExistence(timeout: 5))
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home-issue-'")).firstMatch
        let target = first.exists ? first : app.buttons["home-personal-issues"]
        for _ in 0..<6 where !target.isHittable { app.swipeUp() }
    }
}
