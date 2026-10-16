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
        request = dict(repository=str(self.work / '.git'), workdir=str(self.work))
        request.update(values)
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

    def make_remote(self):
        self.remote = Path(self.temp.name) / 'remote.git'
        self.git('clone', '--bare', str(self.work), str(self.remote))
        self.git('remote', 'add', 'origin', self.remote.as_uri())
        self.git('fetch', 'origin')
        self.git('branch', '--set-upstream-to', 'origin/main')

    def test_clone_and_plain_directory_association_preserve_existing_edits(self):
        self.make_remote()
        destination = Path(self.temp.name) / 'cloned'
        self.result('clone', destination=str(destination), remote=self.remote.as_uri(), branch='main')
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=destination), self.head)
        folder = Path(self.temp.name) / 'unzipped'
        folder.mkdir()
        (folder / '代码.py').write_text('edited before import')
        metadata = Path(self.temp.name) / 'private.git'
        response = self.call('associate', repository=str(metadata), workdir=str(folder),
                             remote=self.remote.as_uri(), branch='main', selectedCommit=self.head, privateGit=True)
        self.assertTrue(response['ok'], response)
        self.assertEqual((folder / '代码.py').read_text(), 'edited before import')
        self.assertFalse((folder / '.git').exists())
        status = self.call('status', repository=str(metadata), workdir=str(folder), privateGit=True)
        self.assertTrue(status['ok'], status)
        self.assertEqual({r['path'] for r in status['result']['files']}, {'代码.py', 'other.txt', '.gitignore'})

    def test_fast_forward_pull_clean_only_and_divergence_preserves_both(self):
        self.make_remote()
        other = Path(self.temp.name) / 'computer'
        self.git('clone', str(self.remote), str(other))
        self.git('config', 'user.name', 'Computer', cwd=other)
        self.git('config', 'user.email', 'computer@example.invalid', cwd=other)
        (other / 'computer.txt').write_text('from desktop')
        self.git('add', '.', cwd=other)
        self.git('commit', '-m', 'desktop', cwd=other)
        self.git('push', 'origin', 'main', cwd=other)
        (self.work / '代码.py').write_text('phone dirty')
        self.assertFalse(self.call('pull', expectedHead=self.head)['ok'])
        self.assertEqual((self.work / '代码.py').read_text(), 'phone dirty')
        (self.work / '代码.py').write_text('print("old")\n')
        self.result('pull', expectedHead=self.head)
        self.assertEqual((self.work / 'computer.txt').read_text(), 'from desktop')
        updated = self.git('rev-parse', 'HEAD')
        self.git('commit', '--allow-empty', '-m', 'phone branch')
        local = self.git('rev-parse', 'HEAD')
        self.git('commit', '--allow-empty', '-m', 'desktop branch', cwd=other)
        self.git('push', 'origin', 'main', cwd=other)
        self.assertFalse(self.call('pull', expectedHead=local)['ok'])
        self.assertFalse(self.call('push', expectedHead=local)['ok'])
        self.assertEqual(self.git('rev-parse', 'HEAD'), local)
        self.assertNotEqual(local, updated)

    def test_ignored_collision_blocks_pull_and_unsafe_pushurl_is_rejected(self):
        self.make_remote()
        (self.work / 'ignored').write_text('user file')
        other = Path(self.temp.name) / 'computer'
        self.git('clone', str(self.remote), str(other))
        self.git('config', 'user.name', 'Computer', cwd=other)
        self.git('config', 'user.email', 'computer@example.invalid', cwd=other)
        (other / 'ignored').write_text('tracked upstream')
        self.git('add', '-f', 'ignored', cwd=other)
        self.git('commit', '-m', 'add collision', cwd=other)
        self.git('push', 'origin', 'main', cwd=other)
        self.assertFalse(self.call('pull', expectedHead=self.head)['ok'])
        self.assertEqual((self.work / 'ignored').read_text(), 'user file')
        self.git('config', 'remote.origin.pushurl', 'https://attacker.invalid/owner/repo.git')
        self.assertFalse(self.call('push', expectedHead=self.head, token='fixture-secret')['ok'])
        self.assertNotIn('fixture-secret', (self.work / '.git/config').read_text())

    def test_push_creates_remote_commit_and_reports_unpushed_history(self):
        self.make_remote()
        self.assertTrue(self.commit(self.change(), ['代码.py'])['ok'])
        local = self.git('rev-parse', 'HEAD')
        self.assertEqual(self.result('history')['ahead'], 1)
        self.result('push', expectedHead=local)
        self.assertEqual(self.git('rev-parse', 'main', cwd=self.remote), local)
        self.assertEqual(self.result('history')['ahead'], 0)


if __name__ == '__main__':
    unittest.main()
