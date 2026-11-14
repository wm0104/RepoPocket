"""Executable Git reference model, NOT a replacement for the shipping bridge tests.
Uses only disposable local repositories. No configured user repository is opened.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which('git'), 'Reference model needs local git')
class HistoryPolicyModel(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root/'work'
        self.work.mkdir()
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.commit('base')
        self.base = self.git('rev-parse', 'HEAD')
        self.origin = self.root/'origin.git'
        self.git('init', '--bare', str(self.origin))
        self.git('remote', 'add', 'origin', self.origin.as_uri())
        self.git('push', '-u', 'origin', 'main')

    def git(self, *args):
        return subprocess.check_output(['git', '-c', 'commit.gpgsign=false', *args], cwd=self.work,
                                       stderr=subprocess.STDOUT).decode().strip()

    def commit(self, name):
        (self.work/name).write_text(name+'\n')
        self.git('add', name)
        self.git('commit', '-m', name)

    def eligible(self, count):
        if self.git('status', '--porcelain'):
            return False
        if self.git('remote').splitlines() != ['origin']:
            return False
        if self.git('config', '--get', 'branch.main.remote') != 'origin':
            return False
        # Fetch only from the synthetic file:// origin, including tags into a
        # private namespace. Never infer publication from a cached ahead count.
        self.git('fetch', 'origin', '+refs/heads/*:refs/remotes/origin/*',
                 '+refs/tags/*:refs/repopocket/fetched-tags/*', '--no-tags')
        published = set(self.git('rev-list', '--remotes', '--tags',
                                 '--glob=refs/repopocket/fetched-tags/*').splitlines())
        tip = self.git('rev-parse', 'HEAD')
        upstream = self.git('rev-parse', '@{upstream}')
        for _ in range(count):
            parents = self.git('show', '-s', '--format=%P', tip).split()
            if tip in published or len(parents) != 1:
                return False
            tip = parents[0]
        return tip == upstream or upstream in self.git('rev-list', tip).splitlines()

    def test_fresh_remote_branch_and_tag_publication_block_rewrite(self):
        self.commit('one')
        self.assertTrue(self.eligible(1))
        self.git('push', 'origin', 'HEAD:refs/heads/review')
        self.assertFalse(self.eligible(1))
        self.git('push', 'origin', ':refs/heads/review')
        self.git('update-ref', '-d', 'refs/remotes/origin/review')
        self.git('tag', 'published')
        self.git('push', 'origin', 'refs/tags/published')
        self.git('tag', '-d', 'published')
        self.assertFalse(self.eligible(1))

    def test_top_contiguous_range_preserves_tree_and_backup(self):
        self.commit('one')
        self.commit('two')
        self.assertTrue(self.eligible(2))
        self.assertFalse(self.eligible(3), 'Cannot cross the fetched publication boundary')
        old = self.git('rev-parse', 'HEAD')
        tree = self.git('rev-parse', 'HEAD^{tree}')
        new = self.git('commit-tree', tree, '-p', self.base, '-m', 'Combined local work')
        self.git('update-ref', 'refs/repopocket/recovery/model', old)
        self.git('update-ref', 'refs/heads/main', new, old)
        self.assertEqual(self.git('rev-parse', 'HEAD^{tree}'), tree)
        self.assertEqual(self.git('rev-parse', 'HEAD^'), self.base)
        self.assertEqual(self.git('rev-parse', 'refs/repopocket/recovery/model'), old)
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_dirty_and_extra_remote_are_conservative_rejections(self):
        self.commit('one')
        (self.work/'precious').write_bytes(b'precious untracked bytes')
        head = self.git('rev-parse', 'HEAD')
        index = (self.work/'.git/index').read_bytes()
        self.assertFalse(self.eligible(1))
        self.assertEqual(self.git('rev-parse', 'HEAD'), head)
        self.assertEqual((self.work/'.git/index').read_bytes(), index)
        self.assertEqual((self.work/'precious').read_bytes(), b'precious untracked bytes')
        (self.work/'precious').unlink()
        self.git('remote', 'add', 'unknown', (self.root/'not-contacted.git').as_uri())
        self.assertFalse(self.eligible(1))


if __name__ == '__main__':
    unittest.main()
