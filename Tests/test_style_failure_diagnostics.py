from contextlib import redirect_stdout
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


class StyleFailureDiagnosticsTests(unittest.TestCase):
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
