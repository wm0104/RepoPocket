"""Focused local Star-list contracts. No network, builds, or GitHub writes."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class StarListInteractionTests(unittest.TestCase):
    def test_durable_order_is_account_and_stable_list_scoped(self):
        path = ROOT / 'RepoPocket/StarListLocalOrder.swift'
        self.assertTrue(path.exists(), 'Star-list order needs durable storage separate from snapshot cache')
        source = path.read_text()
        for token in ['accountID', 'listID', '.atomic', 'reconciled', 'removeAccount', 'maximumBytes']:
            self.assertIn(token, source)
        self.assertNotIn('ContentSnapshotCache', source)
        accounts = (ROOT / 'RepoPocket/GitHubAccounts.swift').read_text()
        self.assertIn('StarListLocalOrder.removeAccount(id)', accounts)

    def test_sorting_is_local_system_movement_not_a_global_card_gesture(self):
        source = (ROOT / 'RepoPocket/StarListReorderView.swift').read_text()
        for token in ['beginInteractiveMovementForItem', 'cancelInteractiveMovement', 'UIImpactFeedbackGenerator',
                      'UISelectionFeedbackGenerator', 'isCurrent', 'dismantleUIViewController']:
            self.assertIn(token, source)
        self.assertNotIn('sensoryFeedback', source)
        self.assertNotIn('UIDragInteraction', source)

    def test_add_stays_open_and_selection_is_opt_in(self):
        source = (ROOT / 'RepoPocket/RepositoryCollectionViews.swift').read_text()
        picker = source.split('private struct StarListRepositoryPicker:', 1)[1]
        for token in ['多选', '已添加', '添加成功', 'membershipKnown', 'selected', 'included: true']:
            self.assertIn(token, picker)
        self.assertNotIn('attempted', picker)
        self.assertNotIn('dismiss() }', picker.split('private func add(', 1)[1])

    def test_add_success_notice_is_visible_without_scrolling_to_the_list_end(self):
        source = (ROOT / 'RepoPocket/RepositoryCollectionViews.swift').read_text()
        picker = source.split('private struct StarListRepositoryPicker:', 1)[1]
        self.assertIn('.overlay(alignment: .topTrailing)', picker)
        overlay = picker.split('.overlay(alignment: .topTrailing)', 1)[1].split('.toolbar', 1)[0]
        self.assertIn('Text(notice)', overlay)
        self.assertIn('.allowsHitTesting(false)', overlay)
        self.assertIn('star-list-add-notice', overlay)
        self.assertNotIn('SoftGroupRow("notice")', picker)

    def test_unknown_membership_and_stale_selection_are_not_actionable(self):
        source = (ROOT / 'RepoPocket/RepositoryCollectionViews.swift').read_text()
        picker = source.split('private struct StarListRepositoryPicker:', 1)[1]
        self.assertIn('selected.formIntersection(Set(repositories.map(\\.id)).subtracting(memberIDs))', picker)
        for section in source.split('@discardableResult private func reconcile() async -> Bool {')[1:]:
            self.assertLess(section.index('membershipKnown = false'), section.index('try await api.starLists.repositories'))
        self.assertIn('.onChange(of: api.isCurrentSession)', picker)

    def test_bridge_waits_for_uikit_completion_and_releases_hosts(self):
        source = (ROOT / 'RepoPocket/StarListReorderView.swift').read_text()
        ended = source.split('case .ended:', 1)[1].split('default:', 1)[0]
        self.assertIn('DispatchQueue.main.async', ended)
        self.assertIn('prepareForReuse()', source)
        self.assertIn('removeFromParent()', source)
        self.assertIn('if #available(iOS 16.0, *)', source)
        self.assertIn('host.sizeThatFits(in:', source)
        self.assertIn('func dismantle()', source)
        self.assertNotIn('private var parent: StarListReorderView', source,
                         'UIViewController already declares parent: UIViewController?')
        self.assertNotIn('@objc private func move(', source,
                         'UIResponder already declares the Objective-C move: selector')
        self.assertIn('#selector(handleReorderLongPress(_:))', source)

    def test_normal_mode_remains_default_and_unmodified_card_is_used(self):
        source = (ROOT / 'RepoPocket/RepositoryCollectionViews.swift').read_text()
        detail = source.split('struct StarListDetailView:', 1)[1].split('private struct StarListRepositoryPicker:', 1)[0]
        self.assertIn('@State private var mode = Mode.normal', detail)
        normal = detail.split('NavigationLink { BrowserView(api: api, repo: item.nameWithOwner', 1)[1]
        self.assertIn('RepositoryCard(repository: item.repository, account: api.login, api: api)', normal)
        self.assertIn('.swipeActions(edge: .trailing, allowsFullSwipe: false)', normal)
        self.assertNotIn('.onDrag', detail)
        self.assertNotIn('.onLongPressGesture', detail)
        self.assertIn('if mode == .sorting', detail)
        self.assertNotIn('NativeMenuItem(id: "remove-many"', detail,
                         'Batch removal is deliberately unavailable in this release')
        self.assertIn('Button("移出分类", role: .destructive)', detail)

    def test_batch_remove_reconciles_and_never_unstars(self):
        source = (ROOT / 'RepoPocket/RepositoryCollectionViews.swift').read_text()
        detail = source.split('struct StarListDetailView:', 1)[1].split('private struct StarListRepositoryPicker:', 1)[0]
        for token in ['编辑排序', '从分类移除', 'included: false', 'await reconcile', 'progress', '不会自动重发']:
            self.assertIn(token, detail)
        self.assertNotIn('removeStar', detail)
        self.assertNotIn('starRequest', detail)

    # Source contracts for CI run 43565751439; NOT an iOS UI reproduction.
    def test_removal_label_has_no_nested_card_actions(self):
        source = (ROOT / 'RepoPocket/RepositoryCollectionViews.swift').read_text()
        row = source.split('if mode == .removing {', 1)[1].split('} else {', 1)[0]
        self.assertIn('CompactRepositorySummary(', row)
        self.assertIn('repository: item.repository, starStore: api.stars', row)
        self.assertIn('.environment(\\.repositorySocialAPI, nil)', row)
        for interactive in ['RepositoryCard(', 'openOwner:', 'openParent:']:
            self.assertNotIn(interactive, row)
        self.assertIn('.accessibilityIdentifier("star-list-select-" + item.id)', row)
        self.assertIn('.accessibilityElement(children: .ignore)', row)

    def test_search_is_cancelled_before_toolbar_and_unsubmitted_close_is_covered(self):
        source = (ROOT / 'StyleUITests/RepositoryCollectionsTests.swift').read_text()
        case = source.split('func testOptInMultipleSelectionSurvivesSearchAndCancelDoesNotWrite()', 1)[1].split('func testPartialBatchRemoval', 1)[0]
        search = case.split('search.typeText("second")', 1)[1]
        self.assertIn('app.buttons["取消"].tap()', search)
        self.assertLess(search.index('app.buttons["取消"].tap()'), search.index('app.buttons["star-list-add-multiple"].tap()'))
        # After cancelling search, selection must survive before mode cancellation.
        after_search = search.split('app.buttons["取消"].tap()', 1)[1]
        self.assertIn('XCTAssertEqual(app.buttons["star-list-add-selected"].label, "添加(2)")', after_search)
        self.assertIn('XCTAssertFalse(app.buttons["star-list-add-selected"].exists)', after_search)
        before_close = after_search.split('app.buttons["关闭"].tap()', 1)[0]
        self.assertIn('first.tap(); second.tap()', before_close)
        reopened = case.split('app.buttons["关闭"].tap()', 1)[1]
        self.assertIn('"分类写入：0"', reopened)
        self.assertIn('"添加(0)"', reopened)

    def test_removal_diagnostic_preserves_actual_button_activation(self):
        # Host wiring contract, not a simulator or AX execution.
        source = (ROOT / 'StyleUITests/RepositoryCollectionsTests.swift').read_text()
        case = source.split('func testPartialBatchRemovalKeepsSuccessAndOffersOnlyRemainingItems()', 1)[1].split('func testUnknownAdd', 1)[0]
        for token in ['recordRemovalState(app, checkpoint: "immediate")',
                      'recordRemovalState(app, checkpoint: "settled")',
                      'app.buttons["star-list-edit-done"].waitForExistence',
                      'let firstSelection = app.buttons["star-list-select-R1"]',
                      'firstSelection.waitForExistence', 'XCTAssertTrue(firstSelection.isHittable)',
                      'firstSelection.tap()', 'firstSelection.value as? String, "已选择"',
                      '"从分类移除(1)"', '"分类写入：0"']:
            self.assertIn(token, case)
        helper = source.split('private func recordRemovalState', 1)[1].split('private func openTools', 1)[0]
        self.assertIn('app.debugDescription', helper)
        self.assertIn('element.elementType', helper)
        self.assertIn('element.isHittable', helper)
        self.assertNotIn('.tap()', helper)
        self.assertNotIn('coordinate(', case)

if __name__ == '__main__':
    unittest.main()
