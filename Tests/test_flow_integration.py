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

    def test_save_adopts_before_dismiss_and_propagates_failure(self):
        editor, upload = source('DebEditorView.swift'), source('UploadView.swift')
        self.assertIn('((URL) throws -> Void)?', editor)
        self.assertIn('保存并返回', editor)
        self.assertIn('try onUseForUpload(target)', editor)
        self.assertIn('try adoptGeneratedDeb(generated, replacing: item.id)', upload)
        self.assertIn('queue[index].replaceLocal', upload)
        self.assertIn('throw error', upload.split('private func adoptGeneratedDeb', 1)[1])

    def test_explicit_file_routes_and_release_single_form(self):
        route = source('ExternalFileActions.swift')
        for text in ('NativeActionMenu', '提交到仓库', '作为发行附件', '存储 / 分享', 'initialFiles: [file]'):
            self.assertIn(text, route)
        entry = source('ReleaseEntryView.swift')
        self.assertNotIn('检查权限并继续', entry)
        self.assertNotIn('.sheet', entry)
        self.assertIn('allowsRepositorySelection: true', entry)
        ui = source('ReleaseManagementUI.swift')
        self.assertIn('initialFiles', ui)
        self.assertIn('确认创建仓库并', ui)
        self.assertIn('检查并重试', ui)
        self.assertNotIn('.alert(form.draft', ui)

    def test_upload_confirmation_stays_open_and_rechecks(self):
        upload = source('UploadView.swift')
        self.assertIn('检查并重试', upload)
        self.assertIn('preflightCommit()', upload)
        self.assertNotIn('submitAfterDismiss', upload)
        self.assertIn('RepoQueue.readiness', upload)
        self.assertIn('try await api.requireWriteAccess', upload)

    @unittest.skipUnless(__import__('shutil').which('swiftc'), 'Production adoption/hash fixture requires macOS Swift/CryptoKit')
    def test_production_owned_adoption_and_review_invalidation(self):
        import subprocess, tempfile
        upload = source('UploadView.swift')
        methods = '    private func adoptGeneratedDeb' + upload.split('    private func adoptGeneratedDeb', 1)[1].split('    @MainActor private func openTargetPicker', 1)[0]
        harness = (ROOT / 'Tests/Fixtures/FlowIntegrationHarness.swift').read_text()
        harness = harness.replace('// PRODUCTION_ADOPTION', methods).replace('// PRODUCTION_BUDGET', '')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Flow.swift'
            path.write_text(source('RepoQueue.swift') + '\n' + harness)
            executable = str(Path(directory) / 'flow-test')
            subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', executable], check=True)
            subprocess.run([executable], check=True, timeout=30)

    def test_existing_release_attachment_is_copied_before_review(self):
        review = source('ReleaseAttachmentReview.swift')
        for token in ('ReleaseAttachmentRules.copy(input)', 'generation == AccountStore.generation', 'api.requireWriteAccess(repo)', 'current == original', 'verify(attachment) == authorizedHash', '检查并重试', 'authorizedHash = nil', 'ShareSelectionCleanup.remove([source])'):
            self.assertIn(token, review)
        detail = source('ReleaseManagementUI.swift').split('struct ReleaseDetailView:', 1)[1].split('struct ReleaseEditorView:', 1)[0]
        self.assertIn('ReleaseAttachmentReview(', detail)
        self.assertNotIn('.alert("确认上传附件"', detail)

if __name__ == '__main__': unittest.main()
