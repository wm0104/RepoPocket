"""IPA/TIPA retain the verified 1.2.2 sandbox signature; privileged audits stay explicit."""
from pathlib import Path
import importlib.util
import plistlib
import tempfile
import unittest

from test_packages import fixture, sign_bytes, thin

ROOT = Path(__file__).resolve().parents[1]


class TrollStorePackageVariantTests(unittest.TestCase):
    def test_tipa_keeps_the_verified_122_sandbox_ipa_baseline(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text(encoding='utf-8')
        self.assertIn('cp RepoPocket.ipa RepoPocket.tipa', workflow)
        self.assertIn('cmp RepoPocket.ipa RepoPocket.tipa', workflow)
        self.assertNotIn('dist/trollstore/Payload/', workflow)
        self.assertIn('Scripts/verify-ipa.py verify/Payload/RepoPocket.app', workflow)
        self.assertIn('codesign --force --sign - --entitlements Packaging/IPA.entitlements "$IPA_APP"', workflow)

    def test_actual_macho_signatures_require_the_exact_template_for_each_variant(self):
        spec = importlib.util.spec_from_file_location('variant_audit', ROOT / 'Scripts/verify-ipa.py')
        audit = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(audit)
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'RepoPocket.app'
            fixture(app)
            audit.verify(app, trollstore=True)
            with self.assertRaises(ValueError):
                audit.verify(app)
            baseline = plistlib.loads((ROOT / 'Packaging/IPA.entitlements').read_bytes())
            (app / 'RepoPocket').write_bytes(sign_bytes(thin(), baseline))
            audit.verify(app)
            with self.assertRaises(ValueError):
                audit.verify(app, trollstore=True)
            # No privilege is inherited by the share extension in either variant.
            full = plistlib.loads((ROOT / 'Entitlements.plist').read_bytes())
            (app / 'RepoPocket').write_bytes(sign_bytes(thin(), full))
            (app / audit.deb.SHARE / 'RepoPocketShare').write_bytes(sign_bytes(thin(), full))
            with self.assertRaises(ValueError):
                audit.verify(app, trollstore=True)


if __name__ == '__main__':
    unittest.main()
