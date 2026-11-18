"""Flow integration contracts; no network or user file writes."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
def source(name): return (ROOT / 'RepoPocket' / name).read_text()

class FlowIntegrationTests(unittest.TestCase):
    def test_navigation_has_no_publish_tab_or_troll_surface(self):
        app, upload = source('RepoPocketApp.swift'), source('UploadView.swift')
        self.assertNotIn('Label("提交 / 发布"', app)
        self.assertNotIn('@State private var mode', upload)
        self.assertNotIn('TrollMetadataView', app)
        self.assertNotIn('TrollFools', upload)
        self.assertIn('UpdateTabBadge(tabIndex: 2', app)


    def test_repository_and_release_keep_their_inbox_routes_without_a_home_file_surface(self):
        app = source('RepoPocketApp.swift')
        self.assertNotIn('ExternalInboxSection', app)
        self.assertIn('if canWrite && (showFiles || !path.isEmpty) { Button("上传")', app)
        self.assertIn('UploadView(api: api, initialRepo: repo, directory: path, initialBranch: activeBranch, openedFromFolder: true)', app)
        upload = source('UploadView.swift')
        for text in ('Button("待上传文件")', 'ShareInboxView(multiple: true)', 'await select(.success(files))', 'ShareSelectionCleanup.remove(files)', '.fileImporter('):
            self.assertIn(text, upload)
        entry = source('ReleaseEntryView.swift')
        self.assertNotIn('检查权限并继续', entry)
        self.assertNotIn('.sheet', entry)
        self.assertIn('allowsRepositorySelection: true', entry)
        ui = source('ReleaseManagementUI.swift')
        self.assertIn('ReleaseEntryView(api: state.api, initialRepo: state.repo)', ui)
        self.assertEqual(ui.count('ShareInboxView('), 2)
        self.assertIn('Button("从待上传文件选择")', ui)
        self.assertIn('确认创建仓库并', ui)
        self.assertIn('检查并重试', ui)
        self.assertNotIn('.alert(form.draft', ui)

    def test_hiding_home_files_preserves_imports_and_does_not_consume_the_inbox(self):
        app = source('RepoPocketApp.swift')
        self.assertIn('.onOpenURL { url in', app)
        self.assertIn('ShareInboxStore.live().importFile(url)', app)
        self.assertIn('store.importFile(source', (ROOT / 'ShareExtension/ShareViewController.swift').read_text())
        picker = source('ShareInboxView.swift')
        self.assertIn('ShareInboxStore.live().stage(chosen)', picker)
        self.assertIn('ShareInboxStore.live().remove(item)', picker)
        for name in ('RepoPocketApp.swift', 'UploadView.swift', 'ReleaseManagementUI.swift'):
            self.assertNotIn('ShareInboxStore.live().remove', source(name))

    def test_upload_confirmation_stays_open_and_rechecks(self):
        upload = source('UploadView.swift')
        self.assertIn('检查并重试', upload)
        self.assertIn('preflightCommit()', upload)
        self.assertNotIn('submitAfterDismiss', upload)
        self.assertIn('RepoQueue.readiness', upload)
        self.assertIn('try await api.requireWriteAccess', upload)


    def test_existing_release_attachment_is_copied_before_review(self):
        review = source('ReleaseAttachmentReview.swift')
        for token in ('ReleaseAttachmentRules.copy(input)', 'generation == AccountStore.generation', 'api.requireWriteAccess(repo)', 'current == original', 'verify(attachment) == authorizedHash', '检查并重试', 'authorizedHash = nil', 'ShareSelectionCleanup.remove([source])'):
            self.assertIn(token, review)
        detail = source('ReleaseManagementUI.swift').split('struct ReleaseDetailView:', 1)[1].split('struct ReleaseEditorView:', 1)[0]
        self.assertIn('ReleaseAttachmentReview(', detail)
        self.assertNotIn('.alert("确认上传附件"', detail)

if __name__ == '__main__': unittest.main()
