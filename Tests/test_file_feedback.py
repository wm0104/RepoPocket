from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class FileFeedbackTests(unittest.TestCase):
    def test_local_deb_reopen_waits_for_post_save_readiness(self):
        source = (ROOT/'StyleUITests/StyleBoundaryTests.swift').read_text(encoding='utf-8')
        case = source.split('    func testLocalDEBUsesExistingEditorAndSavesToProject()', 1)[1].split('    func testLocalWholeFolderImportsAllChildrenAndSelectsThem()', 1)[0]
        reopen = case.split('        save.tap()', 1)[1]
        self.assertIn('menu.exists && menu.isEnabled && menu.isHittable', reopen)
        self.assertLess(reopen.index('menu.exists && menu.isEnabled && menu.isHittable'), reopen.index('menu.tap()'))
        self.assertIn('XCTAssertTrue(edit.waitForExistence(timeout: 5))', reopen)
        self.assertIn('XCTAssertEqual(version.value as? String, "2.0"', reopen)

    def test_project_file_delete_has_one_long_press_entry(self):
        source = (ROOT/'RepoPocket/LocalProjectEditor.swift').read_text(encoding='utf-8')
        files = source.split('struct LocalProjectFilesView:',1)[1]
        self.assertNotIn('Image(systemName: "ellipsis")',files)
        self.assertNotIn('更多操作：',files)
        self.assertIn('.contextMenu { Button("删除此文件", role: .destructive)',files)
        self.assertIn('LocalProjectDebEditor(api: api', files)
        self.assertIn('LocalProjectEditor(project: project', files)

    def test_zip_completion_is_dismissible_and_only_after_saved(self):
        source = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text(encoding='utf-8')
        browser = source.split('struct BrowserView:',1)[1].split('struct FileView:',1)[0]
        self.assertNotIn('Text(downloadNotice)', browser)
        self.assertIn('.downloadCompletionNotice($downloadedZIP)',browser)
        operation = browser.split('private func zip() async',1)[1]
        self.assertLess(operation.index('try await DownloadStore.shared.persist'),operation.index('downloadedZIP = saved'))
        self.assertIn('guard api.isCurrentSession else { throw CancellationError() }', operation)

    def test_all_download_destinations_use_the_shared_native_presenter(self):
        for name, token in [('RepoPocketApp.swift','$downloadedFile'),('WorkflowViews.swift','$downloadedArtifact'),('UploadView.swift','$downloadedAsset'),('ReleaseManagementUI.swift','$state.completedDownload'),('UpdateFeature.swift','$checker.downloadCompletion')]:
            text = (ROOT/'RepoPocket'/name).read_text(encoding='utf-8')
            self.assertIn('.downloadCompletionNotice(' + token + ')', text)
            self.assertNotIn('已下载并保存到 ',text)
            self.assertNotIn('已保存 ZIP 到 ',text)
            self.assertNotIn('已保存到 " + DownloadStore.shared.label',text)

if __name__ == '__main__': unittest.main()
