"""Local merge seam: shipping bridge + disposable Git repositories; never simulate native success."""
from pathlib import Path
import platform
import unittest
import test_local_git_native as fixtures

ROOT = Path(__file__).resolve().parents[1]


class LocalMergeContracts(unittest.TestCase):
    def test_native_dispatch_and_manual_recovery_guard(self):
        source = (ROOT / 'Vendor/NativeGit/NativeGitBridge.m').read_text()
        self.assertIn('[op isEqual:@"mergePreview"]', source)
        self.assertIn('[op isEqual:@"mergeBranch"]', source)
        self.assertIn('git_merge_commits', source)
        self.assertIn('[intent[@"operation"] isEqual:@"mergeBranch"]', source)

    def test_view_pins_preview_and_reuses_author_workflow(self):
        engine = (ROOT / 'RepoPocket/LocalGitEngine.swift').read_text()
        policy = engine.split('coordinate(root, writing: ', 1)[1].split('.contains(operation)', 1)[0]
        self.assertIn('"mergeBranch"', policy)
        self.assertNotIn('"mergePreview"', policy)
        view = (ROOT / 'RepoPocket/LocalGitMerge.swift').read_text()
        for text in ('struct LocalGitMergeView: View', 'localGit.authorName', 'localGit.authorEmail',
                     'expectedHead', 'expectedRef', 'sourceRef', 'sourceSHA', 'CommitPatchView',
                     'SoftGroupRow(', 'AccountStore.generation', 'Task.checkCancellation', 'isValid()'):
            self.assertIn(text, view)


@unittest.skipUnless(platform.system() == 'Darwin', 'requires macOS Foundation and production libgit2')
class LocalMergeNative(unittest.TestCase):
    setUpClass = classmethod(fixtures.NativeGitBehavior.setUpClass.__func__)
    setUp = fixtures.NativeGitBehavior.setUp
    git = fixtures.NativeGitBehavior.git
    call = fixtures.NativeGitBehavior.call
    result = fixtures.NativeGitBehavior.result

    def feature(self, conflict=False, diverge=False, ignored=False):
        self.git('checkout', '-b', 'feature')
        path = 'ignored' if ignored else ('代码.py' if conflict else 'feature.txt')
        (self.work / path).write_text('source content\n')
        self.git('add', '-f', path)
        self.git('commit', '-m', 'source commit')
        source = self.git('rev-parse', 'HEAD')
        self.git('checkout', 'main')
        if diverge:
            (self.work / ('代码.py' if conflict else 'main.txt')).write_text('target content\n')
            self.git('add', '.')
            self.git('commit', '-m', 'target commit')
        self.head = self.git('rev-parse', 'HEAD')
        return dict(expectedHead=self.head, sourceRef='refs/heads/feature', sourceSHA=source,
                    method='ordinary', authorName='Fixture', authorEmail='fixture@example.invalid', message='Merge feature')

    def snapshot(self):
        files = {str(p.relative_to(self.work)): p.read_bytes() for p in self.work.rglob('*')
                 if p.is_file() and '.git' not in p.relative_to(self.work).parts}
        objects = {str(p.relative_to(self.work)): p.read_bytes()
                   for p in (self.work / '.git/objects').rglob('*') if p.is_file()}
        return (self.git('show-ref'), (self.work / '.git/HEAD').read_bytes(),
                (self.work / '.git/index').read_bytes(), files, objects)

    def refused(self, args):
        before = self.snapshot()
        self.assertFalse(self.call('mergeBranch', **args)['ok'])
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.work / '.git/repopocket-transaction.json').exists())

    def test_fast_forward_and_already_contained(self):
        args = self.feature()
        before = self.snapshot()
        preview = self.result('mergePreview', **args)
        self.assertEqual(self.snapshot(), before)
        self.assertTrue(preview['fastForward'])
        self.assertEqual(preview['files'][0]['filename'], 'feature.txt')
        for key in ('authorName', 'authorEmail', 'message'):
            del args[key]
        self.result('mergeBranch', **args)
        self.assertEqual(self.git('rev-parse', 'HEAD'), args['sourceSHA'])
        self.assertEqual(self.git('status', '--porcelain'), '')
        args['expectedHead'] = args['sourceSHA']
        before = self.snapshot()
        self.result('mergeBranch', **args)
        self.assertEqual(self.snapshot(), before)

    def test_diverged_true_two_parent_commit_and_squash_one_parent(self):
        args = self.feature(diverge=True)
        expected_tree = self.git('merge-tree', '--write-tree', 'HEAD', 'feature').splitlines()[0]
        for method, parent_count in [('squash', 1), ('ordinary', 2)]:
            args['method'] = method
            self.result('mergeBranch', **args)
            parents = self.git('show', '-s', '--format=%P', 'HEAD').split()
            self.assertEqual(len(parents), parent_count)
            self.assertEqual(parents[0], args['expectedHead'])
            if parent_count == 2:
                self.assertEqual(parents[1], args['sourceSHA'])
            self.assertEqual(self.git('rev-parse', 'HEAD^{tree}'), expected_tree)
            self.assertEqual(self.git('status', '--porcelain'), '')
            # Fixture-only reset to independently exercise the other method.
            self.git('reset', '--hard', args['expectedHead'])

    def test_same_file_automerge_preview_never_writes_synthesized_blob(self):
        baseline = ''.join(f'line {i}\n' for i in range(30))
        (self.work / 'lines.txt').write_text(baseline)
        self.git('add', '.')
        self.git('commit', '-m', 'multiline base')
        self.git('checkout', '-b', 'feature')
        (self.work / 'lines.txt').write_text(baseline.replace('line 1\n', 'source line\n'))
        self.git('add', '.')
        self.git('commit', '-m', 'source edit')
        source = self.git('rev-parse', 'HEAD')
        self.git('checkout', 'main')
        (self.work / 'lines.txt').write_text(baseline.replace('line 28\n', 'target line\n'))
        self.git('add', '.')
        self.git('commit', '-m', 'target edit')
        args = dict(expectedHead=self.git('rev-parse', 'HEAD'), sourceRef='refs/heads/feature',
                    sourceSHA=source, method='squash')
        before = self.snapshot()
        preview = self.result('mergePreview', **args)
        self.assertEqual(preview['conflicts'], [])
        self.assertIn('+source line', preview['files'][0]['patch'])
        self.assertEqual(self.snapshot(), before)
        self.refused(args)  # No author: even synthesized objects stay in memory.
        self.result('mergeBranch', **dict(args, authorName='Fixture', authorEmail='fixture@example.invalid', message='Squash'))
        self.assertEqual((self.work / 'lines.txt').read_text(), baseline.replace('line 1\n', 'source line\n').replace('line 28\n', 'target line\n'))
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_submodule_budget_and_missing_author_refuse(self):
        args = self.feature(diverge=True)
        self.refused(dict(args, authorName=''))
        (self.work / '.gitmodules').write_text('[submodule "sample"]\n')
        self.refused(args)
        (self.work / '.gitmodules').unlink()
        self.git('update-index', '--add', '--cacheinfo', '160000,' + self.head + ',module')
        self.refused(args)

    def test_interrupted_merge_requires_manual_inspection_not_legacy_recovery(self):
        import json
        args = self.feature()
        journal = self.work / '.git/repopocket-transaction.json'
        journal.write_text(json.dumps(dict(operation='mergeBranch', reference='refs/heads/main',
                                          oldHead=self.head, newHead=args['sourceSHA'], preparedIndex='repopocket-index-fixture')))
        (self.work / 'precious-untracked.txt').write_text('never clean me')
        before = self.snapshot()
        reply = self.call('recover', expectedHead=self.head)
        self.assertFalse(reply['ok'])
        self.assertIn('桌面 Git', reply['error'])
        self.assertTrue(journal.exists())
        self.assertEqual(self.snapshot(), before)

    def test_conflict_preview_and_apply_never_mutate(self):
        args = self.feature(conflict=True, diverge=True)
        before = self.snapshot()
        preview = self.result('mergePreview', **args)
        self.assertIn('代码.py', preview['conflicts'])
        self.assertEqual(self.snapshot(), before)
        self.refused(args)

    def test_dirty_staged_untracked_ignored_collision_and_stale_pins(self):
        args = self.feature(ignored=True)
        for path, stage in [('other.txt', False), ('other.txt', True), ('untracked.txt', False), ('ignored', False)]:
            with self.subTest(path=path, stage=stage):
                original = (self.work / path).read_bytes() if (self.work / path).exists() else None
                (self.work / path).write_text('precious user edit\n')
                if stage:
                    self.git('add', path)
                self.refused(args)
                if stage:
                    self.git('reset', 'HEAD', '--', path)
                if original is None:
                    (self.work / path).unlink()
                else:
                    (self.work / path).write_bytes(original)
        for change in ({'expectedHead': '0'*40}, {'expectedRef': 'refs/heads/other'},
                       {'sourceSHA': '0'*40}, {'sourceRef': 'refs/remotes/origin/feature'}):
            self.refused(dict(args, **change))
        self.git('update-ref', 'refs/heads/feature', self.head)
        self.refused(args)

    def test_cancellation_rootguard_detached_and_in_progress(self):
        args = self.feature()
        self.native.rp_git_cancel(b'cancel-local-merge')
        self.refused(dict(args, requestID='cancel-local-merge'))
        wrong = self.work.parent / 'wrong'
        wrong.mkdir()
        self.refused(dict(args, workdir=str(wrong)))
        self.git('checkout', '--detach', self.head)
        self.refused(args)
        self.git('checkout', 'main')
        marker = self.work / '.git/MERGE_HEAD'
        marker.write_text(args['sourceSHA']+'\n')
        self.refused(args)


if __name__ == '__main__':
    unittest.main()
