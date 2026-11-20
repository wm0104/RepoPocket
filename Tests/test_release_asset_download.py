from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]

class ReleaseAssetDownloadTests(unittest.TestCase):
    def test_external_download_saves_once_and_only_cleans_the_temporary_parent(self):
        source=(ROOT/'RepoPocket/ReleaseAssetDownload.swift').read_text()
        for token in ['DownloadStore.shared.begin()', 'DownloadStore.shared.end()', 'api.downloadManagedAssetWithProgress(repo, asset: asset, transfer: update)', 'DownloadStore.shared.persist(file, session: generation)']:
            self.assertIn(token,source)
        ui=(ROOT/'RepoPocket/ReleaseManagementUI.swift').read_text()
        self.assertIn('defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }',ui)
        self.assertIn('.onDisappear { state.cancel() }',ui)
        github=(ROOT/'RepoPocket/GitHub.swift').read_text()
        download=github.split('    func downloadManagedAssetWithProgress(',1)[1].split('\n    }',1)[0]
        self.assertIn('guard asset.id > 0',download)
    def test_compact_actions_inline_progress_and_request_identity(self):
        ui=(ROOT/'RepoPocket/ReleaseManagementUI.swift').read_text()
        row=ui.split('for asset in state.assets {',1)[1].split('if state.assets.isEmpty',1)[0]
        self.assertEqual(row.count('SoftGroupRow("asset-\\(asset.id)")'),1)
        self.assertNotIn('.softGroupedRow(',row)
        for token in ['Image(systemName:', '.frame(width: 24)', 'Text(asset.name)', '.font(.caption).foregroundStyle(Color.secondary)', 'minHeight: 44', 'Menu {', 'assetActions(asset)', 'if state.canWrite', 'ReleaseAssetDownloadStatusView(']: self.assertIn(token,row)
        self.assertNotIn('LocalGitFileLabel(',row)
        self.assertIn('self.assetDownload?.request == initial.request',ui)
        self.assertIn('self.assetDownload?.stage == .connecting || self.assetDownload?.stage == .downloading',ui)
        self.assertNotIn('presenting: assetAction',ui)
        self.assertNotIn('ellipsis',row)
        self.assertIn('.contentShape(Rectangle())',row)
        self.assertIn('target.generation == AccountStore.generation',ui)
        delegate=(ROOT/'RepoPocket/ReleaseAssetDownload.swift').read_text()
        self.assertIn('ReleaseAssetRedirectPolicy()',delegate)
        self.assertNotIn('Timer',delegate)

    def test_retry_hit_area_is_inside_its_button_label_and_failures_keep_diagnostics(self):
        status=(ROOT/'RepoPocket/ReleaseAssetDownloadStatusView.swift').read_text()
        self.assertIn('Button(action: retry) {',status)
        retry=status.split('Button(action: retry) {',1)[1].split('}.buttonStyle(.borderless)',1)[0]
        self.assertIn('Text("重试")',retry)
        self.assertIn('.frame(minWidth: 44, minHeight: 44)',retry)
        self.assertIn('.contentShape(Rectangle())',retry)
        self.assertIn('.accessibilityIdentifier("release-download-retry-\\(download.assetID)")',status)
        preview=(ROOT/'RepoPocket/ReleaseDownloadStylePreview.swift').read_text()
        for token in ['@Published private(set) var attempts = 0', 'ReleaseDownloadDiagnostics(state: state, downloader: downloader)', 'release-download-fixture-state', 'busy=\\(state.busy)', 'valid=\\(state.valid)']:
            self.assertIn(token,preview)
        test=(ROOT/'StyleUITests/StyleBoundaryTests.swift').read_text().split('    func testReleaseAttachmentsUseNativeActionsAndInlineDownloadStates()',1)[1].split('    func testSharedProfileFollowStateAndFailureHandling()',1)[0]
        for token in ['addTeardownBlock', 'failureCount', 'release-download-failure', 'app.debugDescription', 'hierarchy.lifetime = .keepAlways', "value CONTAINS '40%'", "label == '下载已取消'", 'completion.waitForExistence(timeout: 15)']:
            self.assertIn(token,test)

    @unittest.skipUnless(shutil.which('swiftc'),'Production Swift regression runs on macOS')
    def test_production_controller_and_real_progress_delegate(self):
        ui=(ROOT/'RepoPocket/ReleaseManagementUI.swift').read_text()
        state=ui.split('@MainActor final class ReleaseScreenState:',1)[1].split('struct ReleaseListView:',1)[0]
        source=(ROOT/'Tests/Fixtures/ReleaseAssetDownloadHarness.swift').read_text()
        source=source.replace('// PRODUCTION_RELEASE_MODELS',(ROOT/'RepoPocket/ReleaseManagement.swift').read_text(encoding='utf-8'))
        changes=(ROOT/'RepoPocket/ReleasePresence.swift').read_text(encoding='utf-8').split('@MainActor enum ReleaseManagementChanges',1)[1].split('@MainActor final class ReleasePresenceState',1)[0]
        source=source.replace('// PRODUCTION_RELEASE_CHANGES','@MainActor enum ReleaseManagementChanges' + changes)
        source=source.replace('// PRODUCTION_STATE','@MainActor final class ReleaseScreenState:' + state)
        source=source.replace('// PRODUCTION_PROGRESS',(ROOT/'RepoPocket/ReleaseAssetDownload.swift').read_text())
        source += '\n' + (ROOT/'RepoPocket/ReleaseAssetRedirectPolicy.swift').read_text()
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'main.swift';path.write_text(source)
            subprocess.run(['swiftc','-parse-as-library',str(path),'-o',folder+'/test'],check=True)
            subprocess.run([folder+'/test'],check=True,timeout=30)

class DownloadProgressContractTests(unittest.TestCase):
 def read(self,name): return (ROOT/'RepoPocket'/name).read_text()
 def test_progress_ring_and_real_bytes(self):
  ring=self.read('DownloadProgressRing.swift')
  for token in ['trim(from:', 'fraction: Double?', 'accessibilityReduceMotion', '1.6', 'TimelineView(.animation', 'paused: startedAt == nil', 'onDisappear', 'Color(uiColor: .systemBlue)', 'Color(uiColor: .systemGray5)', '.frame(width: 18, height: 18)']:
   self.assertIn(token,ring)
  self.assertNotIn('Timer',ring)
  model=self.read('ReleaseAssetDownload.swift')
  self.assertNotIn('fraction * 100',model.split('var label: String',1)[1].split('struct ReleaseAssetDownload',1)[0])
  self.assertIn('policy: URLSessionTaskDelegate',model)
 def test_only_artifacts_offer_transport_controls(self):
  view=self.read('WorkflowViews.swift').split('struct WorkflowArtifactsView:',1)[1].split('struct WorkflowJobView:',1)[0]
  for token in ['.frame(width: 44, height: 44)', '.contentShape(Rectangle())', 'setPaused(!paused)', 'active: !paused', 'downloadTask?.cancel()', '.swipeActions(edge: .trailing, allowsFullSwipe: false)', 'Button("取消下载")', '.tint(.red)', 'transfer = $0']:
   self.assertIn(token,view)
  self.assertNotIn('role: .destructive',view)
  self.assertNotIn('DELETE',view)
  self.assertNotIn('Text("暂停',view)
  self.assertNotIn('Text("继续',view)
 def test_generic_download_progress_keeps_policy(self):
  source=self.read('GitHub.swift')
  for method in ['communityArtifact','downloadZIP','downloadFile','fetchWorkspace','downloadWorkspace']:
   signature=source.split('func '+method+'(',1)[1].split('{',1)[0]
   self.assertIn('progress: ((ReleaseDownloadProgress) -> Void)? = nil',signature)
  self.assertIn('policy: redirect',source)
  self.assertIn('onCancel:',source)
  self.assertIn('GitHubAPIRedirectPolicy()',source.split('private func downloadBlob(',1)[1].split('func commitWorkspace',1)[0])
 def test_final_save_feedback_not_page_alert(self):
  for name in ['ReleaseManagementUI.swift','WorkflowViews.swift','UpdateFeature.swift']:
   source=self.read(name)
   self.assertNotIn('.downloadCompletionNotice(',source)
   self.assertIn('AppFeedback.show("下载完成"',source)
  source=self.read('WorkflowViews.swift').split('private func download(_ artifact:',1)[1].split('struct WorkflowJobView',1)[0]
  self.assertLess(source.index('DownloadStore.shared.persist'), source.index('AppFeedback.show'))
  self.assertIn('try Task.checkCancellation()',source)
 def test_release_final_feedback_keeps_confirmations_and_partial_failure(self):
  source=self.read('ReleaseManagementUI.swift')
  self.assertNotIn('completedDownload', source)
  self.assertNotIn('@State private var copied', source)
  self.assertNotIn('.alert("下载链接已复制"', source)
  for token in ['"发行版已删除" : "附件已删除"', '"发行版已发布" : "发行版已保存"', 'plan.fail()', 'plan.cancel()', 'guard verifiedAll, attachments.allSatisfy', '.confirmationDialog(deleteTitle']:
   self.assertIn(token, source)
  operation=source.split('private func performConfirmedRelease()',1)[1].split('@SoftGroupRowsBuilder',1)[0]
  self.assertLess(operation.index('try await publishAttachments(captured)'), operation.index('AppFeedback.show'))
  api=self.read('GitHub.swift')
  for token in ['statusCode == (method == "POST" ? 201 : 200)', 'saved.draft == form.draft', 'statusCode == 201', 'asset.name == file.lastPathComponent']:
   self.assertIn(token,api)
 def test_update_unknown_and_stages(self):
  source=self.read('UpdateFeature.swift')
  self.assertIn('var progress: ReleaseDownloadProgress?',source)
  self.assertIn('正在校验 IPA',source)
  self.assertIn('正在保存',source)
  self.assertNotIn('ProgressView(value: checker.progress)',source)
  self.assertNotIn('self.message = "下载完成，请选择应用安装"',source)

if __name__ == '__main__': unittest.main()
