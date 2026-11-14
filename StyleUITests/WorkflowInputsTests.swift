import XCTest

/// Uses only WorkflowSelectionPreviewProtocol; never talks to GitHub or creates a real run.
final class WorkflowInputsTests: XCTestCase {
    func testNativeInputsDefaultsValidationAndMenuSelectionWithoutDispatch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-workflow-selection-style-preview", "-workflow-filter-corners-preview"]
        app.launch()
        let open = app.buttons["workflow-dispatch-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 20)); open.tap()
        app.buttons["workflow-dispatch-workflow"].tap()
        app.buttons["Build IPA · .github/workflows/build.yml"].tap()
        app.buttons["workflow-dispatch-branch"].tap()
        app.buttons["main"].tap()
        let run = app.buttons["workflow-dispatch-confirm"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: run)], timeout: 15), .completed)

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
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
    }
}
