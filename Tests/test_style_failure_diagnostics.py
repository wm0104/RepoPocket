from contextlib import redirect_stdout
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


class StyleFailureDiagnosticsTests(unittest.TestCase):
    def test_simulator_launch_failure_keeps_crash_reports_before_device_deletion(self):
        root = Path(__file__).resolve().parents[1]
        script = (root / 'Scripts/run_style_preview.sh').read_text(encoding='utf-8')
        workflow = (root / '.github/workflows/ui-check.yml').read_text(encoding='utf-8')
        cleanup = script.split('cleanup_preview() {', 1)[1].split('trap cleanup_preview EXIT', 1)[0]
        self.assertIn('Library/Logs/DiagnosticReports', cleanup)
        self.assertIn('data/Library/Logs/CrashReporter', cleanup)
        self.assertIn('preview-crashes', cleanup)
        self.assertLess(cleanup.index('preview-crashes'), cleanup.index('simctl delete'))
        self.assertIn('preview-crashes/**', workflow)
        self.assertIn('xcrun otool -L "$binary"', cleanup)
        self.assertIn('preview-linkage.log', workflow)
        self.assertIn('local status=$?', cleanup)
        self.assertIn('if [ "$status" -ne 0 ]; then sleep 5; fi', cleanup)
        self.assertIn('preview-crashes/no-report.txt', cleanup)
        self.assertIn('preview-launch-help.log', workflow)

    def test_switch_helper_targets_the_native_control_and_keeps_state_assertion(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / 'StyleUITests/StyleBoundaryTests.swift').read_text(encoding='utf-8')
        helper = source.split('private func setSwitch(', 1)[1].split('private func sourceReport(', 1)[0]
        self.assertIn('app.switches.allElementsBoundByIndex.first', helper)
        self.assertIn('guard $0.identifier.isEmpty, $0.label.isEmpty else { return false }', helper)
        self.assertIn('frame.contains(CGPoint(x: candidate.midX, y: candidate.midY))', helper)
        self.assertNotIn('frame.contains($0.frame)', helper)
        self.assertIn('(native ?? control).tap()', helper)
        self.assertNotIn('CGVector(dx: 0.94', helper)
        self.assertIn('NSPredicate(format: "value == %@", expected)', helper)
        self.assertIn('The actual switch must change state', helper)

    def test_production_switch_selection_handles_native_bounds_beyond_the_label_row(self):
        import shutil, subprocess
        if not shutil.which('swiftc'):
            self.skipTest('The production Swift geometry fixture executes on macOS')
        root = Path(__file__).resolve().parents[1]
        source = (root / 'StyleUITests/StyleBoundaryTests.swift').read_text(encoding='utf-8')
        closure = source.split('let native = app.switches.allElementsBoundByIndex.first {', 1)[1].split('\n            }', 1)[0]
        fixture = '''import Foundation
import CoreGraphics
struct Control { let identifier: String; let label: String; let frame: CGRect }
func selected(_ frame: CGRect, _ controls: [Control]) -> Control? {
    return controls.first {
''' + closure + '''
    }
}
let branchRow = CGRect(x: 20, y: 149.7, width: 353, height: 44)
let branch = Control(identifier: "", label: "", frame: CGRect(x: 304, y: 156.3, width: 51, height: 31))
assert(selected(branchRow, [branch])?.frame == branch.frame)
let patchRow = CGRect(x: 8, y: 227, width: 377, height: 31)
let wrapper = Control(identifier: "", label: "raw patch", frame: patchRow)
let other = Control(identifier: "", label: "", frame: CGRect(x: 336, y: 180, width: 51, height: 31))
let patch = Control(identifier: "", label: "", frame: CGRect(x: 336, y: 227, width: 51, height: 31))
assert(!patchRow.contains(patch.frame), "The original native bounds exceed the label row by 2pt")
assert(selected(patchRow, [wrapper, other, patch])?.frame == patch.frame)
assert(selected(patchRow, [wrapper, other]) == nil)
print("PASS production native switch geometry: Actions, 2pt overflow, sibling and wrapper exclusion")
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'main.swift'; path.write_text(fixture, encoding='utf-8')
            binary = str(Path(directory) / 'geometry')
            subprocess.run(['swiftc', str(path), '-o', binary], check=True, timeout=30)
            subprocess.run([binary], check=True, timeout=10)

    def test_html_zoom_waits_for_native_ready_before_querying_web_content(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / 'StyleUITests/ReadingZoomTests.swift').read_text(encoding='utf-8')
        case = source.split('func testHTMLPageZoomChangesContentWithoutReloadingOrResettingScroll()', 1)[1].split('func testLongMarkdown', 1)[0]
        self.assertLess(case.index('"loads=1|"'), case.index('sentinel.waitForExistence(timeout: 10)'))
        self.assertIn('object: ready)], timeout: 60), .completed)', case)
        self.assertNotIn('sentinel.waitForExistence(timeout: 30)', case)
        for assertion in ['sentinel.label, "ZOOM_SENTINEL"', 'pinched["loads"], "1"',
                          'enlarged["loads"], "1"', 'reset["loads"], "1"',
                          'enlargedFrame.width, baseline.width * 2',
                          'enlargedInk.width, baselineInk.width * 2']:
            self.assertIn(assertion, case)

    def selection(self, scope, group):
        import os, shutil, subprocess
        root = Path(__file__).resolve().parents[1]
        script = (root / 'Scripts/run_style_preview.sh').read_text(encoding='utf-8')
        self.assertIn('select_test_scope() {', script)
        selection = 'select_test_scope() {' + script.split('select_test_scope() {', 1)[1].split('\nxcodebuild -project', 1)[0]
        bash = 'C:/Program Files/Git/bin/bash.exe' if sys.platform == 'win32' else shutil.which('bash')
        if not bash or not Path(bash).is_file():
            self.skipTest('The production Bash selector requires Bash')
        # Windows Bash truncates a long -c argument; stdin keeps the selector intact.
        result = subprocess.run([bash, '-s'], input='set -euo pipefail\n' + selection + '\nprintf "%s\\n" "${TEST_ARGUMENTS[@]}"',
                                env={**os.environ, 'RP_STYLE_TEST_SCOPE': scope, 'RP_STYLE_TEST_GROUP': group},
                                capture_output=True, text=True, check=True)
        return result.stdout.splitlines()

    def test_all_groups_cover_each_real_ui_case_once_without_changing_focused_scopes(self):
        import re
        root = Path(__file__).resolve().parents[1]
        workflow = (root / '.github/workflows/ui-check.yml').read_text(encoding='utf-8')
        script = (root / 'Scripts/run_style_preview.sh').read_text(encoding='utf-8')
        self.assertIn("fromJSON((inputs.test_scope || 'all') == 'all' && '[\"boundaries-a\",\"boundaries-b\",\"editors\"]' || '[\"selected\"]')", workflow)
        self.assertIn('fail-fast: false', workflow)
        self.assertIn('max-parallel: 1', workflow)
        self.assertIn('timeout-minutes: 60', workflow)
        self.assertIn('RP_STYLE_TEST_GROUP: ${{ matrix.group }}', workflow)
        self.assertIn('group: ui-check-${{ github.event.pull_request.number || github.ref }}\n  cancel-in-progress: true', workflow)
        for name in ['preview-build-log', 'simulator-style-preview']:
            self.assertIn("matrix.group == 'selected' && '" + name + "' || format('" + name + "-{0}', matrix.group)", workflow)
        self.assertIn('all) TEST_ARGUMENTS=(-only-testing:RepoPocketStyleUITests)', script)
        self.assertIn('if [ "${RP_STYLE_TEST_SCOPE:-all}" = all ]; then\n  case "${RP_STYLE_TEST_GROUP:-selected}" in', script)
        cases = {f'RepoPocketStyleUITests/{name}/{method}'
                 for path in (root / 'StyleUITests').glob('*.swift')
                 for text in [path.read_text(encoding='utf-8')]
                 for name in re.findall(r'final class (\w+): XCTestCase', text)
                 for method in re.findall(r'(?m)^    func (test\w+)\(', text)}
        baseline = {case for case in cases if '/RepositoryOperationsTests/' not in case and '/RepositoryCollectionsTests/' not in case}
        self.assertEqual(len(baseline), 73, 'Keep every original UI case when adding new repository coverage')
        self.assertEqual(len({case for case in cases if '/RepositoryOperationsTests/' in case}), 4)
        self.assertEqual(len({case for case in cases if '/RepositoryCollectionsTests/' in case}), 6)
        groups = {}
        for group, count in [('boundaries-a', 25), ('boundaries-b', 24), ('editors', 34)]:
            arguments = self.selection('all', group)
            self.assertEqual(len(arguments), len(set(arguments)), group)
            only = [item.split(':', 1)[1] for item in arguments if item.startswith('-only-testing:')]
            skip = [item.split(':', 1)[1] for item in arguments if item.startswith('-skip-testing:')]
            matches = lambda case, selectors: any(case == item or case.startswith(item + '/') for item in selectors)
            groups[group] = {case for case in cases if matches(case, only) and not matches(case, skip)}
            self.assertEqual(len(groups[group]), count, group)
        self.assertEqual(set.union(*groups.values()), cases)
        self.assertEqual(sum(map(len, groups.values())), len(cases))
        scopes = ['maintenance-regressions', 'branch-merge', 'profiles', 'actions']
        combined = {item for scope in scopes for item in self.selection(scope, 'selected')}
        self.assertEqual(self.selection('all', 'boundaries-a'), sorted(combined))
        self.assertEqual(set(self.selection('all', 'boundaries-b')),
                         {'-only-testing:RepoPocketStyleUITests/StyleBoundaryTests'}
                         | {item.replace('-only-testing:', '-skip-testing:', 1) for item in combined})

    def test_focused_scope_arguments_are_unaffected_by_all_group_selection(self):
        import re
        script = (Path(__file__).resolve().parents[1] / 'Scripts/run_style_preview.sh').read_text(encoding='utf-8')
        focused = re.findall(r'(?m)^  ([a-z-]+)\)', script)
        self.assertEqual(len(focused), 20)
        self.assertEqual(self.selection('workflow-log-navigation', 'selected'), [
            '-only-testing:RepoPocketStyleUITests/WorkflowLogTests/testExplicitLineHighlightsKeepTheCompleteReadOnlyContext',
        ])
        self.assertEqual(self.selection('reading-layout', 'selected'), [
            '-only-testing:RepoPocketStyleUITests/WorkflowLogTests',
            '-only-testing:RepoPocketStyleUITests/SettingsTests',
            '-only-testing:RepoPocketStyleUITests/RepositoryCollectionsTests',
            '-only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testSharedGroupCornersSurviveRefreshAndBackNavigation',
            '-only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testReleaseAttachmentsUseNativeActionsAndInlineDownloadStates',
            '-only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testDirectRepositorySearchAndTypedUserNavigation',
        ])
        self.assertEqual(self.selection('path-time', 'selected'), [
            '-only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testRepositorySearchFindsNestedFoldersAndFilesOnSelectedBranch',
        ])
        self.assertEqual(self.selection('ui-fixes-failed', 'selected'), [
            '-only-testing:RepoPocketStyleUITests/RepositoryCollectionsTests/testPartialBatchRemovalKeepsSuccessAndOffersOnlyRemainingItems',
            '-only-testing:RepoPocketStyleUITests/SettingsTests/testProfileAndAboutStayVisibleWhileThemeAndFolderUseNativeMenu',
            '-only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testRepositorySearchFindsNestedFoldersAndFilesOnSelectedBranch',
        ])
        self.assertEqual(self.selection('ui-fixes', 'selected'), [
            '-only-testing:RepoPocketStyleUITests/RepositoryCollectionsTests',
            '-only-testing:RepoPocketStyleUITests/SettingsTests',
            '-only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testRepositorySearchFindsNestedFoldersAndFilesOnSelectedBranch',
        ])
        recheck = self.selection('regression-recheck', 'selected')
        self.assertEqual(len(recheck), 13)
        for method in ['testWorkflowFiltersAndSelectionKeepGroupedRows',
                       'testMobileEditorCreatesSavesAndGuardsUnsavedChanges',
                       'testLongCommitPatchStartsAtLeadingEdge', 'testPatchHighlightAndRawHorizontalScrolling']:
            self.assertIn('-only-testing:RepoPocketStyleUITests/StyleBoundaryTests/' + method, recheck)
        for scope in focused:
            block = script.split('  ' + scope + ')', 1)[1].split(';;', 1)[0]
            expected = re.findall(r'-only-testing:[\w/]+', block)
            for group in ['selected', 'boundaries-a', 'boundaries-b', 'editors']:
                if scope == 'all' and group != 'selected':
                    continue
                with self.subTest(scope=scope, group=group):
                    self.assertEqual(self.selection(scope, group), expected)

    def test_all_group_screenshots_are_disjoint_complete_and_do_not_change_focused_scopes(self):
        import json, os, runpy, subprocess
        script = Path(__file__).resolve().parents[1] / 'Scripts/export_style_attachments.py'
        with tempfile.TemporaryDirectory() as directory:
            config = {}
            with patch.object(sys, 'argv', ['export', 'fixture.xcresult', directory, 'all']), \
                    patch.dict(os.environ, {'RP_STYLE_TEST_GROUP': 'selected'}):
                exec(compile(script.read_text(encoding='utf-8').split('\nwhile pending:', 1)[0], str(script), 'exec'), config)
            all_names = config['expected']
            editors = ((config['upload_viewer'] - {'local-project-compact', 'local-project-information'})
                       | config['release_editor'] | config['editor_extensions'])
            boundaries = all_names - editors
            first = config['maintenance'] | config['branch_merge'] | config['profiles'] | config['actions']
            second = boundaries - first
            additions = config['repository_operations'] | config['repository_collections']
            self.assertTrue({'workflow-runs-normal', 'workflow-runs-selection', 'mobile-editor-create-menu',
                             'mobile-editor-saved-preview', 'long-patch-leading',
                             'patch-highlight-left', 'patch-highlight-right', 'patch-raw-left', 'patch-raw-right'}
                            <= config['regression_recheck'])
            self.assertEqual(len(config['repository_operations']), 4)
            self.assertEqual(len(config['repository_collections']), 6)
            self.assertEqual((len(all_names - additions), len(first), len(second), len(editors - additions)), (112, 50, 36, 26))
            self.assertEqual((len(all_names), len(editors)), (122, 36))
            self.assertEqual(first | second | editors, all_names)
            self.assertEqual(len(first) + len(second) + len(editors), len(all_names))
            tree = [{'name': {'_value': name}, 'payloadRef': {'id': {'_value': name}}}
                    for name in all_names | config['regression_recheck'] | config['ui_fixes'] | config['path_time'] | config['reading_layout'] | config['workflow_log_navigation']]
            for scope, group, expected in [('all', 'boundaries-a', first), ('all', 'boundaries-b', second),
                                           ('all', 'editors', editors),
                                           ('all', 'selected', all_names),
                                           ('regression-recheck', 'selected', config['regression_recheck']),
                                           ('ui-fixes', 'selected', config['ui_fixes']),
                                           ('ui-fixes-failed', 'selected', config['ui_fixes_failed']),
                                           ('path-time', 'selected', config['path_time']),
                                            ('reading-layout', 'selected', config['reading_layout']),
                                            ('workflow-log-navigation', 'selected', config['workflow_log_navigation']),
                                           ('upload-viewer', 'editors', config['upload_viewer']),
                                           ('release-editor', 'boundaries', config['release_editor'])]:
                with self.subTest(scope=scope, group=group), \
                        patch.object(sys, 'argv', ['export', 'fixture.xcresult', directory, scope]), \
                        patch.dict(os.environ, {'RP_STYLE_TEST_GROUP': group}), \
                        patch.object(subprocess, 'check_output', return_value=json.dumps(tree).encode()), \
                        patch.object(subprocess, 'run') as export, redirect_stdout(io.StringIO()):
                    runpy.run_path(str(script), run_name='__main__')
                paths = {Path(call.args[0][-1]).stem for call in export.call_args_list}
                optional = config['diagnostics'] & (all_names | config['regression_recheck'] | config['workflow_log_navigation'])
                self.assertEqual(paths, expected | optional)
            for group, expected in [('boundaries-a', first), ('boundaries-b', second), ('editors', editors)]:
                missing = next(iter(expected))
                tree = [{'name': {'_value': name}, 'payloadRef': {'id': {'_value': name}}}
                        for name in all_names if name != missing]
                with self.subTest(missing_from=group), \
                        patch.object(sys, 'argv', ['export', 'fixture.xcresult', directory, 'all']), \
                        patch.dict(os.environ, {'RP_STYLE_TEST_GROUP': group}), \
                        patch.object(subprocess, 'check_output', return_value=json.dumps(tree).encode()), \
                        patch.object(subprocess, 'run'), redirect_stdout(io.StringIO()), \
                        self.assertRaises(RuntimeError):
                    runpy.run_path(str(script), run_name='__main__')

    def test_maintenance_scope_exports_compact_and_fold_state_screenshots(self):
        import json, runpy, subprocess
        script = Path(__file__).resolve().parents[1] / 'Scripts/export_style_attachments.py'
        names = {'local-project-compact', 'local-project-information', 'local-branch-create-confirmation',
                 'local-history-collapsed', 'local-history-expanded', 'local-commit-detail',
                 'local-commit-patch', 'local-history-after-folding', 'local-import-destination',
                 'local-import-picker', 'local-whole-folder-import', 'local-folder-selection',
                 'upstream-watch-link-input-responsive', 'upstream-preview-retains-result',
                 'upstream-preview-retains-error', 'workflow-run-details-collapsed',
                 'workflow-run-details-after-rapid-folding', 'repository-more-after-rapid-folding',
                 'workflow-runs-normal', 'workflow-runs-selection', 'workflow-runs-partial-failure'}
        names |= {'upstream-preview-collapsed-' + mode for mode in ('empty', 'single', 'many', 'truncated')}
        names |= {prefix + mode for prefix in ('upstream-commits-expanded-', 'upstream-files-expanded-')
                  for mode in ('single', 'many', 'truncated')}
        tree = [{'name': {'_value': n}, 'payloadRef': {'id': {'_value': n}}} for n in names]
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(sys, 'argv', ['export', 'fixture.xcresult', directory, 'maintenance-regressions']), \
                patch.object(subprocess, 'check_output', return_value=json.dumps(tree).encode()), \
                patch.object(subprocess, 'run') as export, redirect_stdout(io.StringIO()):
            runpy.run_path(str(script), run_name='__main__')
        paths = {Path(call.args[0][-1]).stem for call in export.call_args_list}
        self.assertEqual(paths, names)

    def test_long_ui_commands_stream_logs_and_keep_pipefail(self):
        script = (Path(__file__).resolve().parents[1] / 'Scripts/run_style_preview.sh').read_text(encoding='utf-8')
        self.assertIn('set -euo pipefail', script)
        self.assertIn('2>&1 | tee style-test-build.log ||', script)
        self.assertIn('2>&1 | tee style-tests.log ||', script)
        self.assertIn('log show --last 30m', script)

    def test_account_addition_confirms_success_before_checking_the_active_account(self):
        source = (Path(__file__).resolve().parents[1] / 'StyleUITests/StyleBoundaryTests.swift').read_text(encoding='utf-8')
        addition = source.split('    private func exerciseAccountAddition(', 1)[1].split('\n    func ', 1)[0]
        notice = 'let authorization = app.alerts["GitHub 授权成功"]'
        self.assertIn(notice, addition)
        self.assertIn('authorization.waitForExistence(timeout: 10)', addition)
        self.assertIn('authorization.staticTexts["授权成功，账号 @fixture-charlie 已保存。"].exists', addition)
        self.assertLess(addition.index('authorization.buttons["好"].tap()'),
                        addition.index('let active = app.staticTexts["fixture-active-account"]'))
        self.assertIn("label == '303' AND hittable == true", addition)

    def test_focused_scope_keeps_all_five_failed_cases(self):
        root = Path(__file__).resolve().parents[1]
        script = (root / 'Scripts/run_style_preview.sh').read_text(encoding='utf-8')
        self.assertIn('review-regressions', (root / '.github/workflows/ui-check.yml').read_text())
        focused = script.split('  review-regressions)', 1)[1].split(';;', 1)[0]
        for name in ['testAccountTokenAdditionStillWorksAfterSwitching',
                     'testAccountTokenAdditionWorksWithoutSwitching',
                     'testLocalDEBUsesExistingEditorAndSavesToProject',
                     'testProfileContactsOpenWebFallbackAndRetryWithoutLosingProfile',
                     'testReadmeBadgesAndInAppLink']:
            self.assertIn('/' + name, focused)
        self.assertIn('all) TEST_ARGUMENTS=(-only-testing:RepoPocketStyleUITests)', script)

    def test_xcode16_attachment_commands_and_optional_failure_screenshots(self):
        import json, runpy, subprocess
        script = Path(__file__).resolve().parents[1] / 'Scripts/export_style_attachments.py'
        required = {'repository-zip-completion', 'local-project-files-long-press', 'local-deb-editor'}
        names = required | {'account-control-failure'}
        tree = [{'name': {'_value': n}, 'payloadRef': {'id': {'_value': n}}} for n in names]

        def read(command):
            self.assertEqual(command[:5], ['xcrun', 'xcresulttool', 'get', 'object', '--legacy'])
            return json.dumps(tree).encode()

        with tempfile.TemporaryDirectory() as directory, \
                patch.object(sys, 'argv', ['export', 'fixture.xcresult', directory, 'file-feedback']), \
                patch.object(subprocess, 'check_output', side_effect=read), \
                patch.object(subprocess, 'run') as export, redirect_stdout(io.StringIO()):
            runpy.run_path(str(script), run_name='__main__')
        self.assertEqual(export.call_count, len(names))
        for call in export.call_args_list:
            self.assertEqual(call.args[0][:5], ['xcrun', 'xcresulttool', 'export', 'object', '--legacy'])

    def report(self, log):
        script = (Path(__file__).resolve().parents[1] / 'Scripts/run_style_preview.sh').read_text(encoding='utf-8')
        code = script.split("<<'PY_FAILED_TESTS'\n", 1)[1].split('\nPY_FAILED_TESTS', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'style-tests.log'
            path.write_text(log, encoding='utf-8')
            output = io.StringIO()
            with patch.object(sys, 'argv', ['-', str(path)]), redirect_stdout(output):
                exec(compile(code, 'run_style_preview.sh diagnostics', 'exec'), {})
            return output.getvalue()

    def test_earlier_failure_keeps_its_full_hierarchy(self):
        failed = "Test Case '-[Suite publicContacts]' started.\nerror: contact not tappable\n"
        failed += ''.join(f'AX row {number}\n' for number in range(250))
        failed += "Test Case '-[Suite publicContacts]' failed (1.0 seconds).\n"
        passed = "Test Case '-[Suite settings]' started.\n" + 'later log\n' * 150
        passed += "Test Case '-[Suite settings]' passed (1.0 seconds).\n"
        self.assertEqual(self.report('runner setup\n' + failed + passed + 'runner summary\n'), failed)

    def test_crashed_active_case_is_not_lost(self):
        active = "Test Case '-[Suite publicContacts]' started.\nerror: runner interrupted\n"
        self.assertEqual(self.report(active), active)


if __name__ == '__main__':
    unittest.main()
