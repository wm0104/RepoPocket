"""Four distributable forms share one App build; deployment targets must agree."""
from pathlib import Path
import unittest
import hashlib
import importlib.util
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

from test_packages import fixture, pkg, sign_bytes, thin

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
        self.assertIn('cp RepoPocket.ipa RepoPocket.tipa',package)
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
        self.assertIn('MARKETING_VERSION: "1.2.3"',project)
        ent=(ROOT/'Entitlements.plist').read_text()
        self.assertIn('TROLLTROLL.com.wm0104.RepoPocket',ent)
        self.assertIn('com.apple.private.security.no-sandbox',ent)

    def test_ipa_permissions_match_exact_122_blob_and_only_two_keys_differ(self):
        old = (ROOT / 'Packaging/IPA.entitlements').read_bytes()
        self.assertEqual(hashlib.sha256(old.replace(b'\r\n', b'\n')).hexdigest(),
                         '01249246d20307f1de44132a2ce4987f6bb31cdd016c9821c120f291cc075c78')
        current = plistlib.loads((ROOT / 'Entitlements.plist').read_bytes())
        for key in ('com.apple.private.security.no-sandbox',
                    'com.apple.private.security.storage.AppDataContainers'):
            self.assertIs(current.pop(key), True)
        self.assertEqual(current, plistlib.loads(old))

    def test_ipa_signing_targets_are_isolated_from_both_debs(self):
        w = (ROOT / '.github/workflows/build.yml').read_text()
        release, probe = w.split('      - name: Package optional update probe', 1)
        block = release.split('      - name: Ad-hoc sign and package IPA', 1)[1]
        self.assertIn('cp -R "$APP" dist/Payload/', block)
        self.assertIn('IPA_APP=dist/Payload/RepoPocket.app', block)
        self.assertIn('codesign --force --sign - --entitlements Packaging/IPA.entitlements "$IPA_APP"', block)
        self.assertNotIn('--entitlements Packaging/IPA.entitlements "$APP"', block)
        self.assertEqual(block.count('Scripts/package-deb.sh --app "$APP"'), 2)
        self.assertEqual(block.count('--sign-mode preserve'), 2)
        self.assertIn('python3 Scripts/verify-ipa.py "$IPA_APP"', block)
        self.assertIn('python3 ../Scripts/verify-ipa.py verify/Payload/RepoPocket.app', block)
        self.assertIn('--entitlements Packaging/IPA.entitlements "$APP"', probe)
        self.assertNotIn('--entitlements Entitlements.plist "$APP"', probe)
        self.assertIn('python3 Scripts/verify-ipa.py "$APP"', probe)
        self.assertIn('python3 ../Scripts/verify-ipa.py verify/Payload/RepoPocket.app', probe)

    def test_mock_workflow_copy_sign_and_real_macho_permission_rejection(self):
        # Synthetic signatures exercise hashes and dictionaries, not native codesign/AMFI.
        spec = importlib.util.spec_from_file_location('ipa_audit', ROOT / 'Scripts/verify-ipa.py')
        ipa = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ipa)
        root = Path(tempfile.mkdtemp(prefix='ipa-isolation-'))
        self.addCleanup(pkg.remove_tree, root)
        app = root / 'original/RepoPocket.app'
        fixture(app)
        for bundle in (app, app / pkg.SHARE):
            info = plistlib.loads((bundle / 'Info.plist').read_bytes())
            info.update(CFBundleShortVersionString='1.2.3', CFBundleVersion='1.2.3')
            (bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
        before = pkg.snapshot(app)
        with self.assertRaisesRegex(ValueError, 'IPA signature entitlement baseline mismatch'):
            ipa.verify(app)
        for folder in ('Scripts', 'Packaging'):
            (root / folder).symlink_to(ROOT / folder, target_is_directory=True)
        tools = root / 'bin'
        tools.mkdir()
        signer = tools / 'codesign'
        signer.write_text('#!' + sys.executable + '\nimport sys, plistlib\n'
                          + f'sys.path.insert(0, {str(ROOT / "Tests")!r})\n'
                          + 'from test_packages import sign_bytes\nfrom pathlib import Path\n'
                          + 'if "--force" in sys.argv:\n'
                          + ' p = Path(sys.argv[-1]) / "RepoPocket"\n'
                          + ' ent = plistlib.loads(Path(sys.argv[sys.argv.index("--entitlements")+1]).read_bytes())\n'
                          + ' p.write_bytes(sign_bytes(p.read_bytes(), ent))\n')
        signer.chmod(0o755)
        # Exercise non-UTF8 tool diagnostics while retaining the real ZIP round trip.
        real_zip = shutil.which('zip')
        self.assertIsNotNone(real_zip)
        archiver = tools / 'zip'
        archiver.write_text('#!' + sys.executable + '\nimport os, sys\n'
                            + 'os.write(2, b"archive-output: \\xff\\n")\n'
                            + f'os.execv({real_zip!r}, [{real_zip!r}] + sys.argv[1:])\n')
        archiver.chmod(0o755)
        workflow = (ROOT / '.github/workflows/build.yml').read_text()
        block = workflow.split('          mkdir -p dist/Payload', 1)[1].split('          bash Scripts/package-deb.sh', 1)[0]
        block = 'mkdir -p dist/Payload' + block
        env = dict(os.environ, APP=str(app), PATH=str(tools) + os.pathsep + os.environ['PATH'])
        # Archive tools may emit filenames in a platform encoding. Preserve raw output;
        # only the exit status and audited archive contents determine success.
        result = subprocess.run(['bash', '-euc', block], cwd=root, env=env,
                                capture_output=True)
        self.assertEqual(result.returncode, 0, repr(result.stdout + result.stderr))
        copied = root / 'dist/verify/Payload/RepoPocket.app'
        ipa.verify(copied)
        self.assertEqual((root / 'dist/RepoPocket.ipa').read_bytes(), (root / 'dist/RepoPocket.tipa').read_bytes())
        self.assertEqual(pkg.snapshot(app), before)
        after = pkg.snapshot(copied)
        self.assertEqual(before.keys(), after.keys())
        for path in before:
            if path != 'RepoPocket':
                self.assertEqual(before[path], after[path], path)
        # Fixture has no code sections: its unsigned header/build command stays equal;
        # only LC_CODE_SIGNATURE size and embedded signature change on the main binary.
        self.assertEqual((app / 'RepoPocket').read_bytes()[:68],
                         (copied / 'RepoPocket').read_bytes()[:68])
        baseline = plistlib.loads((ROOT / 'Packaging/IPA.entitlements').read_bytes())
        bad = [dict(baseline, **{'com.apple.private.security.no-sandbox': True}),
               {key: value for key, value in baseline.items() if key != 'application-identifier'},
               dict(baseline, **{'get-task-allow': 0})]
        for ent in bad:
            (copied / 'RepoPocket').write_bytes(sign_bytes(thin(), ent))
            with self.assertRaisesRegex(ValueError, 'IPA signature entitlement baseline mismatch'):
                ipa.verify(copied)
        (copied / 'RepoPocket').write_bytes(sign_bytes(thin(), baseline))
        extension = copied / pkg.SHARE / 'RepoPocketShare'
        extension.write_bytes(sign_bytes(thin(), baseline))
        with self.assertRaisesRegex(ValueError, 'IPA signature entitlement baseline mismatch'):
            ipa.verify(copied)

if __name__=='__main__':
    unittest.main()
