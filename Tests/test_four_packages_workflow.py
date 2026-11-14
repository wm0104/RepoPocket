"""Four distributable forms share one App build; deployment targets must agree."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class FourPackageWorkflowTests(unittest.TestCase):
    def test_minimum_os_and_native_libraries_agree(self):
        self.assertIn('iOS: "15.0"', (ROOT/'project.yml').read_text())
        self.assertIn('CMAKE_OSX_DEPLOYMENT_TARGET=15.0', (ROOT/'Scripts/build_native_git.sh').read_text())
        workflow=(ROOT/'.github/workflows/build.yml').read_text()
        self.assertIn('Print :MinimumOSVersion', workflow)
        self.assertIn('= "15.0"', workflow)
        self.assertNotIn('CMAKE_OSX_DEPLOYMENT_TARGET=16.0', (ROOT/'Scripts/build_native_git.sh').read_text())

    def test_four_artifacts_checksums_and_validation_gate(self):
        w=(ROOT/'.github/workflows/build.yml').read_text()
        package=w.split('      - name: Ad-hoc sign and package IPA',1)[1].split('      - name: Package optional update probe',1)[0]
        for name in ['RepoPocket.ipa','RepoPocket.tipa','iphoneos-arm64e.deb','iphoneos-arm64.deb','SHA256SUMS']:
            self.assertIn(name,package)
        self.assertIn('cmp RepoPocket.ipa RepoPocket.tipa',package)
        self.assertIn('shasum -a 256 -c SHA256SUMS',package)
        self.assertIn('Scripts/package-deb.sh',package)
        self.assertIn('roothide',package)
        self.assertIn('rootless',package)
        self.assertIn('if: ${{ !inputs.validate_only }}',package)
        self.assertNotIn('gh release',w)
        self.assertNotIn('contents: write',w)

    def test_original_identity_and_trollstore_entitlements_unchanged(self):
        project=(ROOT/'project.yml').read_text()
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER: com.wm0104.RepoPocket',project)
        self.assertIn('MARKETING_VERSION: "1.2.1"',project)
        ent=(ROOT/'Entitlements.plist').read_text()
        self.assertIn('TROLLTROLL.com.wm0104.RepoPocket',ent)
        self.assertNotIn('no-sandbox',ent)

if __name__=='__main__':
    unittest.main()
