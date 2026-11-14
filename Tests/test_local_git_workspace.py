"""History edits: static guards here, production bridge tests on macOS only.
All Git writes happen inside TemporaryDirectory repositories and their local bare origin.
"""
from pathlib import Path
import platform
import unittest
import test_local_git_native as native

ROOT = Path(__file__).resolve().parents[1]


class HistoryWorkspaceStructure(unittest.TestCase):
    def test_history_guards_and_preflight_precede_mutation(self):
        bridge = (ROOT/'Vendor/NativeGit/NativeGitBridge.m').read_text()
        body = (ROOT/'Vendor/NativeGit/NativeGitHistory.inc').read_text()
        self.assertIn('#include "NativeGitHistory.inc"', bridge)
        for op in ['historyPreview', 'historyApply']:
            self.assertIn('[op isEqual:@"'+op+'"]', bridge)
        for guard in ['RPHistoryClean', 'RPSafeUpstream', 'RPHistoryFetch', 'RPHistoryPublished',
                      'git_repository_is_shallow', 'git_commit_parentcount(cursor)==1',
                      'RPMergeTreeBudget', 'RPMergeHistory', 'RPMergeOverlay', 'expectedUpstream',
                      'expectedTree', 'refs/repopocket/recovery/', 'preparedIndex',
                      'GIT_CHECKOUT_DONT_OVERWRITE_IGNORED']:
            self.assertIn(guard, body)
        self.assertLess(body.index('!git_index_has_conflicts(result)'), body.index('if (!apply) return preview'))
        self.assertLess(body.index('if (!apply) return preview'), body.index('git_commit_create'))
        self.assertNotIn('git_revert(', body, 'No unfinished revert state on preflight conflict')
        for forbidden in ['GIT_CHECKOUT_FORCE', 'git_reset(', 'git_rebase', 'git_cherrypick']:
            self.assertNotIn(forbidden, body)
        self.assertIn('"+refs/tags/*:refs/repopocket/fetched-tags/*"', body)
        self.assertIn('names.count==1', body, 'Unknown additional remotes must conservatively block rewriting')

    def test_directory_add_flow_and_blocked_remote_have_single_destinations(self):
        page = (ROOT/'RepoPocket/LocalProjectView.swift').read_text()
        files = (ROOT/'RepoPocket/LocalProjectEditor.swift').read_text()
        menu = (ROOT/'RepoPocket/LocalGitAddAction.swift').read_text()
        self.assertNotIn('choosingImportTarget', page)
        self.assertNotIn('importTarget', page)
        self.assertIn('NativeActionMenu(title: "添加到"', files)
        self.assertIn('LocalGitAddAction.items', page)
        self.assertIn('LocalGitAddAction.items', files)
        for case in ['newFile', 'newFolder', 'importFiles', 'importFolder']:
            self.assertIn(case, menu)
        self.assertNotIn('SoftGroupRow("import-files")', files)
        self.assertNotIn('SoftGroupRow("import-folder")', files)
        self.assertIn('directory: directory, generation: generation', files)
        self.assertEqual(page.count('NavigationLink("关联 GitHub 仓库…")'), 1)
        actions = page.split('private func actionsSection', 1)[1].split('private func historySection', 1)[0]
        self.assertIn('snapshot.history.remoteMissing == true', actions)
        self.assertIn('NavigationLink("关联 GitHub 仓库…")', actions)
        self.assertIn('syncing = "fetch"', actions)

    def test_history_view_revalidates_session_and_uses_existing_native_ui(self):
        ui = (ROOT/'RepoPocket/LocalGitHistoryActions.swift').read_text()
        for text in ['NativeActionMenu', 'SoftGroupRows', 'context.generation == AccountStore.generation',
                     'context.api.isCurrentSession', 'context.isValid()', 'context.changed()',
                     'preview.truncated', '.confirmationDialog', 'task?.cancel()', 'expectedHead', 'expectedRef']:
            self.assertIn(text, ui)


@unittest.skipUnless(platform.system() == 'Darwin', 'Production Objective-C/libgit2 bridge requires macOS')
class HistoryWorkspaceNative(unittest.TestCase):
    setUpClass = classmethod(native.NativeGitBehavior.setUpClass.__func__)
    setUp = native.NativeGitBehavior.setUp
    git = native.NativeGitBehavior.git
    call = native.NativeGitBehavior.call
    result = native.NativeGitBehavior.result

    def commit(self, name='change.txt', text='new\n'):
        (self.work/name).write_text(text)
        self.git('add', name)
        self.git('commit', '-m', name)
        return self.git('rev-parse', 'HEAD')

    def origin(self):
        origin = self.work.parent/'origin.git'
        self.git('init', '--bare', str(origin))
        self.git('remote', 'add', 'origin', origin.as_uri())
        self.git('push', '-u', 'origin', 'main')
        return origin

    def snapshot(self, objects=False):
        files = {str(p.relative_to(self.work)): p.read_bytes() for p in self.work.rglob('*')
                 if p.is_file() and '.git' not in p.relative_to(self.work).parts}
        result = [self.git('rev-parse', 'HEAD'), self.git('symbolic-ref', 'HEAD'),
                  (self.work/'.git/index').read_bytes(), files]
        if objects:
            result.append({str(p.relative_to(self.work)): p.read_bytes()
                           for p in (self.work/'.git/objects').rglob('*') if p.is_file()})
        return result

    def arguments(self, kind, **extra):
        args = dict(kind=kind, expectedHead=self.git('rev-parse', 'HEAD'), count=1,
                    authorName='Fixture', authorEmail='fixture@example.invalid', message='Local history edit')
        args.update(extra)
        return args

    def apply(self, args):
        preview = self.result('historyPreview', **args)
        return self.result('historyApply', **dict(args, expectedTree=preview['tree'], expectedUpstream=preview['upstream']))

    def test_additive_revert_and_conflicting_revert_no_orphan_state(self):
        target = self.commit('代码.py', 'target\n')
        args = self.arguments('revert', sha=target)
        before = self.snapshot(objects=True)
        self.result('historyPreview', **args)
        self.assertEqual(self.snapshot(objects=True), before)
        reply = self.apply(args)
        self.assertEqual(self.git('rev-parse', 'HEAD^'), target)
        self.assertEqual((self.work/'代码.py').read_text(), 'print("old")\n')
        self.assertEqual(self.git('rev-parse', reply['recoveryRef']), target)
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.git('reset', '--hard', target)  # fixture-only reset
        self.commit('代码.py', 'later incompatible edit\n')
        before = self.snapshot(objects=True)
        self.assertFalse(self.call('historyPreview', **self.arguments('revert', sha=target))['ok'])
        self.assertEqual(self.snapshot(objects=True), before)
        for name in ['REVERT_HEAD', 'MERGE_HEAD', 'repopocket-transaction.json']:
            self.assertFalse((self.work/'.git'/name).exists())

    def test_remove_keep_and_discard_latest_unpublished_commit(self):
        self.origin()
        for kind in ['removeKeep', 'removeDiscard']:
            with self.subTest(kind=kind):
                tip = self.commit()
                reply = self.apply(self.arguments(kind))
                self.assertEqual(self.git('rev-parse', 'HEAD'), self.head)
                self.assertEqual(self.git('rev-parse', reply['recoveryRef']), tip)
                self.assertEqual((self.work/'change.txt').exists(), kind == 'removeKeep')
                self.assertEqual(self.git('diff', '--cached'), '')
                if kind == 'removeKeep':
                    self.assertIn('?? change.txt', self.git('status', '--porcelain'))
                    (self.work/'change.txt').unlink()
                else:
                    self.assertEqual(self.git('status', '--porcelain'), '')

    def test_squash_preserves_final_tree_and_recovery(self):
        self.origin()
        self.commit('one.txt', 'one')
        tip = self.commit('two.txt', 'two')
        tree = self.git('rev-parse', 'HEAD^{tree}')
        reply = self.apply(self.arguments('squash', count=2, message='Combined local work'))
        self.assertEqual(self.git('rev-parse', 'HEAD^{tree}'), tree)
        self.assertEqual(self.git('rev-parse', 'HEAD^'), self.head)
        self.assertEqual(self.git('rev-parse', reply['recoveryRef']), tip)
        self.assertEqual(self.git('log', '-1', '--format=%s'), 'Combined local work')
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_rewrite_rejects_no_upstream_dirty_staged_and_published(self):
        self.commit()
        before = self.snapshot()
        self.assertFalse(self.call('historyPreview', **self.arguments('removeKeep'))['ok'])
        self.assertEqual(self.snapshot(), before)
        self.origin()  # tip is now published
        before = self.snapshot()
        self.assertFalse(self.call('historyPreview', **self.arguments('removeKeep'))['ok'])
        self.assertEqual(self.snapshot(), before)
        self.commit('local.txt', 'local')
        for stage in [False, True]:
            (self.work/'other.txt').write_text('precious edit\n')
            if stage:
                self.git('add', 'other.txt')
            before = self.snapshot()
            self.assertFalse(self.call('historyPreview', **self.arguments('removeDiscard'))['ok'])
            self.assertEqual(self.snapshot(), before)

    def test_published_on_other_remote_branch_or_tag_is_not_unpublished(self):
        self.origin()
        tip = self.commit()
        self.git('push', 'origin', 'HEAD:refs/heads/review')
        before = self.snapshot()
        self.assertFalse(self.call('historyPreview', **self.arguments('removeKeep'))['ok'])
        self.assertEqual(self.snapshot(), before)
        self.git('push', 'origin', ':refs/heads/review')
        self.git('update-ref', '-d', 'refs/remotes/origin/review')
        self.git('tag', 'published', tip)
        self.git('push', 'origin', 'refs/tags/published')
        self.git('tag', '-d', 'published')
        before = self.snapshot()
        self.assertFalse(self.call('historyPreview', **self.arguments('removeKeep'))['ok'])
        self.assertEqual(self.snapshot(), before)

    def test_merge_node_range_and_existing_index_lock_are_rejected(self):
        self.origin()
        self.git('checkout', '-b', 'feature')
        self.commit('feature.txt', 'feature')
        self.git('checkout', 'main')
        self.commit('local.txt', 'local')
        self.git('merge', '--no-ff', 'feature', '-m', 'fixture merge')
        before = self.snapshot(objects=True)
        for kind in ['removeKeep', 'squash', 'revert']:
            self.assertFalse(self.call('historyPreview', **self.arguments(kind, count=2 if kind == 'squash' else 1, sha=self.git('rev-parse', 'HEAD')))['ok'])
            self.assertEqual(self.snapshot(objects=True), before)
        self.git('reset', '--hard', 'HEAD^')
        args = self.arguments('removeDiscard')
        preview = self.result('historyPreview', **args)
        lock = self.work/'.git/index.lock'
        lock.write_bytes(b'other tool owns this lock')
        before = self.snapshot()
        self.assertFalse(self.call('historyApply', **dict(args, expectedTree=preview['tree'], expectedUpstream=preview['upstream']))['ok'])
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(lock.read_bytes(), b'other tool owns this lock')

    def test_interrupted_history_keeps_original_ref_and_journal(self):
        import json
        self.origin()
        tip = self.commit()
        recovery = 'refs/repopocket/recovery/fixture'
        self.git('update-ref', recovery, tip)
        journal = self.work/'.git/repopocket-transaction.json'
        journal.write_text(json.dumps(dict(operation='historyEdit', kind='removeKeep', reference='refs/heads/main',
                                          oldHead=tip, newHead=self.head, recoveryRef=recovery,
                                          preparedIndex='repopocket-index-fixture')))
        (self.work/'precious.txt').write_bytes(b'never remove')
        before = self.snapshot()
        reply = self.call('recover', expectedHead=tip)
        self.assertFalse(reply['ok'])
        self.assertIn('recoveryRef', reply['error'])
        self.assertEqual(self.snapshot(), before)
        self.assertTrue(journal.exists())
        self.assertEqual(self.git('rev-parse', recovery), tip)

    def test_stale_preview_and_merge_state_reject_without_data_loss(self):
        self.origin()
        tip = self.commit()
        args = self.arguments('removeDiscard')
        preview = self.result('historyPreview', **args)
        self.commit('later.txt', 'keep')
        before = self.snapshot()
        self.assertFalse(self.call('historyApply', **dict(args, expectedTree=preview['tree'], expectedUpstream=preview['upstream']))['ok'])
        self.assertEqual(self.snapshot(), before)
        (self.work/'.git/MERGE_HEAD').write_text(tip+'\n')
        before = self.snapshot()
        self.assertFalse(self.call('historyPreview', **self.arguments('removeDiscard'))['ok'])
        self.assertEqual(self.snapshot(), before)


if __name__ == '__main__':
    unittest.main()
