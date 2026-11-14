"""Local branch operations run the shipping bridge in disposable repositories on macOS."""
from pathlib import Path
import ctypes
import json
import platform
import subprocess
import tempfile
import unittest

import test_local_git_native as native_fixtures

ROOT = native_fixtures.ROOT


class LocalBranchContracts(unittest.TestCase):
    def test_create_confirmation_is_a_plain_alert_button_and_reports_result(self):
        view = (ROOT / 'RepoPocket/LocalGitBranchManagement.swift').read_text()
        alert = view.split('.appTextInputAlert("从当前 HEAD 新建并切换"', 1)[1].split('.alert("切换分支？"', 1)[0]
        self.assertIn('text: $newName, placeholder: "新分支名称", confirmTitle: "新建并切换"', alert)
        self.assertIn('start("createBranch"', alert)
        compat = (ROOT / 'RepoPocket/AppTextInputAlert.swift').read_text()
        modern = compat.split('if #available(iOS 16.0, *) {', 1)[1].split('} else {', 1)[0]
        # iOS 16's alert bridge still receives an unwrapped enabled Button.
        confirm = next(line for line in modern.splitlines() if 'Button(confirmTitle)' in line)
        self.assertNotIn('.disabled(', confirm)
        self.assertIn('已创建并切换到本地分支', view)
        self.assertIn('SoftGroupRow("result")', view)

    def test_local_delete_is_explicit_and_not_offered_for_current_or_remote_tracking(self):
        view = (ROOT / 'RepoPocket/LocalGitBranchManagement.swift').read_text()
        self.assertIn('.contextMenu', view)
        self.assertIn('!branch.current && !branch.remote', view)
        self.assertIn('start("deleteBranch"', view)
        self.assertIn('仅删除本地分支', view)

    def test_branch_and_upstream_writes_use_file_provider_write_coordination(self):
        source = (ROOT / 'RepoPocket/LocalGitEngine.swift').read_text()
        policy = source.split('coordinate(root, writing: ', 1)[1].split('.contains(operation)', 1)[0]
        for operation in ('"createBranch"', '"switchBranch"', '"push"'):
            self.assertIn(operation, policy)

    def test_symbolic_head_lock_does_not_embed_ownership_marker(self):
        source = (ROOT / 'Vendor/NativeGit/NativeGitBridge.m').read_text()
        helper = source.split('static git_transaction *RPLockHeadForUpdate(', 1)[1].split('static NSDictionary *RPRecover', 1)[0]
        self.assertIn('RPLeaseCapture(metadata,@"HEAD.lock",!symbolicWrite,c)', helper)
        for operation in ('RPCreateBranch(', 'RPSwitchBranch('):
            body = source.split('static NSDictionary *' + operation, 1)[1].split('static NSDictionary *', 1)[0]
            self.assertIn('RPLockHeadForUpdate(repo,head,YES,c)', body)

    def test_create_only_updates_refs_and_preserves_index(self):
        source = (ROOT / 'Vendor/NativeGit/NativeGitBridge.m').read_text()
        create = source.split('static NSDictionary *RPCreateBranch(', 1)[1].split('static NSDictionary *RPSwitchBranch(', 1)[0]
        for text in ('RPExpected', 'RPLockHead', 'RPBranchState', 'RPAbsentBranch', 'RPIsCancelled', 'git_transaction_set_symbolic_target'):
            self.assertIn(text, create)
        for text in ('git_checkout_', 'git_index_write', 'git_stash', 'git_reset'):
            self.assertNotIn(text, create)

    def test_switch_is_safe_pinned_and_never_cleans_files(self):
        source = (ROOT / 'Vendor/NativeGit/NativeGitBridge.m').read_text()
        switch = source.split('static NSDictionary *RPSwitchBranch(', 1)[1].split('static NSDictionary *RPCreate(', 1)[0]
        for text in ('expectedTargetHead', 'RPExpected', 'GIT_CHECKOUT_SAFE', 'GIT_CHECKOUT_DRY_RUN', 'GIT_CHECKOUT_DONT_OVERWRITE_IGNORED', 'RPIsCancelled', 'repopocket-transaction.json'):
            self.assertIn(text, switch)
        for text in ('GIT_CHECKOUT_FORCE', 'GIT_CHECKOUT_REMOVE_UNTRACKED', 'git_stash', 'git_reset'):
            self.assertNotIn(text, switch)
        self.assertLess(switch.index('[status[@"files"] count]==0'), switch.index('git_checkout_tree'))

    def test_push_only_same_name_and_sets_upstream_after_success(self):
        source = (ROOT / 'Vendor/NativeGit/NativeGitBridge.m').read_text()
        push = source.split('static NSDictionary *RPPush(', 1)[1].split('static NSDictionary *RPBranches(', 1)[0]
        self.assertIn('BOOL firstPush=', push)
        self.assertIn('stringWithFormat:@"%@:%@"', push)
        self.assertNotIn('stringWithFormat:@"+%@', push)
        self.assertLess(push.index('git_remote_push'), push.index('git_config_set_string'))
        self.assertLess(push.index('pushRejected"] boolValue'), push.index('git_config_set_string'))
        self.assertIn('git_config_lock', push)

    def test_manager_uses_native_list_and_lifecycle(self):
        view = (ROOT / 'RepoPocket/LocalGitBranchManagement.swift').read_text()
        for text in ('SoftGroupRows', '"branches"', '"createBranch"', '"switchBranch"', '"expectedHead"', '"expectedRef"', '"expectedTargetHead"', 'generation == AccountStore.generation', 'operation?.cancel()', 'changed()'):
            self.assertIn(text, view)
        self.assertNotIn('api.branches', view)
        self.assertNotIn('}.disabled(busy)\n', view)  # Modifiers belong inside SoftGroupRow closures.


@unittest.skipUnless(platform.system() == 'Darwin', 'macOS required for Objective-C/Foundation production bridge')
class LocalBranchBehavior(unittest.TestCase):
    git = native_fixtures.NativeGitBehavior.git
    setUp = native_fixtures.NativeGitBehavior.setUp
    result = native_fixtures.NativeGitBehavior.result

    @classmethod
    def setUpClass(cls):
        cls.library_dir = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.library_dir.cleanup)
        prefix = ROOT / 'NativeBuild/macosx'
        library = Path(cls.library_dir.name) / 'branches.dylib'
        subprocess.run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-DRP_GIT_TESTING=1',
                        '-I' + str(prefix / 'include'), str(ROOT / 'Vendor/NativeGit/NativeGitBridge.m'),
                        '-L' + str(prefix / 'lib'), '-lgit2', '-lz', '-liconv',
                        '-framework', 'Foundation', '-framework', 'Security',
                        '-framework', 'CoreFoundation', '-o', str(library)], check=True)
        cls.native = ctypes.CDLL(str(library))
        cls.native.rp_git_execute.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        cls.native.rp_git_execute.restype = ctypes.c_void_p
        cls.native.rp_git_free.argtypes = [ctypes.c_void_p]
        cls.native.rp_git_cancel.argtypes = [ctypes.c_char_p]
        fixture = Path(cls.library_dir.name) / 'BranchesFixture.swift'
        fixture.write_text(r'''import Foundation
private struct Envelope<T: Decodable>: Decodable { let ok: Bool; let result: T?; let error: String? }
enum ChinaDate { static func dateTime(_ value: Date) -> String { "fixture" } }
@main struct Harness {
    static func main() throws {
        let bytes = FileHandle.standardInput.readDataToEndOfFile()
        if CommandLine.arguments[1] == "branches" {
            let reply = try JSONDecoder().decode(Envelope<LocalGitBranches>.self, from: bytes)
            if reply.ok {
                let branches = try require(reply.result)
                precondition(branches.local.filter(\.current).count == 1)
                precondition(branches.local.allSatisfy { !$0.remote })
                precondition(branches.remote.allSatisfy { $0.remote && !$0.current })
            } else { precondition(reply.result == nil && reply.error != nil) }
        } else {
            let reply = try JSONDecoder().decode(Envelope<LocalGitReply>.self, from: bytes)
            if reply.ok {
                let result = try require(reply.result)
                precondition(result.head != nil)
            } else { precondition(reply.result == nil && reply.error != nil) }
        }
    }
    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "BranchesFixture", code: 1) }
        return value
    }
}
''', encoding='utf-8')
        cls.decoder = str(Path(cls.library_dir.name) / 'decode-branches')
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(ROOT / 'RepoPocket/LocalGitModels.swift'),
                        str(fixture), '-o', cls.decoder], check=True)

    def call(self, operation, **values):
        request = dict(repository=str(self.work / '.git'), workdir=str(self.work),
                       expectedHead=self.head, expectedRef='refs/heads/main')
        request.update(values)
        pointer = self.native.rp_git_execute(operation.encode(), json.dumps(request).encode())
        self.assertTrue(pointer)
        try:
            raw = ctypes.string_at(pointer)
        finally:
            self.native.rp_git_free(pointer)
        if operation in ('branches', 'createBranch', 'switchBranch', 'push'):
            decoded = subprocess.run([self.decoder, 'branches' if operation == 'branches' else 'reply'], input=raw, capture_output=True)
            self.assertEqual(decoded.returncode, 0, decoded.stderr.decode(errors='replace'))
        return json.loads(raw)

    def preserved(self):
        return ((self.work / '.git/index').read_bytes(),
                {str(p.relative_to(self.work)): (p.read_bytes(), p.stat().st_mode)
                 for p in self.work.rglob('*') if p.is_file() and '.git' not in p.relative_to(self.work).parts},
                self.git('ls-files', '--stage'), self.git('diff', '--binary'), self.git('diff', '--cached', '--binary'))

    def make_target(self, name='feature'):
        self.git('checkout', '-b', name)
        (self.work / '代码.py').write_text('print("feature")\n')
        self.git('add', '.')
        self.git('commit', '-m', 'feature commit')
        target = self.git('rev-parse', 'HEAD')
        self.git('checkout', 'main')
        return target

    def bare_remote(self):
        bare = Path(self.temp.name) / 'remote.git'
        self.git('init', '--bare', str(bare))
        self.git('remote', 'add', 'origin', bare.as_uri())
        return bare

    def test_list_local_and_already_fetched_remote_without_network(self):
        self.git('branch', '中文/feature')
        self.git('remote', 'add', 'origin', 'https://github.com/invalid/offline.git')
        self.git('update-ref', 'refs/remotes/origin/remote-only', self.head)
        self.git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/remote-only')
        result = self.result('branches')
        self.assertEqual({b['name'] for b in result['local']}, {'main', '中文/feature'})
        self.assertEqual([b['name'] for b in result['remote']], ['origin/remote-only'])
        self.assertEqual([b['name'] for b in result['local'] if b['current']], ['main'])
        self.assertEqual(result['reference'], 'refs/heads/main')

    def test_dirty_create_preserves_worktree_staged_untracked_and_index_bytes(self):
        (self.work / '代码.py').write_text('staged version\n')
        self.git('add', '代码.py')
        (self.work / '代码.py').write_text('unstaged second version\n')
        (self.work / 'other.txt').unlink()
        (self.work / 'untracked 文件').write_bytes(b'\0untracked\xff')
        (self.work / 'ignored').write_bytes(b'ignored data')
        before = self.preserved()
        self.result('createBranch', name='中文/dirty-work')
        self.assertEqual(self.git('symbolic-ref', 'HEAD'), 'refs/heads/中文/dirty-work')
        self.assertEqual((self.work / '.git/HEAD').read_bytes(), 'ref: refs/heads/中文/dirty-work\n'.encode())
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.head)
        self.assertEqual(self.git('rev-parse', 'main'), self.head)
        self.assertEqual(self.preserved(), before)
        self.assertNotIn('[branch "中文/dirty-work"]', (self.work / '.git/config').read_text())

    def test_dirty_switch_rejected_for_worktree_index_and_untracked(self):
        target = self.make_target()
        for kind in ('worktree', 'index', 'untracked'):
            with self.subTest(kind=kind):
                path = self.work / ('loose.txt' if kind == 'untracked' else '代码.py')
                path.write_text('keep exactly\n')
                if kind == 'index':
                    self.git('add', '代码.py')
                before = self.preserved()
                response = self.call('switchBranch', targetRef='refs/heads/feature', expectedTargetHead=target)
                self.assertFalse(response['ok'])
                self.assertIn('请先提交', response['error'])
                self.assertEqual(self.git('symbolic-ref', 'HEAD'), 'refs/heads/main')
                self.assertEqual(self.preserved(), before)
                if kind == 'untracked':
                    path.unlink()
                else:
                    self.git('restore', '--staged', '--worktree', '代码.py')

    def test_clean_switch_checks_out_target_and_updates_head(self):
        target = self.make_target()
        self.result('switchBranch', targetRef='refs/heads/feature', expectedTargetHead=target)
        self.assertEqual(self.git('symbolic-ref', 'HEAD'), 'refs/heads/feature')
        self.assertEqual((self.work / '.git/HEAD').read_bytes(), b'ref: refs/heads/feature\n')
        self.assertEqual((self.work / '代码.py').read_text(), 'print("feature")\n')
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.assertEqual(self.git('rev-parse', 'main'), self.head)

    def test_clean_remote_switch_creates_tracking_local_branch(self):
        target = self.make_target('remote-only')
        self.git('branch', '-D', 'remote-only')
        self.git('remote', 'add', 'origin', 'https://github.com/invalid/offline.git')
        self.git('update-ref', 'refs/remotes/origin/remote-only', target)
        self.result('switchBranch', targetRef='refs/remotes/origin/remote-only', expectedTargetHead=target)
        self.assertEqual(self.git('symbolic-ref', 'HEAD'), 'refs/heads/remote-only')
        self.assertEqual(self.git('rev-parse', 'HEAD'), target)
        self.assertEqual(self.git('rev-parse', '--abbrev-ref', '@{upstream}'), 'origin/remote-only')
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_ignored_collision_never_overwritten(self):
        self.git('checkout', '-b', 'collision')
        (self.work / 'ignored').write_text('target tracked content')
        self.git('add', '-f', 'ignored')
        self.git('commit', '-m', 'track ignored path')
        target = self.git('rev-parse', 'HEAD')
        self.git('checkout', 'main')
        (self.work / 'ignored').write_text('precious ignored content')
        before = self.preserved()
        response = self.call('switchBranch', targetRef='refs/heads/collision', expectedTargetHead=target)
        self.assertFalse(response['ok'])
        self.assertEqual(self.preserved(), before)
        self.assertEqual(self.git('symbolic-ref', 'HEAD'), 'refs/heads/main')

    def test_stale_head_ref_target_invalid_name_and_duplicates_do_not_mutate(self):
        target = self.make_target()
        (self.work / 'loose.txt').write_text('preserve')
        before = self.preserved()
        for values in ({'expectedHead': '0' * 40}, {'expectedRef': 'refs/heads/other'},
                       {'name': '../bad'}, {'name': 'main'}, {'name': 'bad..name'}):
            with self.subTest(values=values):
                request = dict(name='new')
                request.update(values)
                self.assertFalse(self.call('createBranch', **request)['ok'])
                self.assertEqual(self.preserved(), before)
                self.assertEqual(self.git('symbolic-ref', 'HEAD'), 'refs/heads/main')
        (self.work / 'loose.txt').unlink()
        before = self.preserved()
        for values in ({'expectedTargetHead': '0' * 40}, {'targetRef': 'refs/tags/not-a-branch'},
                       {'targetRef': 'refs/heads/deleted'}, {'expectedRef': 'refs/heads/feature'}):
            request = dict(targetRef='refs/heads/feature', expectedTargetHead=target)
            request.update(values)
            self.assertFalse(self.call('switchBranch', **request)['ok'])
            self.assertEqual(self.preserved(), before)
            self.assertEqual(self.git('symbolic-ref', 'HEAD'), 'refs/heads/main')

    def test_missing_remote_and_disconnected_push_keep_local_commit_and_tracking(self):
        before = self.preserved()
        self.assertFalse(self.call('push')['ok'])
        missing = (Path(self.temp.name) / 'does-not-exist.git').as_uri()
        self.git('remote', 'add', 'origin', missing)
        self.assertFalse(self.call('push', expectedRemote=missing)['ok'])
        self.assertEqual(self.preserved(), before)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.head)
        config = (self.work / '.git/config').read_text()
        self.assertNotIn('[branch "main"]', config)

    def test_first_push_sets_same_name_upstream_and_repeat_push_succeeds(self):
        bare = self.bare_remote()
        self.result('createBranch', name='topic/first')
        self.result('push', expectedRef='refs/heads/topic/first', expectedRemote=bare.as_uri())
        self.assertEqual(self.git('rev-parse', 'refs/heads/topic/first', cwd=bare), self.head)
        self.assertEqual(self.git('config', 'branch.topic/first.remote'), 'origin')
        self.assertEqual(self.git('config', 'branch.topic/first.merge'), 'refs/heads/topic/first')
        self.assertEqual(self.git('rev-parse', '--abbrev-ref', '@{upstream}'), 'origin/topic/first')
        self.result('push', expectedRef='refs/heads/topic/first', expectedRemote=bare.as_uri())
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_nonfastforward_push_rejected_without_upstream_or_data_loss(self):
        bare = self.bare_remote()
        target = self.make_target()
        self.git('push', 'origin', 'feature:main')
        before = self.preserved()
        self.assertFalse(self.call('push', expectedRemote=bare.as_uri())['ok'])
        self.assertEqual(self.git('rev-parse', 'refs/heads/main', cwd=bare), target)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.head)
        self.assertEqual(self.preserved(), before)
        self.assertNotIn('[branch "main"]', (self.work / '.git/config').read_text())

    def test_different_existing_upstream_and_changed_remote_rejected(self):
        bare = self.bare_remote()
        for remote, merge in (('origin', 'refs/heads/different'), ('another', 'refs/heads/main')):
            self.git('config', 'branch.main.remote', remote)
            self.git('config', 'branch.main.merge', merge)
            before = self.preserved()
            self.assertFalse(self.call('push', expectedRemote=bare.as_uri())['ok'])
            self.assertEqual(self.preserved(), before)
            self.assertEqual(self.git('config', 'branch.main.merge'), merge)
        self.git('config', '--remove-section', 'branch.main')
        self.assertFalse(self.call('push', expectedRemote='https://github.com/other/repo.git')['ok'])
        refs = self.git('for-each-ref', '--format=%(refname)', cwd=bare)
        self.assertEqual(refs, '')

    def test_wrong_root_pairing_rejected_without_changes(self):
        other = Path(self.temp.name) / 'wrong-root'
        other.mkdir()
        (other / 'precious.txt').write_text('do not touch')
        before = self.preserved()
        self.assertFalse(self.call('createBranch', name='new', workdir=str(other))['ok'])
        self.assertEqual((other / 'precious.txt').read_text(), 'do not touch')
        self.assertEqual(self.preserved(), before)

    def test_detached_head_and_interrupted_operation_rejected(self):
        self.git('checkout', '--detach', self.head)
        before = self.preserved()
        self.assertFalse(self.call('createBranch', name='new')['ok'])
        self.assertEqual(self.preserved(), before)
        self.git('checkout', 'main')
        journal = self.work / '.git/repopocket-transaction.json'
        journal.write_text('{}')
        before = self.preserved()
        self.assertFalse(self.call('createBranch', name='new')['ok'])
        self.assertEqual(journal.read_text(), '{}')
        self.assertEqual(self.preserved(), before)

    def test_cancelled_create_switch_and_push_preserve_everything(self):
        target = self.make_target()
        for action, args in (('createBranch', {'name': 'new'}),
                             ('switchBranch', {'targetRef': 'refs/heads/feature', 'expectedTargetHead': target}),
                             ('push', {})):
            request_id = 'cancel-branches-' + action
            self.native.rp_git_cancel(request_id.encode())
            before = self.preserved()
            response = self.call(action, requestID=request_id, **args)
            self.assertFalse(response['ok'])
            self.assertIn('取消', response['error'])
            self.assertEqual(self.preserved(), before)
            self.assertEqual(self.git('symbolic-ref', 'HEAD'), 'refs/heads/main')


if __name__ == '__main__':
    unittest.main()
