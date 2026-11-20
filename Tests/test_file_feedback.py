from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class FileFeedbackTests(unittest.TestCase):

    def test_deb_menu_waits_for_ready_expansion_and_targets_the_file_button(self):
        ui = (ROOT/'StyleUITests/StyleBoundaryTests.swift').read_text()
        case = ui.split('func testLocalDEBHasNoPackageEditingAction()', 1)[1].split('\n    func ', 1)[0]
        self.assertIn('tapReady(folder, in: app)', case)
        self.assertIn('"value == %@", "已展开"', case)
        self.assertIn('app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "package-01.deb", "package-01.deb、"))', case)
        self.assertIn('XCTAssertEqual(files.count, 1', case)
        self.assertIn('waitReady(file, in: app)', case)
        self.assertNotIn('app.staticTexts["package-01.deb"]', case)
        for token in ['file.press(forDuration: 1)', 'app.buttons["删除文件"].waitForExistence',
                      'XCTAssertFalse(app.buttons["编辑包信息"].exists)', 'local-deb-ordinary-file']:
            self.assertIn(token, case)

    def test_project_file_delete_has_one_long_press_entry(self):
        source = (ROOT/'RepoPocket/LocalProjectEditor.swift').read_text(encoding='utf-8')
        files = source.split('struct LocalProjectFilesView:',1)[1]
        self.assertNotIn('Image(systemName: "ellipsis")',files)
        self.assertNotIn('更多操作：',files)
        self.assertIn('.contextMenu { Button("删除此文件", role: .destructive)',files)
        self.assertNotIn('LocalProjectDebEditor', files)
        self.assertIn('LocalProjectEditor(project: project', files)

    def test_zip_completion_is_nonblocking_and_only_after_saved(self):
        source = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text(encoding='utf-8')
        browser = source.split('struct BrowserView:',1)[1].split('struct FileView:',1)[0]
        self.assertNotIn('Text(downloadNotice)', browser)
        self.assertNotIn('downloadCompletionNotice', browser)
        self.assertNotIn('downloadedZIP', browser)
        operation = browser.split('private func zip() async',1)[1]
        self.assertLess(operation.index('try await downloads.persist(file, session: session)'), operation.index('AppFeedback.show("下载完成", session: session)'))
        self.assertIn('guard api.isCurrentSession, session == AccountStore.generation else { throw CancellationError() }', operation)
        self.assertIn('zipRequest == request', operation)
        self.assertIn('zipStatus = "正在保存…"', operation)
        store = (ROOT/'RepoPocket/DownloadStore.swift').read_text(encoding='utf-8')
        self.assertIn('NSFileCoordinator().coordinate(', store)
        self.assertIn('DownloadRules.save(temporary, parent: coordinated', store)

    def test_all_download_destinations_use_final_success_feedback(self):
        for name in ['RepoPocketApp.swift', 'WorkflowViews.swift', 'ReleaseManagementUI.swift', 'UpdateFeature.swift']:
            text = (ROOT/'RepoPocket'/name).read_text(encoding='utf-8')
            self.assertNotIn('.downloadCompletionNotice(', text)
            self.assertIn('AppFeedback.show("下载完成"', text)
            self.assertNotIn('已下载并保存到 ', text)
            self.assertNotIn('已保存 ZIP 到 ', text)
        preview = (ROOT/'RepoPocket/DownloadCompletionNotice.swift').read_text()
        self.assertNotIn('.alert(', preview)
        self.assertNotIn('ViewModifier', preview)
        ui = (ROOT/'StyleUITests/StyleBoundaryTests.swift').read_text()
        case = ui.split('func testRepositoryZIPCompletionIsNativeDismissibleAndReusable()', 1)[1].split('func testLocalBranchCreation', 1)[0]
        for token in ['app-success-feedback', 'feedback-through-button', 'feedback-stale-button', '已接收 75%', 'exists == false']:
            self.assertIn(token, case)
        self.assertNotIn('alert.buttons["好"].tap()', case)

    def test_attachment_and_account_results_keep_true_completion_and_details(self):
        upload = (ROOT/'RepoPocket/ReleaseAttachmentReview.swift').read_text().split('private func upload()', 1)[1]
        self.assertLess(upload.index('api.uploadManagedAsset'), upload.index('AppFeedback.show("附件上传成功", api: api)'))
        self.assertIn('try Task.checkCancellation()', upload)
        self.assertIn('guard valid else { throw CancellationError() }', upload)
        app = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
        self.assertNotIn('.alert("GitHub 授权成功"', app)
        self.assertIn('accountPresentation.authorizationDetails = message', app)
        self.assertIn('AppFeedback.show("GitHub 授权成功")', app)
        account = (ROOT/'RepoPocket/AccountManagement.swift').read_text()
        self.assertIn('Text(details)', account)
        self.assertIn('presentation.authorizationDetails', account)

if __name__ == '__main__': unittest.main()
