from pathlib import Path
import plistlib, unittest

ROOT = Path(__file__).resolve().parents[1]


class CurrentReleaseVersionTests(unittest.TestCase):
    def test_app_and_extension_share_the_requested_release_version(self):
        project = (ROOT / 'project.yml').read_text()
        for key in ('MARKETING_VERSION', 'CURRENT_PROJECT_VERSION'):
            self.assertRegex(project, rf'{key}: "1\.2\.1"')
        self.assertEqual(project.count('CFBundleShortVersionString: "$(MARKETING_VERSION)"'), 2)
        self.assertEqual(project.count('CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"'), 2)
        self.assertIn('iOS: "15.0"', project)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER: com.wm0104.RepoPocket', project)
        with (ROOT / 'Entitlements.plist').open('rb') as stream:
            entitlements = plistlib.load(stream)
        self.assertIn('TROLLTROLL.com.wm0104.RepoPocket', str(entitlements))
        self.assertNotIn('com.apple.private.security.no-sandbox', entitlements)

    def test_package_gate_checks_the_same_current_version(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text()
        for target in ('APP', 'EXT'):
            for field in ('CFBundleShortVersionString', 'CFBundleVersion'):
                self.assertIn(f'Print :{field}\' "${target}/Info.plist")" = "1.2.1"', workflow)
        for architecture in ('arm64e', 'arm64'):
            self.assertIn(f'RepoPocket_1.2.1_iphoneos-{architecture}.deb', workflow)
            self.assertNotIn(f'RepoPocket_1.2.0_iphoneos-{architecture}.deb', workflow)
        control = (ROOT / 'Packaging/control.in').read_text()
        self.assertIn('Version: {version}', control)
        self.assertRegex(control, r'X-RepoPocket-Changelog: 1\.2\.1 \| \d{4}-\d{2}-\d{2} \| ')


if __name__ == '__main__':
    unittest.main()
