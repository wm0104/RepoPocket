"""Real dpkg-deb round trips with synthetic Mach-O, never executing payloads.

The test-only ldid/codesign substitutes are NOT evidence of native signing.
Run: python3 Tests/test_packages.py -v
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / 'Scripts/verify-deb.py'
spec = importlib.util.spec_from_file_location('deb_packaging', SCRIPT)
pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pkg)


def thin(cpu=0x100000c, subtype=0, minimum=0xf0000, platform=2, filetype=2):
    build = struct.pack('<6I', 0x32, 24, platform, minimum, 0x110000, 0)
    return struct.pack('<8I', 0xfeedfacf, cpu, subtype, filetype, 1, len(build), 0, 0) + build


def sign_bytes(data, entitlements):
    """Minimal ad-hoc CodeDirectory with real SHA256 page/entitlement hashes."""
    # Test input is unsigned. Reconstruct the load command table, then hash it.
    header = list(struct.unpack_from('<8I', data))
    old_commands = data[32:32 + header[5]]
    if header[4] == 2:
        old_commands = old_commands[:24]
    header[4], header[5] = 2, len(old_commands) + 16
    offset = 32 + header[5]
    ent = plistlib.dumps(entitlements)
    ent_blob = struct.pack('>II', 0xfade7171, len(ent) + 8) + ent
    hash_offset = 44 + 5 * 32
    cd_size = hash_offset + 32
    signature_size = 28 + cd_size + len(ent_blob)
    unsigned = struct.pack('<8I', *header) + old_commands + struct.pack('<4I', 0x1d, 16, offset, signature_size)
    cd = struct.pack('>9I4BI', 0xfade0c02, cd_size, 0x20001, 2, hash_offset, 0,
                     5, 1, offset, 32, 2, 0, 12, 0)
    cd += hashlib.sha256(ent_blob).digest() + bytes(4 * 32) + hashlib.sha256(unsigned).digest()
    superblob = struct.pack('>7I', 0xfade0cc0, signature_size, 2, 0, 28, 5, 28 + cd_size)
    return unsigned + superblob + cd + ent_blob


def fixture(app, signed=True):
    app.mkdir(parents=True)
    for relative, identifier, executable, template in (
        ('', pkg.APP_ID, 'RepoPocket', 'Entitlements.plist'),
        (pkg.SHARE, pkg.APP_ID + '.Share', 'RepoPocketShare', 'ShareExtension/Entitlements.plist')):
        bundle = app / relative
        bundle.mkdir(parents=True, exist_ok=True)
        info = {'CFBundleIdentifier': identifier, 'CFBundleExecutable': executable,
                'CFBundleShortVersionString': '1.2.0', 'CFBundleVersion': '1.2.0',
                'MinimumOSVersion': '15.0', 'UIFileSharingEnabled': True,
                'LSSupportsOpeningDocumentsInPlace': True}
        (bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
        entitlements = plistlib.loads((REPO / template).read_bytes())
        binary = bundle / executable
        binary.write_bytes(sign_bytes(thin(), entitlements) if signed else thin())
        binary.chmod(0o755)
    framework = app / 'Frameworks/Fixture.framework/Fixture'
    framework.parent.mkdir(parents=True)
    framework.write_bytes(sign_bytes(thin(filetype=6), {}) if signed else thin(filetype=6))
    framework.chmod(0o755)
    (app / '资源.txt').write_text('fixture resource, not a runnable App\n')


def fake_sign(arguments):
    target = Path(arguments[-1])
    if target.is_dir():
        assert arguments[0] == '-s'
        return
    ent = plistlib.loads(Path(arguments[0][2:]).read_bytes())
    target.write_bytes(sign_bytes(target.read_bytes(), ent))


@unittest.skipUnless(shutil.which('dpkg-deb'), 'install dpkg to run real archive tests')
class PackageTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='repopocket-package-test-'))
        self.addCleanup(pkg.remove_tree, self.root)
        self.app = self.root / 'input/RepoPocket.app'
        fixture(self.app)
        self.out = self.root / 'out'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        signer = self.bin / 'ldid'
        signer.write_text('#!' + sys.executable + '\nimport runpy, sys\n'
                          + f"ns = runpy.run_path({str(Path(__file__).resolve())!r}, run_name='fixture')\n"
                          + "ns['fake_sign'](sys.argv[1:])\n")
        signer.chmod(0o755)
        codesign = self.bin / 'codesign'
        codesign.write_text('#!/bin/sh\nexit 0\n')
        codesign.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ.get('PATH', ''),
                        PYTHONDONTWRITEBYTECODE='1')
        self.before = pkg.snapshot(self.app)

    def pack(self, flavor='roothide', success=True, extra=()):
        result = subprocess.run(['bash', str(REPO / 'Scripts/package-deb.sh'), '--app', str(self.app),
                                 '--output', str(self.out), '--flavor', flavor, '--sign-mode', 'preserve',
                                 *extra], capture_output=True, env=self.env)
        self.assertEqual(result.returncode == 0, success, result.stderr.decode())
        self.assertEqual(pkg.snapshot(self.app), self.before)
        self.assertFalse(list(self.out.glob('.repopocket-stage-*')))
        if not success:
            self.assertFalse(list(self.out.glob('*.deb*')))
        return self.out / f'RepoPocket_1.2.0_{pkg.FLAVORS[flavor][0]}.deb'

    def rebuild(self, deb, modify):
        root = self.root / 'repack'
        subprocess.run(['dpkg-deb', '-R', str(deb), str(root)], check=True, capture_output=True)
        modify(root)
        result = self.root / 'tampered.deb'
        subprocess.run(['dpkg-deb', '--root-owner-group', '-Zgzip', '--build', str(root), str(result)],
                       check=True, capture_output=True)
        return result

    def check_rejected(self, deb, flavor='roothide'):
        result = subprocess.run([sys.executable, str(SCRIPT), 'verify', '--deb', str(deb), '--flavor', flavor],
                                capture_output=True, env=self.env)
        self.assertNotEqual(result.returncode, 0)

    def test_real_deb_roundtrip_both_flavors(self):
        for flavor in pkg.FLAVORS:
            with self.subTest(flavor=flavor):
                deb = self.pack(flavor)
                report = json.loads(Path(str(deb) + '.verification.json').read_text())
                self.assertEqual(report['version'], '1.2.0')
                self.assertEqual(len(report['macho']), 3)
                self.assertEqual(report['deb_sha256'], hashlib.sha256(deb.read_bytes()).hexdigest())
                self.assertTrue(all(p.startswith(pkg.FLAVORS[flavor][1] + '/') for p in report['files_sha256']))
                self.assertIn(report['deb_sha256'], Path(str(deb) + '.sha256').read_text())
                result = subprocess.run([sys.executable, str(SCRIPT), 'verify', '--deb', str(deb),
                                         '--flavor', flavor], capture_output=True, env=self.env)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.check_rejected(deb, 'rootless' if flavor == 'roothide' else 'roothide')
                for path in self.out.iterdir():
                    path.unlink()

    def test_mock_ldid_signs_unsigned_copy_only(self):
        pkg.remove_tree(self.app)
        fixture(self.app, signed=False)
        self.before = pkg.snapshot(self.app)
        self.pack(extra=('--sign-mode', 'ldid'))

    def test_wrong_version(self):
        self.pack(success=False, extra=('--version', '9.9.9'))

    def test_invalid_version_control_injection(self):
        self.pack(success=False, extra=('--version', '1.2.0\nDepends: evil'))

    def test_symlink_source_or_nested(self):
        (self.app / 'escape').symlink_to(self.root)
        self.assertRaises(ValueError, pkg.snapshot, self.app)
        result = subprocess.run(['bash', str(REPO / 'Scripts/package-deb.sh'), '--app', str(self.app),
                                 '--output', str(self.out), '--flavor', 'rootless'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        (self.app / 'escape').unlink()
        self.assertEqual(pkg.snapshot(self.app), self.before)

    def test_output_inside_source(self):
        self.out = self.app / 'out'
        self.pack(success=False)

    def test_signature_tampering(self):
        binary = self.app / 'RepoPocket'
        data = bytearray(binary.read_bytes())
        data[28] ^= 1
        binary.write_bytes(data)
        self.before = pkg.snapshot(self.app)
        self.pack(success=False)

    def test_extra_macho_helper(self):
        (self.app / 'helper').write_bytes(sign_bytes(thin(), {}))
        self.before = pkg.snapshot(self.app)
        self.pack(success=False)

    def test_wrong_entitlements(self):
        ent = plistlib.loads((REPO / 'Entitlements.plist').read_bytes())
        ent[pkg.CONTAINER] = False
        (self.app / 'RepoPocket').write_bytes(sign_bytes(thin(), ent))
        self.before = pkg.snapshot(self.app)
        self.pack(success=False)

    def test_fail_during_signing_cleans_stage(self):
        (self.bin / 'ldid').write_text('#!/bin/sh\nexit 7\n')
        self.pack(success=False, extra=('--sign-mode', 'ldid'))

    def test_wrong_controls_rejected(self):
        deb = self.pack()
        def change(root):
            control = root / 'DEBIAN/control'
            control.write_text(control.read_text().replace('iphoneos-arm64e', 'iphoneos-arm64'))
        self.check_rejected(self.rebuild(deb, change))

    def test_payload_daemon_rejected(self):
        deb = self.pack()
        def change(root):
            daemon = root / 'Library/LaunchDaemons/evil.plist'
            daemon.parent.mkdir(parents=True)
            daemon.write_text('fixture')
            daemon.chmod(0o644)
        self.check_rejected(self.rebuild(deb, change))

    def test_maintainer_hook_rejected(self):
        deb = self.pack()
        def change(root):
            hook = root / 'DEBIAN/postinst'
            hook.write_text('#!/bin/sh\nexit 0\n')
            hook.chmod(0o755)
        self.check_rejected(self.rebuild(deb, change))

    def test_minimum_platform_and_architecture_all_slices(self):
        for data in (thin(minimum=0x100000), thin(cpu=0x1000007), thin(platform=7)):
            with self.subTest(data=data):
                self.assertRaises(ValueError, pkg.macho, data, False)
        first, second = thin(), thin(cpu=0x1000007)
        fat = struct.pack('>2I', 0xcafebabe, 2)
        fat += struct.pack('>5I', 0x100000c, 0, 48, len(first), 0)
        fat += struct.pack('>5I', 0x1000007, 0, 48 + len(first), len(second), 0)
        self.assertRaises(ValueError, pkg.macho, fat + first + second, False)

    def test_compatible_dual_slice_and_second_slice_signature(self):
        first, second = sign_bytes(thin(), {}), sign_bytes(thin(subtype=2), {})
        header = struct.pack('>2I', 0xcafebabe, 2)
        header += struct.pack('>5I', 0x100000c, 0, 48, len(first), 0)
        header += struct.pack('>5I', 0x100000c, 2, 48 + len(first), len(second), 0)
        self.assertEqual([x['architecture'] for x in pkg.macho(header + first + second, True)],
                         ['arm64', 'arm64e'])
        second = bytearray(second)
        second[28] ^= 1
        self.assertRaises(ValueError, pkg.macho, header + first + second, True)

    def test_legacy_minimum_command(self):
        header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 16, 0, 0)
        good = header + struct.pack('<4I', 0x25, 16, 0xe0000, 0xf0000)
        self.assertEqual(pkg.macho(good, False)[0]['minimum_os'], '14.0.0')
        bad = header + struct.pack('<4I', 0x25, 16, 0x100000, 0x110000)
        self.assertRaises(ValueError, pkg.macho, bad, False)

    def test_nested_framework_minimum_rejected(self):
        path = self.app / 'Frameworks/Fixture.framework/Fixture'
        path.write_bytes(sign_bytes(thin(minimum=0x100000, filetype=6), {}))
        self.before = pkg.snapshot(self.app)
        self.pack(success=False)

    def test_32bit_hidden_resource_rejected(self):
        (self.app / 'Frameworks/32bit.dylib').write_bytes(b'\xce\xfa\xed\xfe' + bytes(40))
        self.before = pkg.snapshot(self.app)
        self.pack(success=False)

    def test_archive_symlink_rejected(self):
        deb = self.pack()
        self.check_rejected(self.rebuild(deb, lambda root: (root / 'Applications/RepoPocket.app/link').symlink_to('/etc')))

    def test_bundle_minimum_rejected(self):
        info_path = self.app / pkg.SHARE / 'Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['MinimumOSVersion'] = '16.0'
        info_path.write_bytes(plistlib.dumps(info))
        self.before = pkg.snapshot(self.app)
        self.pack(success=False)


class LegacyDebFixtureTests(unittest.TestCase):
    def test_normal_control_directory_has_traversal_permission(self):
        import ast
        import io
        import tarfile
        # Execute the production fixture generator function without creating its files.
        path = REPO / 'DebControlEditorTests/fixtures.py'
        module = ast.parse(path.read_text())
        generator = next(node for node in module.body if isinstance(node, ast.FunctionDef) and node.name == 'tar')
        namespace = {'io': io, 'tarfile': tarfile, 'control': b'Package: fixture\n'}
        exec(compile(ast.Module(body=[generator], type_ignores=[]), str(path), 'exec'), namespace)
        with tarfile.open(fileobj=io.BytesIO(namespace['tar']())) as archive:
            self.assertEqual(archive.getmember('.').mode, 0o755)
            self.assertEqual(archive.getmember('./control').mode, 0o644)
            self.assertEqual(archive.getmember('./postinst').mode, 0o755)


if __name__ == '__main__':
    unittest.main()
