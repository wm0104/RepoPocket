"""Keep related destructive-operation controls, preview and status in one native group."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1] / 'RepoPocket'


def source(name):
    return (ROOT / name).read_text(encoding='utf-8')


class CompactOperationGroupsTests(unittest.TestCase):
    def test_remote_merge_preview_and_status_are_native_sibling_rows(self):
        page = source('RemoteBranchMergeView.swift')
        self.assertEqual(len(re.findall(r'\bSection\s*(?:\(|\{)', page)), 1)
        self.assertIn('Section("远端 PR · Squash")', page)
        self.assertEqual(page.count('SoftGroupRows {'), 1)
        for heading in ['sha-heading', 'commits-heading', 'files-heading', 'actions-heading', 'failure-heading', 'result-heading']:
            self.assertIn(f'SoftGroupRow("{heading}")', page)
        for row in ['repository', 'source', 'target', 'notice', 'head', 'base', 'race', 'busy', 'failure', 'result']:
            self.assertIn(f'SoftGroupRow("{row}")', page)
        self.assertNotIn('.softGroupedRow(', page)

    def test_local_history_preview_and_status_continue_the_operation_group(self):
        page = source('LocalGitHistoryActions.swift')
        self.assertEqual(len(re.findall(r'\bSection\s*(?:\(|\{)', page)), 1)
        self.assertIn('Section("当前分支：" + context.status.branch)', page)
        self.assertEqual(page.count('SoftGroupRows {'), 1)
        self.assertIn('SoftGroupRow("preview-heading") { Text("确认前预览")', page)
        for row in ['operation', 'explanation', 'proof', 'head', 'apply', 'busy', 'error', 'result']:
            self.assertIn(f'SoftGroupRow("{row}")', page)
        self.assertNotIn('.softGroupedRow(', page)

    def test_repository_deletion_has_one_semantic_group_and_outer_corners(self):
        page = source('RepositoryDeletionView.swift')
        self.assertEqual(len(re.findall(r'\bSection\s*(?:\(|\{)', page)), 1)
        self.assertIn('Section("危险操作：永久删除 GitHub 远端仓库")', page)
        self.assertIn('Text("已预填所选仓库，无需输入").font(.subheadline).foregroundStyle(.secondary).softGroupedRow()', page)
        self.assertIn('Text(RepositoryDeletion.permissionHelp).font(.caption).softGroupedRow()', page)
        self.assertEqual(page.count('.softGroupedRow(top: true)'), 1)
        self.assertEqual(page.count('.softGroupedRow(bottom: true)'), 1)
        self.assertIn('}.disabled(!canDelete).softGroupedRow(bottom: true)', page)


if __name__ == '__main__':
    unittest.main()
