"""Execute the real Foundation/CryptoKit order store; no network or UI stand-ins."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StarListLocalOrderModelTests(unittest.TestCase):
    def test_production_harness_is_connected_not_a_python_reimplementation(self):
        fixture = ROOT / 'Tests/Fixtures/StarListLocalOrderHarness.swift'
        self.assertTrue(fixture.is_file())
        source = fixture.read_text()
        self.assertIn('StarListLocalOrder(accountID:', source)
        self.assertNotIn('struct StarListLocalOrder {', source)
        self.assertIn('Data(contentsOf: first.location)', source)
        self.assertIn('not-a-directory', source)
        self.assertIn('StarListLocalOrder.removeAccount("account-A", root: root)', source)

    @unittest.skipUnless(shutil.which('swiftc'), 'swiftc unavailable: real Swift order-store harness not executed')
    def test_real_production_order_store_and_filesystem_failures(self):
        with tempfile.TemporaryDirectory(prefix='star-list-order-') as folder:
            binary = str(Path(folder) / 'star-list-order')
            subprocess.run([
                'swiftc', '-parse-as-library',
                str(ROOT / 'RepoPocket/StarListLocalOrder.swift'),
                str(ROOT / 'Tests/Fixtures/StarListLocalOrderHarness.swift'),
                '-module-cache-path', str(Path(folder) / 'ModuleCache'), '-o', binary,
            ], check=True, timeout=120)
            env = dict(os.environ, TMPDIR=folder)
            result = subprocess.run([binary], check=True, timeout=30, env=env,
                                    text=True, capture_output=True)
            self.assertEqual(result.stdout.count('PASS '), 7, result.stdout)
            print(result.stdout, end='')


if __name__ == '__main__':
    unittest.main()
