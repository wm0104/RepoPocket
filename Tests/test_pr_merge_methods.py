from pathlib import Path
import shutil
import unittest
from repository_operations_support import run_operations_fixture

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    path = ROOT / 'RepoPocket' / name
    return path.read_text(encoding='utf-8') if path.exists() else ''


class PRMergeMethodTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Production PR transport/state requires native Swift')
    def test_production_three_methods_gates_and_lost_responses(self):
        run_operations_fixture('pr')

    def test_three_methods_respect_repository_and_github_rules(self):
        text = source('PullRequestMerge.swift')
        for token in ['case merge, squash, rebase', 'allow_merge_commit', 'allow_squash_merge',
                      'allow_rebase_merge', 'mergeStateStatus', 'reviewDecision', 'rebaseable']:
            self.assertTrue(token in text, token)

    def test_confirmation_freezes_sha_method_and_reconciles_unknown_result(self):
        text = source('PullRequestMerge.swift')
        for token in ['head.sha', 'base.sha', 'AccountStore.generation', 'pending',
                      'reconcile', 'api.isCurrentSession']:
            self.assertTrue(token in text, token)
        api = source('GitHub.swift')
        self.assertIn('"merge_method": confirmation.method.rawValue', api)
        self.assertIn('"sha": confirmation.options.pull.head.sha', api)

    def test_confirmation_and_reconciliation_keep_the_same_branch_identity(self):
        text = source('PullRequestMerge.swift')
        self.assertIn('let node_id: String', text)
        self.assertIn('fresh.repository.node_id == confirmation.options.repository.node_id', text)
        self.assertEqual(text.count('self.sameBranches(fresh.pull, as: confirmation.options.pull)'), 1)
        self.assertIn('sameBranches(fresh, as: confirmation.options.pull)', text)
        for field in ['head.ref', 'base.ref', 'head.repo?.full_name', 'base.repo?.full_name']:
            self.assertIn('pull.' + field, text)

    def test_detail_uses_the_existing_navigation_and_native_confirmation(self):
        self.assertIn('PullRequestMergeView(api: api, repo: repo, number: number)', source('CollaborationViews.swift'))
        text = source('PullRequestMergeView.swift')
        for token in ['NativeActionMenu', '.confirmationDialog', 'SoftGroupRows', '只读核实']:
            self.assertTrue(token in text, token)


if __name__ == '__main__':
    unittest.main()
