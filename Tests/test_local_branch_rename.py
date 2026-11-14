"""Local-only rename contracts and the production macOS bridge in disposable repos."""
from pathlib import Path
import platform
import unittest

import test_local_branches as local

ROOT = Path(__file__).resolve().parents[1]


class LocalRenameContracts(unittest.TestCase):
    def test_local_menu_has_plain_input_alert_and_preserves_delete(self):
        view = (ROOT / 'RepoPocket/LocalGitBranchManagement.swift').read_text()
        self.assertIn('Button("重命名")', view)
        self.assertIn('if !branch.remote', view)
        self.assertIn('!branch.current && !branch.remote', view)
        self.assertIn('start("renameBranch"', view)
        self.assertIn('不会重命名远端分支', view)
        alert = view.split('.appTextInputAlert("重命名本地分支"', 1)[1].split('private func branchButton', 1)[0]
        self.assertIn('text: $renameName, placeholder: "新分支名称", confirmTitle: "重命名"', alert)
        compat = (ROOT / 'RepoPocket/AppTextInputAlert.swift').read_text()
        self.assertIn('TextField(placeholder, text: $text)', compat)
        self.assertIn('"expectedTargetHead": branch.head', alert)
        self.assertIn('[renaming]', alert)

    def test_native_rename_is_pinned_locked_and_never_checks_out(self):
        source = (ROOT / 'Vendor/NativeGit/NativeGitBridge.m').read_text()
        self.assertIn('static NSDictionary *RPRenameBranch(', source)
        body = source.split('static NSDictionary *RPRenameBranch(', 1)[1].split('static NSDictionary *', 1)[0]
        for text in ('RPExpected', 'expectedTargetHead', 'RPLockHead', 'RPLockBranch',
                     'RPAbsentBranch', 'RPBranchState', 'RPIsCancelled', 'git_config_lock',
                     'git_branch_is_checked_out', 'repopocket-transaction.json'):
            self.assertIn(text, body)
        for text in ('git_checkout_', 'git_index_write', 'git_reset', 'git_stash',
                     'git_branch_move', 'git_remote_', 'git_transaction_set_symbolic_target'):
            self.assertNotIn(text, body)
        self.assertIn('else if ([op isEqual:@"renameBranch"]) result = RPRenameBranch(repo,q,c);', source)


@unittest.skipUnless(platform.system() == 'Darwin', 'macOS required for production Objective-C bridge')
class NativeLocalRename(unittest.TestCase):
    setUpClass = classmethod(local.LocalBranchBehavior.setUpClass.__func__)
    setUp = local.LocalBranchBehavior.setUp
    git = local.LocalBranchBehavior.git
    call = local.LocalBranchBehavior.call
    result = local.LocalBranchBehavior.result
    preserved = local.LocalBranchBehavior.preserved
    make_target = local.LocalBranchBehavior.make_target

    def rename(self, old='feature', new='renamed', sha=None, **values):
        return self.call('renameBranch', targetRef='refs/heads/' + old,
                         expectedTargetHead=sha or self.head, name=new, **values)

    def test_dirty_other_branch_rename_preserves_index_worktree_and_head(self):
        target = self.make_target()
        (self.work / '代码.py').write_text('staged\n')
        self.git('add', '代码.py')
        (self.work / '代码.py').write_text('unstaged\n')
        (self.work / 'untracked').write_text('keep\n')
        before = self.preserved()
        self.assertTrue(self.rename(sha=target)['ok'])
        self.assertEqual(self.git('rev-parse', 'renamed'), target)
        self.assertEqual(self.git('for-each-ref', '--format=%(refname)', 'refs/heads/feature'), '')
        self.assertEqual(self.git('symbolic-ref', 'HEAD'), 'refs/heads/main')
        self.assertEqual(self.preserved(), before)

    def test_current_rename_fails_conservatively_without_touching_symbolic_head(self):
        (self.work / 'other.txt').write_text('dirty\n')
        before = self.preserved()
        head = (self.work / '.git/HEAD').read_bytes()
        response = self.rename(old='main')
        self.assertFalse(response['ok'])
        self.assertIn('当前分支', response['error'])
        self.assertEqual((self.work / '.git/HEAD').read_bytes(), head)
        self.assertEqual(self.preserved(), before)
        self.assertEqual(self.git('for-each-ref', '--format=%(refname)', 'refs/heads'), 'refs/heads/main')

    def test_tracked_remote_and_merge_target_are_not_renamed(self):
        self.git('branch', 'feature')
        self.git('remote', 'add', 'origin', 'https://github.com/fixture/repo.git')
        self.git('update-ref', 'refs/remotes/origin/feature', self.head)
        self.git('config', 'branch.feature.remote', 'origin')
        self.git('config', 'branch.feature.merge', 'refs/heads/feature')
        self.assertTrue(self.rename()['ok'])
        self.assertEqual(self.git('config', 'branch.renamed.remote'), 'origin')
        self.assertEqual(self.git('config', 'branch.renamed.merge'), 'refs/heads/feature')
        self.assertEqual(self.git('rev-parse', 'refs/remotes/origin/feature'), self.head)
        self.assertEqual(self.git('for-each-ref', '--format=%(refname)', 'refs/remotes/origin/renamed'), '')
        self.assertEqual(self.git('config', '--get-regexp', '^branch\\.'),
                         'branch.renamed.remote origin\nbranch.renamed.merge refs/heads/feature')
        self.git('checkout', 'renamed')
        reply = self.call('push', expectedRef='refs/heads/renamed')
        self.assertFalse(reply['ok'])
        self.assertIn('不会更改既有跟踪目标', reply['error'])

    def test_duplicate_invalid_stale_and_remote_refs_are_rejected(self):
        self.git('branch', 'feature')
        self.git('branch', 'taken')
        before = self.preserved()
        refs = self.git('show-ref')
        for name in ('taken', 'main', 'bad..name', 'bad name', '-bad', 'HEAD', 'feature', 'feature/nested'):
            with self.subTest(name=name):
                self.assertFalse(self.rename(new=name)['ok'])
                self.assertEqual(self.git('show-ref'), refs)
                self.assertEqual(self.preserved(), before)
        for values in ({'sha': '0' * 40}, {'expectedHead': '0' * 40}, {'expectedRef': 'refs/heads/other'}):
            self.assertFalse(self.rename(**values)['ok'])
        self.git('update-ref', 'refs/remotes/origin/feature', self.head)
        self.assertFalse(self.call('renameBranch', targetRef='refs/remotes/origin/feature',
                                   expectedTargetHead=self.head, name='renamed')['ok'])

    def test_packed_source_keeps_all_other_refs(self):
        self.git('branch', 'feature')
        self.git('branch', 'untouched')
        self.git('pack-refs', '--all')
        self.assertTrue(self.rename()['ok'])
        self.assertEqual(self.git('show-ref', '--heads'), '\n'.join(
            self.head + ' refs/heads/' + name for name in ('main', 'renamed', 'untouched')))

    def test_in_progress_detached_special_config_and_external_locks_refuse(self):
        self.git('branch', 'feature')
        for relative in ('MERGE_HEAD', 'refs/heads/feature.lock', 'refs/heads/renamed.lock', 'config.lock'):
            path = self.work / '.git' / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(self.head + '\n')
            try:
                self.assertFalse(self.rename()['ok'], relative)
                self.assertEqual(self.git('rev-parse', 'feature'), self.head)
                self.assertTrue(path.exists())
            finally:
                path.unlink()
        self.git('config', 'branch.renamed.description', 'existing metadata')
        self.assertFalse(self.rename()['ok'])
        self.git('config', '--unset', 'branch.renamed.description')
        self.git('checkout', '--detach')
        self.assertFalse(self.rename()['ok'])

    def test_linked_worktree_branch_cannot_be_renamed(self):
        self.git('branch', 'feature')
        other = Path(self.temp.name) / 'linked'
        self.git('worktree', 'add', str(other), 'feature')
        self.assertFalse(self.rename()['ok'])
        self.assertEqual(self.git('rev-parse', 'feature'), self.head)


if __name__ == '__main__':
    unittest.main()
