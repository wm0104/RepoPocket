from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class FileFeedbackTests(unittest.TestCase):

    def test_project_file_delete_has_one_long_press_entry(self):
        source = (ROOT/'RepoPocket/LocalProjectEditor.swift').read_text(encoding='utf-8')
        files = source.split('struct LocalProjectFilesView:',1)[1]
        self.assertNotIn('Image(systemName: "ellipsis")',files)
        self.assertNotIn('更多操作：',files)
        self.assertIn('.contextMenu { Button("删除此文件", role: .destructive)',files)
        self.assertNotIn('LocalProjectDebEditor', files)
        self.assertIn('LocalProjectEditor(project: project', files)

    def test_zip_completion_is_dismissible_and_only_after_saved(self):
        source = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text(encoding='utf-8')
        browser = source.split('struct BrowserView:',1)[1].split('struct FileView:',1)[0]
        self.assertNotIn('Text(downloadNotice)', browser)
        self.assertIn('.downloadCompletionNotice($downloadedZIP)',browser)
        operation = browser.split('private func zip() async',1)[1]
        self.assertLess(operation.index('try await downloads.persist(file, session: session)'),operation.index('downloadedZIP = saved'))
        store = (ROOT/'RepoPocket/DownloadStore.swift').read_text(encoding='utf-8')
        self.assertIn('NSFileCoordinator().coordinate(', store)
        self.assertIn('DownloadRules.save(temporary, parent: coordinated', store)
        self.assertIn('guard api.isCurrentSession else { throw CancellationError() }', operation)

    def test_all_download_destinations_use_the_shared_native_presenter(self):
        for name, token in [('RepoPocketApp.swift','$downloadedFile'),('WorkflowViews.swift','$downloadedArtifact'),('ReleaseManagementUI.swift','$state.completedDownload'),('UpdateFeature.swift','$checker.downloadCompletion')]:
            text = (ROOT/'RepoPocket'/name).read_text(encoding='utf-8')
            self.assertIn('.downloadCompletionNotice(' + token + ')', text)
            self.assertNotIn('已下载并保存到 ',text)
            self.assertNotIn('已保存 ZIP 到 ',text)
            self.assertNotIn('已保存到 " + DownloadStore.shared.label',text)

if __name__ == '__main__': unittest.main()
