import XCTest

final class NativeDisclosureTests: XCTestCase {
    func testHomeIssuesStartClosedAndRefreshKeepsTheUserChoice() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-style-preview", "-user-connections-style-preview"]
        app.launch()
        let fold = app.buttons["议题"]
        XCTAssertTrue(fold.waitForExistence(timeout: 20))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "议题")).count, 1)
        XCTAssertFalse(app.buttons["home-issue-4"].exists)
        expandHomeIssues(in: app)
        XCTAssertTrue(app.buttons["home-issue-4"].waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "home-issues-native-expanded"; shot.lifetime = .keepAlways; add(shot)
        refreshHome(app)
        XCTAssertTrue(app.buttons["home-personal-issues"].exists)
        XCTAssertTrue(app.buttons["home-issue-4"].exists)
        for _ in 0..<6 where !fold.isHittable { app.swipeDown() }
        fold.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["home-issue-4"])], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["home-issue-4"].exists)
        refreshHome(app)
        XCTAssertFalse(app.buttons["home-personal-issues"].exists)
        XCTAssertFalse(app.buttons["home-issue-4"].exists)
    }

    func testThreeScrollHostDisclosureTransitionsAndRepeatedInput() {
        continueAfterFailure = false
        let cases: [(String, [String], String, [String])] = [
            ("home-issues", ["-style-preview", "-user-connections-style-preview"], "home-issues-disclosure", ["home-issue-4", "home-personal-issues"]),
            ("repository-more", ["-style-preview", "-user-connections-style-preview", "-upstream-sync-style-preview"], "repository-more", ["repository-more-tools", "repository-more-owner"])
        ]
        for (name, arguments, headerID, children) in cases {
            let app = XCUIApplication(); app.launchArguments = arguments; app.launch()
            let header = app.buttons[headerID]
            XCTAssertTrue(header.waitForExistence(timeout: 20))
            XCTAssertTrue(header.isHittable)
            let card = disclosureCard(app, headerID: headerID)
            // Fixed fixtures already expose the card; pre-scrolling hid its top under navigation.
            let visibleTop = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : 0
            XCTAssertGreaterThanOrEqual(card.frame.minY, visibleTop + 4,
                                        "The whole card must remain below navigation material")
            XCTAssertLessThanOrEqual(card.frame.maxY, app.frame.maxY)
            XCTAssertFalse(app.cells.containing(.any, identifier: headerID).firstMatch.exists, "This must exercise the production ScrollView host, not a List fixture")
            recordDisclosureTransition(app, name: name + "-opening") { tapNativeDisclosureHeader(header, trailing: true) }
            XCTAssertTrue(app.buttons[children[0]].waitForExistence(timeout: 5))
            assertDisclosureCard(app, headerID: headerID, childIDs: children)
            recordDisclosureTransition(app, name: name + "-closing-and-reopening") {
                tapNativeDisclosureHeader(header, trailing: false)
                tapNativeDisclosureHeader(header, trailing: true)
            }
            XCTAssertTrue(app.buttons[children[0]].waitForExistence(timeout: 5))
            assertDisclosureCard(app, headerID: headerID, childIDs: children)
            recordDisclosureTransition(app, name: name + "-closing") { tapNativeDisclosureHeader(header, trailing: false) }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons[children[0]])], timeout: 5), .completed)
            assertDisclosureCard(app, headerID: headerID, childIDs: [])
            app.terminate()
        }
    }

    // XCUIScreen sampling runs alongside input; timestamps expose XCTest serialization.
    // It is evidence capture, not a claim that XCTest can interrupt every animation frame.
    func recordDisclosureTransition(_ app: XCUIApplication, name: String, action: () -> Void) {
        let done = expectation(description: name + "-samples")
        let started = Date()
        let lock = NSLock()
        var samples: [(requested: TimeInterval, completed: TimeInterval, screenshot: XCUIScreenshot)] = []
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<12 {
                let time = Date().timeIntervalSince(started)
                let screenshot = XCUIScreen.main.screenshot()
                let completed = Date().timeIntervalSince(started)
                lock.lock(); samples.append((time, completed, screenshot)); lock.unlock()
                Thread.sleep(forTimeInterval: 0.04)
            }
            done.fulfill()
        }
        let inputStarted = Date().timeIntervalSince(started)
        action()
        let inputCompleted = Date().timeIntervalSince(started)
        wait(for: [done], timeout: 20)
        lock.lock(); let captured = samples; lock.unlock()
        for (index, sample) in captured.enumerated() {
            let attachment = XCTAttachment(screenshot: sample.screenshot)
            attachment.name = name + "-sample-\(index)"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        let timing = XCTAttachment(string: "input: \(inputStarted)...\(inputCompleted)s\n" + captured.enumerated().map { "\($0.offset): requested=\($0.element.requested)s completed=\($0.element.completed)s" }.joined(separator: "\n") + "\nNative screen samples; XCTest may serialize capture/input. Inspect timestamps before claiming intermediate frames.\n" + app.debugDescription)
        timing.name = name + "-timing-and-ax"; timing.lifetime = .keepAlways; add(timing)
    }

    private func refreshHome(_ app: XCUIApplication) {
        app.buttons["仓库操作"].tap()
        let refresh = app.buttons["刷新"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5)); refresh.tap()
        let timestamp = app.descendants(matching: .any)["content-freshness"].firstMatch
        for _ in 0..<6 where !timestamp.exists || !timestamp.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(timestamp.waitForExistence(timeout: 10))
    }
}
