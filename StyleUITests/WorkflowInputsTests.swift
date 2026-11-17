import XCTest

/// Uses only WorkflowSelectionPreviewProtocol; never talks to GitHub or creates a real run.
final class WorkflowInputsTests: XCTestCase {
    func testNativeInputsDefaultsValidationAndMenuSelectionWithoutDispatch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-workflow-selection-style-preview", "-workflow-filter-corners-preview"]
        app.launch()
        chooseWorkflowAction("运行工作流", in: app)
        app.buttons["workflow-dispatch-workflow"].tap()
        app.buttons["Build IPA · .github/workflows/build.yml"].tap()
        app.buttons["workflow-dispatch-branch"].tap()
        app.buttons["main"].tap()
        let run = app.buttons["workflow-dispatch-confirm"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: run)], timeout: 15), .completed)

        let fold = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "工作流参数")).firstMatch
        reveal(fold, app: app)
        XCTAssertFalse(app.textFields["workflow-input-run_title"].exists, "Valid defaults allow a compact initial form")
        XCTAssertTrue(fold.label.contains("使用默认值")); fold.tap()

        let title = app.textFields["workflow-input-run_title"]
        reveal(title, app: app)
        XCTAssertEqual(title.value as? String, "Preview run")
        let channel = app.buttons["workflow-input-channel"]
        reveal(channel, app: app); channel.tap()
        XCTAssertTrue(app.buttons["beta"].waitForExistence(timeout: 5)); app.buttons["beta"].tap()
        XCTAssertEqual(channel.value as? String, "beta")
        let flag = app.switches["workflow-input-dry_run"]
        reveal(flag, app: app); XCTAssertTrue(["1", "true"].contains(flag.value as? String ?? ""))
        // SwiftUI exposes the whole labelled row as Switch; its center is not the trailing toggle.
        flag.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ["0", "false"].contains(flag.value as? String ?? "")
        }, object: nil)], timeout: 5), .completed)
        flag.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ["1", "true"].contains(flag.value as? String ?? "")
        }, object: nil)], timeout: 5), .completed)

        let amount = app.textFields["workflow-input-count"]
        reveal(amount, app: app); amount.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Wait for the tapped input to open its native keyboard before typing")
        amount.typeText(XCUIKeyboardKey.delete.rawValue + "-")
        XCTAssertEqual(amount.value as? String, "-")
        XCTAssertFalse(run.isEnabled, "Invalid number must prevent preparing a dispatch confirmation")
        amount.typeText(XCUIKeyboardKey.delete.rawValue + "2")
        XCTAssertEqual(amount.value as? String, "2")
        XCTAssertTrue(run.isEnabled)
        // No Run / Start tap: input editing must not trigger a mutation.
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "GitHub 已接受启动请求")).firstMatch.exists)
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        let form = app.collectionViews.allElementsBoundByIndex.last!
        let top = app.navigationBars.allElementsBoundByIndex.last!.frame.maxY
        let bottom = app.frame.maxY - 44
        // A field below the sheet's safe area can report hittable without accepting focus.
        for _ in 0..<8 {
            if element.exists && element.isHittable && element.frame.minY >= top && element.frame.maxY <= bottom { break }
            if element.exists && element.frame.minY < top { form.swipeDown() }
            else { form.swipeUp() }
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
        XCTAssertGreaterThanOrEqual(element.frame.minY, top)
        XCTAssertLessThanOrEqual(element.frame.maxY, bottom)
    }

    func testRequiredParametersAutoExpandButValidValuesCanCollapse() {
        let app = openFixture("-workflow-required-inputs-preview")
        let field = app.textFields["workflow-input-message"]
        reveal(field, app: app)
        XCTAssertFalse(app.buttons["workflow-dispatch-confirm"].isEnabled)
        field.tap(); field.typeText("fixture message\n")
        let fold = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "工作流参数")).firstMatch
        reveal(fold, app: app); fold.tap()
        XCTAssertFalse(field.exists)
        XCTAssertTrue(fold.label.contains("已填写"))
        XCTAssertTrue(app.buttons["workflow-dispatch-confirm"].isEnabled)
        fold.tap(); reveal(field, app: app)
        XCTAssertEqual(field.value as? String, "fixture message")
    }

    func testNoInputsAndReadFailureDoNotShowAnEmptyFold() {
        let app = openFixture("-workflow-no-inputs-preview")
        let run = app.buttons["workflow-dispatch-confirm"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: run)], timeout: 15), .completed)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "工作流参数")).firstMatch.exists)
        app.terminate()
        let failed = openFixture("-workflow-schema-failure-preview")
        let retry = failed.buttons["重新读取参数"]
        reveal(retry, app: failed)
        XCTAssertFalse(failed.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "工作流参数")).firstMatch.exists)
        XCTAssertFalse(failed.buttons["workflow-dispatch-confirm"].isEnabled)
        XCTAssertTrue(retry.isEnabled)
    }

    func testWorkflowAndStatusFiltersUseTheRealListRoute() {
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-workflow-selection-style-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["workflow-run-4"].waitForExistence(timeout: 15))
        chooseWorkflowFilter("Tests", group: "工作流", in: app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["workflow-run-1"])], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["workflow-run-4"].exists)
        chooseWorkflowFilter("Build IPA", group: "工作流", in: app)
        chooseWorkflowFilter("运行中", group: "状态", in: app)
        XCTAssertTrue(app.buttons["workflow-run-3"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["workflow-run-4"].exists)
        XCTAssertFalse(app.buttons["workflow-run-1"].exists)
        chooseWorkflowFilter("全部状态", group: "状态", in: app)
        XCTAssertTrue(app.buttons["workflow-run-1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["workflow-run-4"].exists, "Removing only status must retain the workflow filter")
    }

    private func openFixture(_ flag: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-workflow-selection-style-preview", "-workflow-filter-corners-preview", flag]
        app.launch()
        chooseWorkflowAction("运行工作流", in: app)
        app.buttons["workflow-dispatch-workflow"].tap()
        app.buttons["Build IPA · .github/workflows/build.yml"].tap()
        app.buttons["workflow-dispatch-branch"].tap(); app.buttons["main"].tap()
        return app
    }
}
