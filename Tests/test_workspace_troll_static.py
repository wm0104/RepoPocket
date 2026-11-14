"""Source-level regressions for 0.4 workspaces and TrollFools.
Run with python3 Tests/test_workspace_troll_static.py when Swift/Xcode are unavailable.
These tests do not replace iOS compilation or device tests.
"""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import unittest

ROOT = REPO_ROOT / "RepoPocket"


class WorkspaceTrollStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = (ROOT / "WorkspaceView.swift").read_text()
        cls.remote = (ROOT / "WorkspaceRemote.swift").read_text()
        cls.upload = (ROOT / "UploadView.swift").read_text()
        cls.github = (ROOT / "GitHub.swift").read_text()

    def test_remote_paths_and_guards(self):
        self.assertIn("WorkspaceMerge.remoteChanges", self.workspace)
        for status in ('"新增"', '"修改"', '"删除"'):
            self.assertIn(status, self.remote)
        self.assertIn("workspaceHead(binding.repo, branch: binding.branch) == pending.binding.head", self.workspace)
        self.assertIn("lastChecked = Date()", self.workspace)
        self.assertIn("lastPulled = Date()", self.github)
        self.assertIn("remoteAuthorDate: commit.author?.date", self.github)

    def test_delete_is_local_and_double_confirmed(self):
        self.assertIn("confirmDelete", self.workspace)
        self.assertIn("confirmDirtyDelete", self.workspace)
        self.assertIn("LocalStore.changes([target])", self.workspace)
        self.assertIn("LocalStore.removeWorkspace(target)", self.workspace)
        self.assertIn("fm.moveItem(at: folder, to: savedFolder)", self.workspace)
        self.assertIn("fm.moveItem(at: savedFolder, to: folder)", self.workspace)
        self.assertNotIn(".swipeActions", self.workspace)
        self.assertIn(".contextMenu", self.workspace)

    def test_plugin_routes_are_removed_without_touching_workspace_safety(self):
        for token in ('trollName', 'trollVersion', 'trollDescription', 'trollPreview', 'TrollFools'):
            self.assertNotIn(token, self.upload)
        self.assertNotIn('func trollPublish(', self.github)
        self.assertNotIn('trollpackages.json', self.github)
        self.assertIn('"force": false', self.github)
        self.assertIn('"parents": [head]', self.github)

    def test_common_upload_stays_bounded_and_streamed(self):
        self.assertNotIn('maximumTrollPluginBytes', self.upload)
        self.assertIn('RepoQueue.addingUploadBytes', self.upload)
        self.assertIn('DebControlEditor.prepareForUpload', self.upload)
        self.assertIn('session.upload(for: uploadRequest, fromFile: bodyFile)', self.github)
        self.assertIn('uploadGitBlobFile(', self.github)


if __name__ == "__main__":
    unittest.main()
