"""Linux-safe wiring/export checks; these do not replace native XCTest execution."""
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import re
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
EXPORT = ROOT / 'Scripts/export_style_attachments.py'
NAMES = {'release-editor-filled', 'release-editor-inbox', 'release-editor-attached',
         'release-editor-scrolled', 'release-editor-confirmation',
         'release-editor-account-changed', 'release-editor-denied'}


class ReleaseEditorLifecycleTests(unittest.TestCase):
    def export(self, scope, names):
        tree = [{'name': {'_value': name}, 'payloadRef': {'id': {'_value': name}}}
                for name in names]
        with tempfile.TemporaryDirectory() as output, \
                patch.object(sys, 'argv', ['export', 'fixture.xcresult', output, scope]), \
                patch.object(subprocess, 'check_output', return_value=json.dumps(tree).encode()), \
                patch.object(subprocess, 'run') as export, redirect_stdout(io.StringIO()):
            runpy.run_path(str(EXPORT), run_name='__main__')
        return {Path(call.args[0][-1]).stem for call in export.call_args_list}

    def test_release_scope_exports_exactly_its_seven_native_attachments(self):
        self.assertEqual(self.export('release-editor', NAMES | {'unrelated-screenshot'}), NAMES)

    def test_release_scope_rejects_missing_screenshots(self):
        with self.assertRaisesRegex(RuntimeError, 'Expected native UI regression screenshots'):
            self.export('release-editor', NAMES - {'release-editor-confirmation'})

    def test_all_retains_existing_scopes_and_adds_release_editor(self):
        # Evaluate only the exporter's existing scope selection, not xcresulttool.
        source = EXPORT.read_text().split('\nwhile pending:', 1)[0]
        def expected(scope):
            with tempfile.TemporaryDirectory() as output, \
                    patch.object(sys, 'argv', ['export', 'fixture.xcresult', output, scope]):
                namespace = {}
                exec(compile(source, str(EXPORT), 'exec'), namespace)
                return namespace['expected']
        all_names = expected('all')
        self.assertTrue(NAMES <= all_names)
        for scope in ('branch-merge', 'profiles', 'workflow-selection', 'actions',
                      'file-feedback', 'download-lifecycle', 'file-edit',
                      'review-regressions', 'maintenance-regressions'):
            self.assertTrue(expected(scope) <= all_names, scope)
        self.assertEqual(self.export('all', all_names), all_names)

    def test_gallery_runner_workflow_and_screenshot_names_agree(self):
        gallery = (ROOT / 'RepoPocket/StylePreviewGallery.swift').read_text()
        runner = (ROOT / 'Scripts/run_style_preview.sh').read_text()
        workflow = (ROOT / '.github/workflows/ui-check.yml').read_text()
        native = (ROOT / 'StyleUITests/ReleaseEditorTests.swift').read_text()
        self.assertIn('-release-editor-style-preview', gallery)
        self.assertIn('ReleaseEditorStylePreview()', gallery)
        self.assertIn('release-editor) TEST_ARGUMENTS=(-only-testing:RepoPocketStyleUITests/ReleaseEditorTests)', runner)
        self.assertIn('all) TEST_ARGUMENTS=(-only-testing:RepoPocketStyleUITests)', runner)
        self.assertIn('branch-merge, release-editor]', workflow)
        self.assertEqual(set(re.findall(r'screenshot\(app, "([^"]+)"\)', native)), NAMES)
        self.assertNotIn('buttons["确认保存"].tap()', native)
        self.assertIn('confirmation.buttons["取消"].tap()', native)
        self.assertIn('target.label.contains("main") && target.isEnabled', native)
        self.assertIn('Do not wait for existence before scrolling', native)

    def test_fixture_keyboard_control_only_ends_editing(self):
        fixture = (ROOT / 'RepoPocket/ReleaseEditorStylePreview.swift').read_text()
        native = (ROOT / 'StyleUITests/ReleaseEditorTests.swift').read_text()
        control = fixture.split('Button("收起键盘") {', 1)[1].split('Button("检查只读请求")', 1)[0]
        self.assertIn('UIResponder.resignFirstResponder', control)
        self.assertNotIn('ready', control)
        self.assertIn('app.buttons["release-fixture-dismiss-keyboard"].tap()', native)
        self.assertIn('object: confirmation)], timeout: 5)', native)

    def test_simulator_group_entitlements_preserve_keychain_settings(self):
        import plistlib
        runner = (ROOT / 'Scripts/run_style_preview.sh').read_text()
        code = runner.split("<<'PY_INBOX_ENTITLEMENTS'\n", 1)[1].split('\nPY_INBOX_ENTITLEMENTS', 1)[0]
        original = (ROOT / 'Scripts/Simulator.entitlements').read_bytes()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Scripts').mkdir()
            (root / 'preview-build').mkdir()
            (root / 'Scripts/Simulator.entitlements').write_bytes(original)
            subprocess.run([sys.executable, '-c', code], cwd=root, check=True)
            result = plistlib.loads((root / 'preview-build/style-preview.entitlements').read_bytes())
        expected = plistlib.loads(original)
        expected['com.apple.security.application-groups'] = ['group.com.wm0104.RepoPocket.shared']
        self.assertEqual(result, expected)
        self.assertIn('all|release-editor)', runner)
        self.assertIn('"${SIGNING_ARGUMENTS[@]}" build-for-testing', runner)

    def test_fixture_uses_real_editor_inbox_and_fail_closed_network(self):
        fixture = (ROOT / 'RepoPocket/ReleaseEditorStylePreview.swift').read_text()
        for required in ('#if DEBUG', 'ReleaseEditorView(api: api, repo: "fixture-owner/sample", original: nil, initialBranch: "main")',
                         'ShareInboxStore.live()', 'inbox.importFile(source, name: Self.attachmentName)',
                         'Data("Nonempty release editor attachment',
                         'configuration.protocolClasses = [ReleaseEditorPreviewProtocol.self]',
                         'canInit(with request: URLRequest) -> Bool { true }',
                         'url.host == "api.github.com"', 'Bearer fixture-release-editor',
                         'var status = 403', 'if method == "GET", authenticated',
                         'if method != "GET" { Self.writes += 1 }',
                         'AccountStore.activate("release-editor-other")', '-release-editor-denied'):
            self.assertIn(required, fixture)
        self.assertNotIn('URLSession.shared', fixture)
        self.assertNotIn('saveManagedRelease(', fixture)


if __name__ == '__main__':
    unittest.main()
