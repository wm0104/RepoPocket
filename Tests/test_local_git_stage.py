"""Stage tests: static contracts everywhere; production ObjC/libgit2 FFI on macOS.
No CLI implementation substitutes for native behavior. Git CLI only prepares/asserts fixtures.
The FFI translation unit copies the real production bridge; missing dispatch integration fails closed.
"""
from pathlib import Path
import ctypes
import json
import os
import platform
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
STAGE = ROOT / 'Vendor/NativeGit/NativeGitStage.inc'
def integration_source():
    source = (ROOT / 'Vendor/NativeGit/NativeGitBridge.m').read_text()
    assert '#include "NativeGitStage.inc"' in source, 'stage must be included in the production bridge'
    for operation in ('stageStatus', 'stageDiff', 'stage', 'unstage', 'commitStaged'):
        assert 'isEqual:@"' + operation + '"' in source, operation + ' must be registered in production'
    return source


class StageContracts(unittest.TestCase):
    def test_bridge_boundaries(self):
        text = STAGE.read_text()
        for expected in ['RPStageExpected', 'RPStageSelected', 'O_EXCL', 'RPLeaseCapture',
                         'RPStageUnlock', 'owned.st_ino==current.st_ino', 'RPLockHead',
                         'git_diff_tree_to_index', 'git_diff_index_to_workdir',
                         'RPStagePrepare', 'rename(temporary', 'RPIsCancelled',
                         'GIT_INDEX_ENTRY_INTENT_TO_ADD', 'GIT_INDEX_ENTRY_SKIP_WORKTREE']:
            self.assertIn(expected, text)
        for forbidden in ['git_reset', 'git_checkout', 'git_remote_push', 'system(', 'NSTask', 'git_index_write(index)']:
            self.assertNotIn(forbidden, text)
        self.assertIn('No subprocesses', text)
        self.assertIn('@"operation":@"commit"', text)
        self.assertIn('RPCommitStaged(repo,q,c)', integration_source())

    def test_ui_has_one_panel_and_two_diff_directions(self):
        ui = (ROOT / 'RepoPocket/LocalGitStageView.swift').read_text()
        for value in ['NativeActionMenu', 'SoftGroupRows', 'HEAD → index', 'index → 工作区',
                      'localGit.authorName', 'localGit.authorEmail', '@Binding var message',
                      'api.isCurrentSession', 'Task.checkCancellation()', 'commitStaged']:
            self.assertIn(value, ui)
        self.assertNotIn('Menu {', ui)
        self.assertIn('.autocorrectionDisabled()', ui)
        for newer_api in ['.navigationDestination(', '.presentationDetents(', '.contentTransition(', '.scrollContentBackground(']:
            self.assertNotIn(newer_api, ui)
        self.assertIn('struct LocalGitStageStatus: Decodable', (ROOT / 'RepoPocket/LocalGitStageModels.swift').read_text())


    def test_production_stage_routes_and_single_project_entry(self):
        bridge = integration_source()
        self.assertIn('RPStageStatus(repo,q,c)', bridge)
        self.assertIn('RPStageDiff(repo,q,c)', bridge)
        self.assertIn('RPScanBudget(repo,requestID,c)', bridge)
        engine = (ROOT / 'RepoPocket/LocalGitEngine.swift').read_text()
        writing = engine.split('writing: [', 1)[1].split('].contains(operation)', 1)[0]
        for operation in ('stage', 'unstage', 'commitStaged'):
            self.assertIn('"' + operation + '"', writing)
        project = (ROOT / 'RepoPocket/LocalProjectView.swift').read_text()
        self.assertEqual(project.count('LocalGitStageView('), 1)
        self.assertEqual(project.count('localgit.stage-panel'), 1)
        self.assertIn('snapshot.status.repoState != 0 || snapshot.status.mergePending == true', project)
        self.assertIn('if !snapshot.status.files.isEmpty && snapshot.status.staged.isEmpty', project)
        self.assertIn('"mergePending"', (ROOT / 'Vendor/NativeGit/NativeGitStage.inc').read_text())


@unittest.skipUnless(platform.system() == 'Darwin', 'requires macOS Foundation + production libgit2; no CLI-model substitute')
class StageNative(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='repopocket-stage-ffi-')
        cls.addClassCleanup(cls.build.cleanup)
        prefix = Path(os.environ.get('RP_NATIVE_PREFIX', str(ROOT / 'NativeBuild/macosx')))
        if not (prefix / 'include/git2.h').is_file():
            raise unittest.SkipTest('native dependency missing: set RP_NATIVE_PREFIX to external macOS libgit2 build')
        source = Path(cls.build.name) / 'NativeGitBridge.m'
        source.write_text(integration_source())
        cls.library_path = str(Path(cls.build.name) / 'bridge.dylib')
        subprocess.run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-DRP_GIT_TESTING=1',
                        '-I' + str(ROOT / 'Vendor/NativeGit'), '-I' + str(prefix / 'include'), str(source),
                        '-L' + str(prefix / 'lib'), '-lgit2', '-lz', '-liconv',
                        '-framework', 'Foundation', '-framework', 'Security', '-framework', 'CoreFoundation',
                        '-o', cls.library_path], check=True)
        cls.native = ctypes.CDLL(cls.library_path)
        cls.native.rp_git_execute.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        cls.native.rp_git_execute.restype = ctypes.c_void_p
        cls.native.rp_git_free.argtypes = [ctypes.c_void_p]
        cls.native.rp_git_cancel.argtypes = [ctypes.c_char_p]

    def git(self, *args):
        return subprocess.check_output(['git', '-c', 'commit.gpgsign=false', *args], cwd=self.work, stderr=subprocess.STDOUT).decode().strip()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='repopocket-stage-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name) / '中文 project'
        self.work.mkdir()
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        (self.work / 'a.txt').write_text('old a\n')
        (self.work / 'b.txt').write_text('old b\n')
        self.git('add', '.')
        self.git('commit', '-m', 'fixture baseline')
        self.head = self.git('rev-parse', 'HEAD')

    def call(self, op, **args):
        request = dict(repository=str(self.work / '.git'), workdir=str(self.work), expectedRef='refs/heads/main')
        request.update(args)
        pointer = self.native.rp_git_execute(op.encode(), json.dumps(request).encode())
        self.assertTrue(pointer)
        try:
            return json.loads(ctypes.string_at(pointer))
        finally:
            self.native.rp_git_free(pointer)

    def result(self, op, **args):
        reply = self.call(op, **args)
        self.assertTrue(reply['ok'], reply)
        return reply['result']

    def snapshot(self):
        return self.result('stageStatus')

    def args(self, snapshot=None, paths=(), side='unstaged'):
        snapshot = snapshot or self.snapshot()
        return dict(expectedHead=snapshot['head'], expectedRef=snapshot['reference'],
                    indexFingerprint=snapshot['indexFingerprint'],
                    files=[row for row in snapshot[side] if row['path'] in paths])

    def author(self):
        return dict(authorName='Fixture', authorEmail='fixture@example.invalid', message='staged snapshot')

    def test_stage_only_explicit_files_then_unstage_preserves_worktree(self):
        (self.work / 'a.txt').write_text('stage a\n')
        (self.work / 'b.txt').write_text('leave b\n')
        self.result('stage', **self.args(paths=['a.txt']))
        self.assertEqual(self.git('diff', '--cached', '--name-only'), 'a.txt')
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.head)
        self.result('unstage', **self.args(paths=['a.txt'], side='staged'))
        self.assertEqual(self.git('diff', '--cached', '--name-only'), '')
        self.assertEqual((self.work / 'a.txt').read_text(), 'stage a\n')
        self.assertEqual((self.work / 'b.txt').read_text(), 'leave b\n')

    def test_commit_uses_index_not_later_worktree_and_keeps_index_bytes(self):
        (self.work / 'a.txt').write_text('staged a\n')
        self.result('stage', **self.args(paths=['a.txt']))
        (self.work / 'a.txt').write_text('later unstaged a\n')
        (self.work / 'b.txt').write_text('unrelated b\n')
        before_index = (self.work / '.git/index').read_bytes()
        status = self.snapshot()
        self.assertEqual({x['path'] for x in status['staged']}, {'a.txt'})
        self.assertEqual({x['path'] for x in status['unstaged']}, {'a.txt', 'b.txt'})
        self.result('commitStaged', **self.args(status), **self.author())
        self.assertEqual(self.git('show', 'HEAD:a.txt'), 'staged a')
        self.assertEqual(self.git('show', 'HEAD:b.txt'), 'old b')
        self.assertEqual((self.work / 'a.txt').read_text(), 'later unstaged a\n')
        self.assertEqual((self.work / '.git/index').read_bytes(), before_index)
        self.assertEqual(self.git('diff', '--cached', '--name-only'), '')

    def test_new_and_deleted_entries_can_be_unstaged(self):
        (self.work / 'new file.txt').write_text('new\n')
        (self.work / 'a.txt').unlink()
        self.result('stage', **self.args(paths=['new file.txt', 'a.txt']))
        self.assertEqual(self.git('diff', '--cached', '--name-only').splitlines(), ['a.txt', 'new file.txt'])
        self.result('unstage', **self.args(paths=['a.txt', 'new file.txt'], side='staged'))
        self.assertEqual(self.git('diff', '--cached', '--name-only'), '')
        self.assertFalse((self.work / 'a.txt').exists())
        self.assertEqual((self.work / 'new file.txt').read_text(), 'new\n')

    def test_separate_diff_directions(self):
        (self.work / 'a.txt').write_text('stage a\n')
        self.result('stage', **self.args(paths=['a.txt']))
        (self.work / 'a.txt').write_text('later a\n')
        status = self.snapshot()
        for side in ['staged', 'unstaged']:
            row = next(x for x in status[side] if x['path'] == 'a.txt')
            args = self.args(status)
            args.update(path='a.txt', side=side, fingerprint=row['fingerprint'])
            diff = self.result('stageDiff', **args)
            if side == 'staged':
                self.assertIn('-old a', diff['text']); self.assertIn('+stage a', diff['text'])
                self.assertNotIn('later a', diff['text'])
            else:
                self.assertIn('-stage a', diff['text']); self.assertIn('+later a', diff['text'])
                self.assertNotIn('old a', diff['text'])

    def test_stale_work_index_head_and_unknown_lock_refused(self):
        (self.work / 'a.txt').write_text('first\n')
        args = self.args(paths=['a.txt'])
        (self.work / 'a.txt').write_text('second\n')
        self.assertFalse(self.call('stage', **args)['ok'])
        args = self.args(paths=['a.txt'])
        self.git('add', 'b.txt')  # no content change, then introduce a genuine external index change
        (self.work / 'b.txt').write_text('external\n'); self.git('add', 'b.txt')
        index = (self.work / '.git/index').read_bytes()
        self.assertFalse(self.call('stage', **args)['ok'])
        self.assertEqual((self.work / '.git/index').read_bytes(), index)
        args = self.args(paths=['a.txt'])
        lock = self.work / '.git/index.lock'; lock.write_text('foreign lock')
        self.assertFalse(self.call('stage', **args)['ok'])
        self.assertEqual(lock.read_text(), 'foreign lock'); lock.unlink()
        args['expectedHead'] = '0' * 40
        self.assertFalse(self.call('stage', **args)['ok'])

    def test_pre_cancelled_write_refused_and_selected_commit_not_used_for_staged(self):
        (self.work / 'a.txt').write_text('changed\n')
        args = self.args(paths=['a.txt']); args['requestID'] = 'stage-cancel-fixture'
        self.native.rp_git_cancel(b'stage-cancel-fixture')
        self.assertFalse(self.call('stage', **args)['ok'])
        self.assertEqual(self.git('diff', '--cached', '--name-only'), '')
        args.pop('requestID'); self.result('stage', **args)
        self.assertFalse(self.call('commit', **self.args(paths=['a.txt'], side='staged'), **self.author())['ok'])

    def test_lfs_symlink_merge_interrupted_and_invalid_paths_rejected(self):
        (self.work / '.gitattributes').write_text('a.txt filter=lfs\n')
        (self.work / 'a.txt').write_text('changed\n')
        status = self.snapshot()
        self.assertTrue(next(x for x in status['unstaged'] if x['path'] == 'a.txt')['blocked'])
        self.assertFalse(self.call('stage', **self.args(status, paths=['a.txt']))['ok'])
        (self.work / '.gitattributes').unlink()
        (self.work / 'link').symlink_to(self.work / 'a.txt')
        status = self.snapshot()
        self.assertTrue(next(x for x in status['unstaged'] if x['path'] == 'link')['blocked'])
        args = self.args(paths=['a.txt']); args['files'] = [dict(path='../outside', fingerprint='missing')]
        self.assertFalse(self.call('stage', **args)['ok'])
        for marker in ['MERGE_HEAD', 'repopocket-transaction.json']:
            path = self.work / '.git' / marker; path.write_text(self.head + '\n')
            self.assertFalse(self.call('stageStatus')['ok']); path.unlink()

    def test_commit_crash_journal_recovers_without_touching_worktree(self):
        (self.work / 'a.txt').write_text('staged\n')
        self.result('stage', **self.args(paths=['a.txt']))
        (self.work / 'a.txt').write_text('later\n')
        args = self.args(); args.update(self.author()); args['testCrashStage'] = 'afterPublish'
        args.update(repository=str(self.work / '.git'), workdir=str(self.work))
        script = '''import ctypes,json,sys
lib=ctypes.CDLL(sys.argv[1]);lib.rp_git_execute.argtypes=[ctypes.c_char_p,ctypes.c_char_p]
lib.rp_git_execute(b'commitStaged',sys.argv[2].encode())
'''
        process = subprocess.Popen(['python3', '-c', script, self.library_path, json.dumps(args)])
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        paused = self.work / '.git/repopocket-test-paused'
        deadline = time.monotonic() + 15
        while not paused.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(.05)
        self.assertTrue(paused.exists(), 'native crash hook not reached')
        process.kill(); process.wait()
        self.assertTrue((self.work / '.git/repopocket-transaction.json').exists())
        self.result('recover', expectedHead=self.git('rev-parse', 'HEAD'))
        self.assertFalse((self.work / '.git/repopocket-transaction.json').exists())
        self.assertEqual(self.git('show', 'HEAD:a.txt'), 'staged')
        self.assertEqual((self.work / 'a.txt').read_text(), 'later\n')
    def test_existing_staged_other_path_is_preserved(self):
        (self.work / 'a.txt').write_text('a selected\n')
        (self.work / 'b.txt').write_text('b previously staged\n')
        self.git('add', 'b.txt')
        old_blob = self.git('rev-parse', ':b.txt')
        self.result('stage', **self.args(paths=['a.txt']))
        self.assertEqual(self.git('rev-parse', ':b.txt'), old_blob)
        self.result('unstage', **self.args(paths=['a.txt'], side='staged'))
        self.assertEqual(self.git('rev-parse', ':b.txt'), old_blob)
        self.assertEqual(self.git('diff', '--cached', '--name-only'), 'b.txt')
        self.assertEqual((self.work / 'b.txt').read_text(), 'b previously staged\n')

    def test_stage_deletion_then_commit_does_not_remove_later_recreated_workfile(self):
        (self.work / 'a.txt').unlink()
        self.result('stage', **self.args(paths=['a.txt']))
        (self.work / 'a.txt').write_text('recreated after staging\n')
        self.result('commitStaged', **self.args(), **self.author())
        self.assertNotIn('a.txt', self.git('ls-tree', '--name-only', 'HEAD').splitlines())
        self.assertEqual((self.work / 'a.txt').read_text(), 'recreated after staging\n')

    def test_unstage_new_index_change_rejects_old_snapshot(self):
        (self.work / 'a.txt').write_text('first staged\n'); self.git('add', 'a.txt')
        args = self.args(paths=['a.txt'], side='staged')
        (self.work / 'a.txt').write_text('second staged\n'); self.git('add', 'a.txt')
        index = (self.work / '.git/index').read_bytes()
        self.assertFalse(self.call('unstage', **args)['ok'])
        self.assertEqual((self.work / '.git/index').read_bytes(), index)
        self.assertFalse(self.call('commitStaged', **args, **self.author())['ok'])


if __name__ == '__main__':
    unittest.main()
