"""Validate test-branch CI entry points without requiring an Apple SDK."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import unittest


class BuildWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(REPO_ROOT, '.github/workflows/build.yml').read_text()

    def test_test_branches_build_on_push(self):
        self.assertIn("push:\n    branches: [main, 'test/**']", self.source)

    def test_pull_requests_and_manual_dispatch(self):
        self.assertIn('pull_request:\n    branches: [main]', self.source)
        self.assertIn('  workflow_dispatch:', self.source)

    def test_read_only_permissions_and_apple_runner(self):
        self.assertIn('permissions:\n  contents: read', self.source)
        self.assertIn('runs-on: macos-14', self.source)

    def test_python_scripts_use_organized_existing_paths(self):
        import re
        scripts = set((REPO_ROOT / 'Tests').glob('test_*.py'))
        commands = re.findall(r'run: python3 (\S+)', self.source)
        self.assertEqual(len(commands), len(scripts))
        self.assertEqual({REPO_ROOT / command for command in commands}, scripts)
        self.assertTrue(all(command.startswith('Tests/test_') for command in commands))
        self.assertFalse(list(REPO_ROOT.glob('test_*.py')))
        self.assertTrue((REPO_ROOT / 'tests/MetadataTextFixture.swift').is_file())
        self.assertTrue((REPO_ROOT / 'tests/WorkspaceZIP-original.swift.txt').is_file())
        self.assertIn('sh DebControlEditorTests/run-macos.sh', self.source)

    def test_compile_and_package_verification_remain_enabled(self):
        commands = self.source
        for required in ('xcodebuild', 'CODE_SIGNING_ALLOWED=NO',
                         'codesign --verify --deep --strict',
                         'unzip -t RepoPocket.ipa',
                         'shasum -a 256 -c RepoPocket.ipa.sha256'):
            self.assertIn(required, commands)
        self.assertIn('uses: actions/upload-artifact@v4', commands)
        self.assertIn('name: RepoPocket-iOS16-Test', commands)


if __name__ == '__main__':
    unittest.main()
