"""Removing package editing must not remove ordinary file transfers or App packaging."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DebRemovalTests(unittest.TestCase):
    def test_no_editor_or_mutating_preprocessor_remains(self):
        for path in (ROOT / 'RepoPocket').glob('*.swift'):
            text = path.read_text(encoding='utf-8')
            for obsolete in ('DebControlEditor', 'DebEditorView', 'LocalProjectDebEditor', 'saveRemoteDeb', 'adoptGeneratedDeb', '编辑包信息'):
                self.assertNotIn(obsolete, text, str(path))
        for name in ('DebControlEditor.swift', 'DebEditorView.swift', 'LocalProjectDebEditor.swift'):
            self.assertFalse((ROOT / 'RepoPocket' / name).exists())
        project = (ROOT / 'project.yml').read_text(encoding='utf-8')
        self.assertNotIn('Vendor/DebCodecs', project)
        self.assertIn('Vendor/NativeGit/NativeGitBridge.h', project)
        self.assertIn('-lgit2 -lz', project)

    def test_ordinary_files_still_copy_upload_and_share(self):
        upload = (ROOT / 'RepoPocket/UploadView.swift').read_text(encoding='utf-8')
        for token in ('FileManager.default.copyItem(at: source, to: copy)', 'RepoQueue.addingUploadBytes(actual, to: total)', 'queue.append(contentsOf: pending)', 'var accepted = false', 'if !accepted'):
            self.assertIn(token, upload)
        api = (ROOT / 'RepoPocket/GitHub.swift').read_text(encoding='utf-8')
        for token in ('preparedItems.append((item, file, size))', 'session.upload(for: r, fromFile: file', 'func downloadFile(', 'func downloadAsset('):
            self.assertIn(token, api)
        self.assertIn('UploadView(api: api, initialRepo: repo', (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text(encoding='utf-8'))
        self.assertIn('ReleaseEntryView(api: state.api, initialRepo: state.repo)', (ROOT / 'RepoPocket/ReleaseManagementUI.swift').read_text(encoding='utf-8'))
        self.assertIn('ShareSheet(url: $0.url, bookmark: $0.bookmark)', (ROOT / 'RepoPocket/UpdateFeature.swift').read_text(encoding='utf-8'))
        # Native binary replacement also serves ordinary directory import.
        self.assertIn('LocalGitFileAccess.replaceBinary(', (ROOT / 'RepoPocket/LocalGitImport.swift').read_text(encoding='utf-8'))

    def test_app_debian_builds_are_preserved(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text(encoding='utf-8')
        self.assertIn('iphoneos-arm64.deb', workflow)
        self.assertIn('iphoneos-arm64e.deb', workflow)
        self.assertNotIn('DebControlEditorTests/run-macos.sh', workflow)
        self.assertTrue((ROOT / 'Packaging/control.in').is_file())


if __name__ == '__main__': unittest.main()
