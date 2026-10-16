"""Execute the shipping Objective-C/libgit2 bridge against disposable repositories."""
from pathlib import Path
import ctypes
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time
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
        cls.library_path = str(library)
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
        request = dict(repository=str(self.work / '.git'), workdir=str(self.work), expectedRef='refs/heads/main')
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

    def test_cancelled_commit_never_updates_head_and_large_scan_is_bounded(self):
        status = self.change()
        self.assertTrue(hasattr(self.native, 'rp_git_cancel'), 'Native cancellation is missing')
        self.native.rp_git_cancel.argtypes = [ctypes.c_char_p]
        self.native.rp_git_cancel(b'cancel-fixture')
        response = self.call('commit', requestID='cancel-fixture', expectedHead=status['head'],
                             files=[status['files'][0]], message='cancel', authorName='Fixture', authorEmail='fixture@example.invalid')
        self.assertFalse(response['ok'])
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.head)
        with (self.work/'large.bin').open('wb') as handle:
            handle.truncate(129 * 1024 * 1024)
        self.assertFalse(self.call('status')['ok'], 'Scan must reject oversized work before hashing it')

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

    @unittest.skipUnless(os.environ.get('RP_GIT_NETWORK_SMOKE') == '1', 'Explicit read-only GitHub TLS smoke')
    def test_public_github_https_clone_smoke(self):
        destination=Path(self.temp.name)/'github-clone'
        cloned=self.result('clone',destination=str(destination),remote='https://github.com/wm0104/RepoPocket.git',branch='main')
        self.assertEqual(cloned['branch'],'main')
        self.assertTrue((destination/'README.md').is_file())

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

    def test_tracked_files_remain_bounded_inside_ignored_directories(self):
        folder = self.work/'tracked'
        folder.mkdir()
        (folder/'file').write_text('tracked')
        self.git('add', '.')
        self.git('commit', '-m', 'track before ignore')
        (self.work/'.gitignore').write_text('ignored\ntracked/\n')
        (folder/'file').write_text('changed tracked content')
        self.assertIn('tracked/file', {r['path'] for r in self.result('status')['files']})
        with (folder/'file').open('wb') as handle:
            handle.truncate(129 * 1024 * 1024)
        self.assertFalse(self.call('status')['ok'])

    def test_interrupted_commit_is_readable_and_recoverable_without_user_file_changes(self):
        self.assertTrue(self.commit(self.change(), ['代码.py'])['ok'])
        new = self.git('rev-parse', 'HEAD')
        prepared = self.work/'.git/repopocket-index-fixture'
        shutil.copyfile(self.work/'.git/index', prepared)
        self.git('read-tree', self.head)
        journal = self.work/'.git/repopocket-transaction.json'
        journal.write_text(json.dumps(dict(operation='commit', oldHead=self.head, newHead=new,
                                           reference='refs/heads/main', preparedIndex=prepared.name)))
        self.assertEqual(self.result('status')['repoState'], 100)
        self.result('recover', expectedHead=new)
        self.assertFalse(journal.exists())
        self.assertEqual(self.git('diff', '--cached', '--name-only'), '')
        self.assertEqual((self.work/'代码.py').read_text(), 'print("new")\n')
        self.assertFalse((self.work/'other.txt').exists())

    def test_interrupted_pull_resume_refuses_external_edits(self):
        self.make_remote()
        other = Path(self.temp.name)/'computer'
        self.git('clone', str(self.remote), str(other))
        self.git('config', 'user.name', 'Computer', cwd=other)
        self.git('config', 'user.email', 'computer@example.invalid', cwd=other)
        (other/'代码.py').write_text('remote update')
        self.git('add', '.', cwd=other)
        self.git('commit', '-m', 'remote update', cwd=other)
        self.git('push', 'origin', 'main', cwd=other)
        self.git('fetch', 'origin')
        remote_head=self.git('rev-parse', 'origin/main')
        journal=self.work/'.git/repopocket-transaction.json'
        journal.write_text(json.dumps(dict(operation='pull', oldHead=self.head, newHead=remote_head, reference='refs/heads/main')))
        (self.work/'代码.py').write_text('preserve phone edit')
        self.assertFalse(self.call('recover',expectedHead=self.head)['ok'])
        self.assertEqual((self.work/'代码.py').read_text(),'preserve phone edit')
        (self.work/'代码.py').write_text('print("old")\n')
        self.result('recover',expectedHead=self.head)
        self.assertEqual(self.git('rev-parse','HEAD'),remote_head)
        self.assertEqual((self.work/'代码.py').read_text(),'remote update')

    def test_fetch_mapping_cannot_force_update_local_heads(self):
        self.make_remote()
        other=Path(self.temp.name)/'computer'
        self.git('clone',str(self.remote),str(other))
        self.git('config','user.name','Computer',cwd=other)
        self.git('config','user.email','computer@example.invalid',cwd=other)
        self.git('commit','--allow-empty','-m','remote branch',cwd=other)
        self.git('push','origin','main',cwd=other)
        self.git('commit','--allow-empty','-m','local unpushed')
        local=self.git('rev-parse','HEAD')
        self.git('config','--replace-all','remote.origin.fetch','+refs/heads/*:refs/heads/*')
        self.result('fetch')
        self.assertEqual(self.git('rev-parse','HEAD'),local)

    def test_pull_cannot_use_another_remote_upstream(self):
        self.make_remote()
        self.git('commit','--allow-empty','-m','other cached remote')
        cached=self.git('rev-parse','HEAD')
        self.git('update-ref','refs/remotes/upstream/main',cached)
        self.git('update-ref','refs/heads/main',self.head)
        self.git('remote','add','upstream',self.remote.as_uri())
        self.git('config','branch.main.remote','upstream')
        self.assertFalse(self.call('pull',expectedHead=self.head)['ok'])
        self.assertEqual(self.git('rev-parse','HEAD'),self.head)

    def test_push_mapping_cannot_update_unrelated_local_branch(self):
        self.make_remote()
        self.git('branch','protected',self.head)
        self.git('commit','--allow-empty','-m','local push')
        current=self.git('rev-parse','HEAD')
        self.git('config','--replace-all','remote.origin.fetch','+refs/heads/main:refs/heads/protected')
        self.result('push',expectedHead=current)
        self.assertEqual(self.git('rev-parse','protected'),self.head)
        self.assertEqual(self.git('rev-parse','refs/remotes/origin/main'),current)

    def test_same_sha_other_branch_rejects_stale_commit(self):
        status=self.change()
        self.git('checkout','-b','feature')
        self.assertFalse(self.commit(status,['代码.py'])['ok'])
        self.assertEqual(self.git('rev-parse','HEAD'),self.head)

    def test_same_sha_other_branch_rejects_stale_push(self):
        self.make_remote()
        self.git('checkout','-b','feature')
        self.assertFalse(self.call('push',expectedHead=self.head)['ok'])
        self.assertEqual(self.git('rev-parse','HEAD'),self.head)

    def test_real_process_kill_recovers_only_owned_locks(self):
        for stage in ('beforeJournal','afterPublish'):
            with self.subTest(stage=stage):
                (self.work/'代码.py').write_text('stage '+stage)
                status=self.result('status')
                request=dict(repository=str(self.work/'.git'),workdir=str(self.work),expectedHead=status['head'],
                             expectedRef='refs/heads/main',files=[r for r in status['files'] if r['path']=='代码.py'],
                             authorName='Fixture',authorEmail='fixture@example.invalid',message='crash fixture',testCrashStage=stage)
                script='import ctypes,sys;lib=ctypes.CDLL(sys.argv[1]);lib.rp_git_execute.argtypes=[ctypes.c_char_p,ctypes.c_char_p];lib.rp_git_execute.restype=ctypes.c_void_p;lib.rp_git_execute(b"commit",sys.argv[2].encode())'
                child=subprocess.Popen([sys.executable,'-c',script,self.library_path,json.dumps(request)])
                marker=self.work/'.git/repopocket-test-paused'
                try:
                    deadline=time.monotonic()+8
                    while not marker.exists() and child.poll() is None and time.monotonic()<deadline:
                        time.sleep(.02)
                    self.assertTrue(marker.exists(),'Missing controlled crash boundary')
                    child.kill();child.wait(timeout=5)
                    marker.unlink()
                    self.assertTrue((self.work/'.git/index.lock').exists())
                    current=self.git('rev-parse','HEAD')
                    self.assertEqual(self.result('status')['repoState'],100)
                    if stage=='beforeJournal':
                        lock=self.work/'.git/HEAD.lock'
                        original=lock.read_text()
                        lock.write_text('another tool owns this lock')
                        self.assertFalse(self.call('recover',expectedHead=current)['ok'])
                        self.assertEqual(lock.read_text(),'another tool owns this lock')
                        lock.write_text(original)
                    self.result('recover',expectedHead=current)
                    self.assertFalse((self.work/'.git/index.lock').exists())
                    self.assertFalse((self.work/'.git/HEAD.lock').exists())
                    self.assertEqual((self.work/'代码.py').read_text(),'stage '+stage)
                finally:
                    if child.poll() is None:child.kill();child.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
