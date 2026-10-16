"""Execute the shipping Objective-C/libgit2 bridge against disposable repositories."""
from pathlib import Path
import ctypes
import json
import os
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeGitFiles(unittest.TestCase):
    def test_bridge_is_available(self):
        self.assertTrue((ROOT / 'Vendor/NativeGit/NativeGitBridge.m').is_file(),
                        'Real local Git bridge has not been implemented')


@unittest.skipUnless(platform.system() == 'Darwin', 'macOS executes the native production bridge')
class NativeGitBehavior(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.library_dir = tempfile.TemporaryDirectory()
        prefix = ROOT / 'NativeBuild/macosx'
        library = Path(cls.library_dir.name) / 'bridge.dylib'
        subprocess.run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-DRP_GIT_TESTING=1',
                        '-I' + str(prefix / 'include'), str(ROOT / 'Vendor/NativeGit/NativeGitBridge.m'),
                        '-L' + str(prefix / 'lib'), '-lgit2', '-lz', '-liconv',
                        '-framework', 'Foundation', '-framework', 'Security',
                        '-framework', 'CoreFoundation', '-o', str(library)], check=True)
        cls.native = ctypes.CDLL(str(library))
        cls.native.rp_git_execute.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        cls.native.rp_git_execute.restype = ctypes.c_void_p
        cls.native.rp_git_free.argtypes = [ctypes.c_void_p]

    @classmethod
    def tearDownClass(cls):
        cls.library_dir.cleanup()

    def git(self, *args, cwd=None):
        return subprocess.check_output(['git', '-c', 'commit.gpgsign=false', '-c', 'core.quotepath=false', *args],
                                       cwd=cwd or self.work, stderr=subprocess.STDOUT).decode().strip()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name) / '中文 project'
        self.work.mkdir()
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        (self.work / '代码.py').write_text('print("old")\n')
        (self.work / 'other.txt').write_text('unchanged\n')
        (self.work / '.gitignore').write_text('ignored\n')
        self.git('add', '.')
        self.git('commit', '-m', 'baseline')
        self.head = self.git('rev-parse', 'HEAD')

    def call(self, operation, **values):
        request = dict(repository=str(self.work / '.git'), workdir=str(self.work), **values)
        pointer = self.native.rp_git_execute(operation.encode(), json.dumps(request).encode())
        self.assertTrue(pointer)
        try:
            return json.loads(ctypes.string_at(pointer))
        finally:
            self.native.rp_git_free(pointer)

    def result(self, operation, **values):
        response = self.call(operation, **values)
        self.assertTrue(response.get('ok'), response)
        return response['result']

    def change(self):
        (self.work / '代码.py').write_text('print("new")\n')
        (self.work / 'new 空.txt').write_text('')
        (self.work / 'ignored').write_text('ignored')
        (self.work / 'other.txt').unlink()
        return self.result('status')

    def commit(self, status, paths):
        selected = [row for row in status['files'] if row['path'] in paths]
        return self.call('commit', expectedHead=status['head'], files=selected,
                         message='selected changes', authorName='Fixture', authorEmail='fixture@example.invalid')

    def test_status_unicode_ignore_deletion_empty_and_diff(self):
        status = self.change()
        self.assertEqual(status['head'], self.head)
        self.assertEqual(status['branch'], 'main')
        self.assertEqual({r['path'] for r in status['files']}, {'代码.py', 'new 空.txt', 'other.txt'})
        diff = self.result('diff', path='代码.py', expectedHead=self.head)
        self.assertIn('print("new")', diff['text'])
        self.assertIn('print("old")', diff['text'])

    def test_commit_only_selected_and_preserve_other_changes(self):
        response = self.commit(self.change(), ['代码.py', 'new 空.txt'])
        self.assertTrue(response['ok'], response)
        self.assertNotEqual(self.git('rev-parse', 'HEAD'), self.head)
        self.assertEqual(set(self.git('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD').splitlines()),
                         {'代码.py', 'new 空.txt'})
        self.assertEqual(self.git('show', 'HEAD:other.txt'), 'unchanged')
        self.assertFalse((self.work / 'other.txt').exists())
        self.assertEqual(self.git('diff', '--cached', '--name-only'), '')

    def test_changed_after_preview_and_head_change_are_rejected(self):
        status = self.change()
        (self.work / '代码.py').write_text('later edit')
        self.assertFalse(self.commit(status, ['代码.py'])['ok'])
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.head)
        status = self.result('status')
        self.git('commit', '--allow-empty', '-m', 'other tool')
        self.assertFalse(self.commit(status, ['代码.py'])['ok'])

    def test_preexisting_staging_is_preserved_and_commit_rejected(self):
        status = self.change()
        self.git('add', '代码.py')
        before = (self.work / '.git/index').read_bytes()
        self.assertFalse(self.commit(status, ['new 空.txt'])['ok'])
        self.assertEqual((self.work / '.git/index').read_bytes(), before)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.head)

    def test_symlink_and_traversal_never_read_or_commit_external_files(self):
        outside = Path(self.temp.name) / 'secret'
        outside.write_text('private fixture')
        (self.work / 'link').symlink_to(outside)
        status = self.result('status')
        self.assertFalse(self.commit(status, ['link'])['ok'])
        for path in ('../secret', '.git/config', 'link'):
            response = self.call('diff', path=path, expectedHead=self.head)
            self.assertFalse(response['ok'], response)
            self.assertNotIn('private fixture', json.dumps(response))

    def test_existing_lock_and_in_progress_operation_are_not_overwritten(self):
        status = self.change()
        lock = self.work / '.git/index.lock'
        lock.write_text('external lock')
        self.assertFalse(self.commit(status, ['代码.py'])['ok'])
        self.assertEqual(lock.read_text(), 'external lock')
        lock.unlink()
        (self.work / '.git/MERGE_HEAD').write_text(self.head + '\n')
        self.assertFalse(self.commit(status, ['代码.py'])['ok'])

    def test_binary_diff_is_bounded_and_does_not_decode_binary(self):
        (self.work / 'binary').write_bytes(b'\x00secret\x01')
        diff = self.result('diff', path='binary', expectedHead=self.head)
        self.assertTrue(diff['binary'])
        self.assertNotIn('secret', diff['text'])


if __name__ == '__main__':
    unittest.main()
