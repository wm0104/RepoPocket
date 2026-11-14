"""Layout contracts for the recorded dispatch regression, not UIKit pixel validation."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class WorkflowFilterLayoutTests(unittest.TestCase):
    def test_corner_regression_checks_the_connected_group_not_an_old_filter_card(self):
        source = (ROOT / 'StyleUITests/StyleBoundaryTests.swift').read_text(encoding='utf-8')
        case = source.split('func testWorkflowFilterCornersSurviveDispatchAndRefresh()', 1)[1].split('func testLocalMergePreview', 1)[0]
        self.assertIn('identifier: "workflow-filter-failed", top: false, bottom: false', case)
        self.assertNotIn('identifier: "workflow-filter-failed", top: false, bottom: true', case)
        self.assertIn('identifier: "workflow-run-\\(lastID)", top: false, bottom: false', case)
        self.assertIn('identifier: "content-freshness", top: false, bottom: true', case)
        self.assertIn('lastCell.frame.minY - lastRunCell.frame.maxY', case)
        freshness = (ROOT / 'RepoPocket/ContentFreshnessText.swift').read_text(encoding='utf-8')
        self.assertIn('.accessibilityIdentifier("content-freshness")', freshness)
        self.assertNotIn('workflow-content-freshness', self.source)
        self.assertIn('gap, 2', case)
        self.assertIn('for cycle in 0..<3', case)
        self.assertIn('run.tap()', case)
        self.assertIn('refresh.tap()', case)
        self.assertIn('setSwitch(app, label: "workflow-filter-failed", enabled: (failed.value as? String) != "1")', case)
        self.assertIn('lastCell.frame.maxY, bottom', case)
        self.assertIn('lastCell.frame.minY, top', case)
        self.assertIn('if freshness.exists && lastRun.isHittable', case)
        self.assertLess(case.index('for _ in 0..<8'), case.index('XCTAssertTrue(freshness.waitForExistence'))
        self.assertNotIn('reveal(lastRun, in: app)', case)
        helper = source.split('private func assertGroupCorners(', 1)[1].split('func testWorkflowLastCard', 1)[0]
        self.assertIn('stableSamples >= 2', helper)
        self.assertLess(helper.index('XCTWaiter.wait'), helper.index('app.screenshot()'))
        self.assertLess(helper.index('app.screenshot()'), helper.index('let frame = cell.frame'))
        self.assertIn('rounded ? background : fill', helper)
        self.assertIn('}.max() ?? 255, 8', helper)

    def test_pagination_gap_reads_one_fixed_visible_snapshot(self):
        source = (ROOT / 'StyleUITests/StyleBoundaryTests.swift').read_text(encoding='utf-8')
        case = source.split('func testWorkflowLastCardToLoadMoreUsesCompactGap()', 1)[1].split('func testUpstreamWatch', 1)[0]
        self.assertIn('try app.collectionViews.firstMatch.snapshot()', case)
        self.assertIn('snapshot.children', case)
        self.assertIn('lastRows.count, 1', case)
        self.assertIn('layout.frame.intersects(last.frame)', case)
        self.assertIn('XCTAssertLessThanOrEqual(gap, 16)', case)
        self.assertNotIn('let last = app.descendants', case)
        self.assertLess(case.index('workflow-pagination-compact-gap'), case.index('XCTAssertLessThanOrEqual(gap, 16)'))

    def test_refresh_regression_exits_selection_with_the_actual_done_button(self):
        source = (ROOT / 'StyleUITests/RepositoryOperationsTests.swift').read_text(encoding='utf-8')
        case = source.split('func testActionsManualRefreshRetainsFailuresAndAutomaticallyFollowsTheSameRun()', 1)[1].split('func testVersionGroups', 1)[0]
        self.assertIn('Button(selection.active ? "完成" : "多选")', self.source)
        self.assertIn('let done = app.buttons["完成"]', case)
        self.assertIn('waitForEnabled(done); done.tap()', case)
        self.assertEqual(case.count('waitForEnabled(app.buttons["多选"])'), 1)
        selector = (ROOT / 'Scripts/run_style_preview.sh').read_text(encoding='utf-8').split('  regression-recheck)', 1)[1].split(';;', 1)[0]
        self.assertIn('/testWorkflowLastCardToLoadMoreUsesCompactGap', selector)
        self.assertIn('/testActionsManualRefreshRetainsFailuresAndAutomaticallyFollowsTheSameRun', selector)
        for required in ['waitForLabel(run, containing: "运行中")',
                         'error.waitForExistence(timeout: 10)',
                         'waitForLabel(run, containing: "成功", timeout: 25)',
                         'XCTAssertFalse(error.exists)']:
            self.assertIn(required, case)

    def setUp(self):
        self.source = (ROOT / 'RepoPocket/WorkflowViews.swift').read_text()

    def test_branch_toggle_and_subtitle_are_one_layout_container(self):
        row = self.source.split('SoftGroupRow("branch") {', 1)[1].split('} else {', 1)[0]
        self.assertIn('VStack(alignment: .leading, spacing: 4)', row)
        self.assertLess(row.index('VStack('), row.index('Toggle("仅当前分支"'))
        self.assertIn('if let dispatchedBranch', row)
        self.assertIn('Text(dispatchedBranch)', row)
        self.assertRegex(self.source, r'SoftGroupRow\("failed"\)\s*\{\s*Toggle\("仅看失败记录"')

    def test_dispatch_is_a_confirmation_toolbar_action_not_a_card(self):
        page = self.source.split('struct WorkflowDispatchView: View {', 1)[1].split('struct WorkflowRunView:', 1)[0]
        self.assertNotIn('SoftGroupRow("dispatch")', page)
        toolbar = page.split('.toolbar {', 1)[1].split('.interactiveDismissDisabled', 1)[0]
        self.assertIn('ToolbarItem(placement: .confirmationAction)', toolbar)
        self.assertIn('Button("运行") { confirmation = state.target(repo, api: api) }', toolbar)
        self.assertIn('.disabled(!ready || state.busy)', toolbar)
        self.assertIn('accessibilityIdentifier("workflow-dispatch-confirm")', toolbar)
        self.assertIn('Button("关闭") { dismiss() }.disabled(state.busy)', toolbar)
        self.assertIn('.confirmationDialog("确认启动工作流？"', page)
        self.assertEqual(page.count('state.submit(target, api: api, accepted: accepted)'), 1)

    def test_status_rows_only_exist_when_there_is_status_and_continue_the_group(self):
        page = self.source.split('struct WorkflowDispatchView: View {', 1)[1].split('struct WorkflowRunView:', 1)[0]
        self.assertIn('private var hasStatus: Bool { state.busy || !state.result.isEmpty || !state.error.isEmpty || !api.isCurrentSession }', page)
        self.assertIn('if hasStatus {\n                    SoftGroupRows(top: false)', page)
        self.assertIn('SoftGroupRows(top: false, bottom: !hasStatus)', page)
        self.assertEqual(page.count('Section {'), 1)
        for item in ['busy', 'result', 'error', 'account']:
            self.assertIn(f'SoftGroupRow("{item}")', page)

if __name__ == '__main__':
    unittest.main()
