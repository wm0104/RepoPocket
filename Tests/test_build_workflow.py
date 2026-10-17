"""Validate test-branch CI entry points without requiring an Apple SDK."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import unittest


class BuildWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(REPO_ROOT, '.github/workflows/build.yml').read_text()

    def test_test_branches_build_on_push(self):
        self.assertNotIn("  push:", self.source)

    def test_pull_requests_and_manual_dispatch(self):
        self.assertNotIn('  pull_request:', self.source)
        self.assertIn('  workflow_dispatch:', self.source)

    def test_read_only_permissions_and_apple_runner(self):
        self.assertIn('permissions:\n  contents: read', self.source)
        self.assertIn('runs-on: macos-14', self.source)
        self.assertNotIn('contents: write', self.source)
        self.assertNotIn('gh release', self.source)
        self.assertNotIn('softprops/action-gh-release', self.source)
        self.assertIn('Print :CFBundleVersion\' "$APP/Info.plist")" = "4"', self.source)
        self.assertIn('Print :CFBundleShortVersionString\' "$APP/Info.plist")" = "1.0.6"', self.source)
        project = (REPO_ROOT / 'project.yml').read_text()
        self.assertIn('MARKETING_VERSION: "1.0.6"', project)
        self.assertIn('CURRENT_PROJECT_VERSION: "12"', project)

    def test_release_version_is_readable_by_installed_1_0_5(self):
        import re
        project = (REPO_ROOT / 'project.yml').read_text()
        version = re.search(r'MARKETING_VERSION: "([^"]+)"', project).group(1)
        # Shipping 1.0.5 rejects four-part version tags before comparison.
        self.assertRegex(version, r'^\d+\.\d+\.\d+$',
                         'A three-part release is needed for the installed 1.0.5 updater')

    def test_system_default_refresh_rate(self):
        project = (REPO_ROOT / 'project.yml').read_text()
        self.assertNotIn('CADisableMinimumFrameDurationOnPhone:', project)
        self.assertIn('Print :CADisableMinimumFrameDurationOnPhone', self.source)
        self.assertNotIn('Print :CADisableMinimumFrameDurationOnPhone\' "$APP/Info.plist")" = "true"', self.source)
        # Do not replace the opt-in with a permanent display link or FPS hook.
        for path in (REPO_ROOT / 'RepoPocket').glob('*.swift'):
            source = path.read_text()
            self.assertNotIn('CADisplayLink(', source, path.name)
            self.assertNotIn('preferredFramesPerSecond = 120', source, path.name)

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

    def test_optional_update_probe_keeps_release_artifact_separate(self):
        self.assertIn('build_update_probe:', self.source)
        self.assertIn('default: false', self.source)
        self.assertIn('if: ${{ inputs.build_update_probe && !inputs.validate_only }}', self.source)
        self.assertIn('Set :CFBundleShortVersionString 1.0.3-rc.1', self.source)
        self.assertIn("Set :CFBundleVersion 4", self.source)
        self.assertIn('codesign --force --sign - --entitlements Entitlements.plist "$APP"', self.source)
        self.assertIn('codesign --verify --deep --strict verify/Payload/RepoPocket.app', self.source)
        self.assertIn('name: RepoPocket-update-probe', self.source)
        self.assertIn('probe/RepoPocket-1.0.3-rc.1.ipa.sha256', self.source)
        self.assertNotIn('gh release', self.source)

    def test_validation_only_never_packages_or_uploads_an_ipa(self):
        self.assertIn('validate_only:', self.source)
        package = self.source.split('      - name: Ad-hoc sign and package IPA', 1)[1]
        package = package.split('      - name: Package optional update probe', 1)[0]
        self.assertEqual(package.count('if: ${{ !inputs.validate_only }}'), 2)
        self.assertEqual(self.source.count('if: ${{ inputs.build_update_probe && !inputs.validate_only }}'), 2)
        compile_step = self.source.split('      - name: Compile iOS app', 1)[1].split('      - name: Ad-hoc sign', 1)[0]
        self.assertNotIn('if:', compile_step)

    def test_compile_and_package_verification_remain_enabled(self):
        commands = self.source
        for required in ('xcodebuild', 'CODE_SIGNING_ALLOWED=NO',
                         'codesign --verify --deep --strict',
                         'unzip -t RepoPocket.ipa',
                         'shasum -a 256 -c RepoPocket.ipa.sha256'):
            self.assertIn(required, commands)
        self.assertIn('uses: actions/upload-artifact@v4', commands)
        self.assertIn('name: RepoPocket', commands)


if __name__ == '__main__':
    unittest.main()
