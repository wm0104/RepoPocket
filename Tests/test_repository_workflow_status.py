"""Repository Actions row contracts plus the production paging/status core.

The host harness exercises cancellation/session/order, not native SwiftUI animation.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc')


def source(name):
    return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')


class RepositoryWorkflowStatusTests(unittest.TestCase):
    def test_shipping_actions_link_keeps_navigation_and_adds_a_scoped_shared_badge(self):
        section = source('CollaborationViews.swift').split('struct RepositoryCommunitySection:', 1)[1].split('struct RepositoryWorkflowStatus:', 1)[0]
        self.assertIn('NavigationLink { WorkflowRunsView(api: api, repo: repo, branch: branch) }', section)
        self.assertIn('RepositoryFeatureLabel(title: "操作 · Actions", symbol: "play.circle", color: .orange)', section)
        self.assertIn('RepositoryWorkflowStatus(api: api, repo: repo)', section)
        self.assertIn('.id(api.accountID + ":" + repo + ":" + AccountStore.generation.uuidString)', section)
        self.assertIn('accessibilityIdentifier("repository-actions")', section)
        self.assertIn('DisclosureGroup(isExpanded: $expanded)', section)

    def test_latest_is_the_first_all_branch_result_and_unavailable_never_means_success(self):
        row = source('CollaborationViews.swift').split('struct RepositoryWorkflowStatus:', 1)[1].split('struct CollaborationListView:', 1)[0]
        for token in ['if api.isCurrentSession, let run = latest', 'latest = run', 'latest = nil',
                      'api.latestRepositoryWorkflowRun(repo)',
                      'WorkflowStatusBadge(status: run.status, conclusion: run.conclusion)']:
            self.assertIn(token, row)
        for forbidden in ['.sorted', '?? "success"', 'TimelineView', 'rotationEffect', 'currentBranchOnly']:
            self.assertNotIn(forbidden, row)
        self.assertIn('.frame(width: 14, height: 14)', source('WorkflowViews.swift').split('struct WorkflowRunsView:', 1)[0])

    def test_foreground_task_owns_each_request_and_sleep(self):
        row = source('CollaborationViews.swift').split('struct RepositoryWorkflowStatus:', 1)[1].split('struct CollaborationListView:', 1)[0]
        for token in ['@Environment(\\.scenePhase)', '.task(id: scenePhase)', 'guard scenePhase == .active',
                      'while !Task.isCancelled, api.isCurrentSession', 'Task.sleep(nanoseconds:']:
            self.assertIn(token, row)
        self.assertNotIn('Task {', row, 'Requests must cancel with the SwiftUI task on disappearance or background')

    def test_native_fixture_uses_the_shipping_row_and_checks_animated_then_completed_state(self):
        preview = source('RepositoryOperationsStylePreview.swift')
        self.assertIn('RepositoryCommunitySection(api: api, repo: "fixture-owner/sample"', preview)
        self.assertIn('"/repos/fixture-owner/sample/actions/runs"', preview)
        self.assertIn('"head_branch": "another-branch"', preview)
        ui = (ROOT / 'StyleUITests/RepositoryOperationsTests.swift').read_text(encoding='utf-8')
        for token in ['func testRepositoryActionsRowShowsLatestRunAndReusesRunningBadge()',
                      'app.buttons["repository-actions"]', '"运行中"', '"成功"',
                      'samples', 'runningIconRect(image)', 'XCTAssertGreaterThan(Set(samples).count, 1',
                      'XCTAssertEqual(changedCenterPixels, 0', 'XCTAssertGreaterThan(changedArcPixels, 0',
                      'app.buttons["模拟最近运行完成"].tap()',
                      'app.navigationBars["Actions"]']:
            self.assertIn(token, ui)

    @unittest.skipUnless(SWIFTC, 'Production Swift core harness needs swiftc')
    def test_production_store_cancellation_session_latest_and_status_mapping(self):
        store = source('CommunityPaging.swift').replace('import Combine', '#if canImport(Combine)\nimport Combine\n#endif')
        models = source('NativeRepositoryModels.swift')
        presentation = models.split('struct WorkflowStatusPresentation {', 1)[1].split('enum WorkflowRunStatusFilter:', 1)[0]
        fixture = (ROOT / 'Tests/Fixtures/RepositoryWorkflowStatusHarness.swift').read_text(encoding='utf-8')
        row = source('CollaborationViews.swift').split('struct RepositoryWorkflowStatus:', 1)[1].split('struct CollaborationListView:', 1)[0]
        poll = '@MainActor private func poll()' + row.split('@MainActor private func poll()', 1)[1].rsplit('}', 1)[0]
        # Exercise the shipping loop with a recorded sleep rather than real 10/30-second delays.
        program = fixture.replace('// PRODUCTION_POLL', poll.replace('Task.sleep(', 'recordSleep('))
        program = program.replace('// PRODUCTION_STORE', store).replace('// PRODUCTION_PRESENTATION', 'struct WorkflowStatusPresentation {' + presentation)
        with tempfile.TemporaryDirectory(prefix='repository-workflow-status-', dir=os.environ.get('REPOPOCKET_TEST_TMP')) as tmp:
            swift = Path(tmp) / 'RepositoryWorkflowStatus.swift'
            executable = Path(tmp) / ('status.exe' if os.name == 'nt' else 'status')
            swift.write_text(program, encoding='utf-8')
            compiled = subprocess.run([SWIFTC, '-swift-version', '5', '-parse-as-library', str(swift), '-o', str(executable)], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(executable)], check=True, capture_output=True, text=True)
            self.assertIn('PASS repository latest/order, cancellation, account generation, empty/error and shared status mapping', result.stdout)


if __name__ == '__main__':
    unittest.main()
