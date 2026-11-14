"""Check the pinned, repeatable libgit2 attribute parser patch."""
from pathlib import Path
import hashlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Scripts'))
import patch_native_git as native_patch


class NativeGitPatch(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.target = Path(self.directory.name) / 'attr_file.c'
        self.original = b'#include <ctype.h>\n' + b'git__isspace(c);\n' * 7
        self.expected = (b'#include <ctype.h>\n' + native_patch.ASCII_SPACE
                         + b'attr_is_ascii_space(c);\n' * 7)

    def apply_fixture(self):
        with patch.multiple(native_patch,
                            ORIGINAL_SHA256=hashlib.sha256(self.original).hexdigest(),
                            PATCHED_SHA256=hashlib.sha256(self.expected).hexdigest()):
            return native_patch.apply_patch(self.target)

    def test_original_is_patched_once_and_repeated_call_does_not_write(self):
        self.target.write_bytes(self.original)
        self.assertEqual(self.apply_fixture(), hashlib.sha256(self.expected).hexdigest())
        self.assertEqual(self.target.read_bytes(), self.expected)
        self.target.touch()
        before = self.target.stat().st_mtime_ns
        self.apply_fixture()
        self.assertEqual(self.target.stat().st_mtime_ns, before)

    def test_unknown_source_is_rejected_without_writes(self):
        self.target.write_bytes(self.original + b'unknown edit\n')
        before = self.target.read_bytes()
        with self.assertRaisesRegex(ValueError, 'Unexpected libgit2'):
            self.apply_fixture()
        self.assertEqual(self.target.read_bytes(), before)

    def test_unexpected_patch_output_is_rejected_without_writes(self):
        self.target.write_bytes(self.original)
        with patch.object(native_patch, 'ORIGINAL_SHA256', hashlib.sha256(self.original).hexdigest()):
            with self.assertRaisesRegex(ValueError, 'patch output'):
                native_patch.apply_patch(self.target)
        self.assertEqual(self.target.read_bytes(), self.original)

    def test_all_native_caches_include_the_patch_and_build_always_applies_it(self):
        for name in ('build.yml', 'local-git-check.yml', 'ui-check.yml'):
            workflow = (ROOT / '.github/workflows' / name).read_text(encoding='utf-8')
            self.assertIn("hashFiles('Scripts/build_native_git.sh', 'Scripts/patch_native_git.py')", workflow)
        build = (ROOT / 'Scripts/build_native_git.sh').read_text(encoding='utf-8')
        self.assertLess(build.index('shasum -a 256 --check'), build.index('patch_native_git.py'))
        self.assertLess(build.index('then tar -xzf'), build.index('patch_native_git.py'))
        self.assertLess(build.index('patch_native_git.py'), build.index('cmake -S'))

    @unittest.skipUnless(shutil.which('cc'), 'A C compiler is needed for the actual byte classifier')
    def test_ascii_helper_classifies_all_byte_values(self):
        source = self.target.with_suffix('.c')
        binary = self.target.with_suffix('.out')
        source.write_bytes(b'#include <stdbool.h>\n' + native_patch.ASCII_SPACE + b'''
int main(void) {
    for (int c = 0; c < 256; c++) {
        int expected = c == 32 || (c >= 9 && c <= 13);
        if (attr_is_ascii_space((unsigned char)c) != expected) return 1;
    }
    return 0;
}
''')
        subprocess.run(['cc', '-std=c99', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)

    def test_pinned_upstream_file_has_the_exact_approved_patch(self):
        archive = ROOT / 'NativeBuild/source/libgit2-1.9.7.tar.gz'
        if not archive.is_file():
            self.skipTest('Pinned source archive is available after the native preparation step')
        with tarfile.open(archive) as source:
            name = 'libgit2-49e408b3208bc3093757a1c2db938d3590f3f412/src/libgit2/attr_file.c'
            original = source.extractfile(name).read()
        self.assertEqual(hashlib.sha256(original).hexdigest(), native_patch.ORIGINAL_SHA256)
        self.assertEqual(original.count(b'git__isspace('), 7)
        self.target.write_bytes(original)
        self.assertEqual(native_patch.apply_patch(self.target), native_patch.PATCHED_SHA256)
        result = self.target.read_bytes()
        self.assertNotIn(b'git__isspace(', result)
        self.assertEqual(result.count(b'attr_is_ascii_space('), 8)
        native_patch.apply_patch(self.target)
        self.assertEqual(self.target.read_bytes(), result)


if __name__ == '__main__':
    unittest.main()
