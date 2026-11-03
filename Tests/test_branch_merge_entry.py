"""Integration contracts for the distinct local-Git and remote-PR merge entries."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]

class BranchMergeEntryTests(unittest.TestCase):
    def test_local_merge_is_exposed_under_sync_and_in_local_branch_menu(self):
        project = (ROOT/'RepoPocket/LocalProjectView.swift').read_text()
        menu = (ROOT/'RepoPocket/LocalGitBranchManagement.swift').read_text()
        self.assertIn('LocalGitMergeSourcePicker(', project)
        self.assertIn('localgit.merge', project)
        self.assertIn('Button("合并到当前分支…")', menu)
        self.assertIn('LocalGitMergeView(', menu)
        self.assertIn('source: branch', menu)
        self.assertIn('if !branch.current && !branch.remote', menu)
        self.assertNotIn('remoteBranchMerge', menu)

    def test_remote_merge_is_a_separate_explicit_pr_flow(self):
        menu = (ROOT/'RepoPocket/DesktopViews.swift').read_text().split('struct BranchPickerView: View {',1)[1]
        self.assertIn('Button("合并到其他分支…")', menu)
        self.assertIn('RemoteBranchMergeView(api: api, repo: repo, source: source.name)', menu)
        self.assertIn('Label("删除 GitHub 远端分支"', menu)
        self.assertIn('Label("重命名 GitHub 远端分支"', menu)
        source = (ROOT/'RepoPocket/LocalGitMergeSourcePicker.swift').read_text()
        self.assertIn('LocalGitEngine.shared.run("branches"', source)
        self.assertIn('!$0.current && !$0.remote', source)
        self.assertNotIn('dispatchWorkflow(', source)
        self.assertNotIn('upstreamCompare(', source)

if __name__ == '__main__': unittest.main()
