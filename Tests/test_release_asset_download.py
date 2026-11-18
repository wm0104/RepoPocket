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
        for token in ['addTeardownBlock', 'failureCount', 'release-download-failure', 'app.debugDescription', 'hierarchy.lifetime = .keepAlways', "label CONTAINS '40%'", "label == '下载已取消'", 'completion.waitForExistence(timeout: 15)']:
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

if __name__ == '__main__': unittest.main()
