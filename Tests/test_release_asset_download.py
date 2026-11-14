from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]

class ReleaseAssetDownloadTests(unittest.TestCase):
    def test_compact_actions_inline_progress_and_request_identity(self):
        ui=(ROOT/'RepoPocket/ReleaseManagementUI.swift').read_text()
        row=ui.split('ForEach(state.assets) { asset in',1)[1].split('if state.assets.isEmpty',1)[0]
        self.assertEqual(row.count('.softGroupedRow('),1)
        for token in ['LocalGitFileLabel(', 'Menu {', 'assetActions(asset)', 'if state.canWrite', 'ReleaseAssetDownloadStatusView(']: self.assertIn(token,row)
        self.assertIn('self.assetDownload?.request == initial.request',ui)
        self.assertIn('self.assetDownload?.stage == .connecting || self.assetDownload?.stage == .downloading',ui)
        self.assertIn('presenting: assetAction',ui)
        self.assertIn('target.generation == AccountStore.generation',ui)
        delegate=(ROOT/'RepoPocket/ReleaseAssetDownload.swift').read_text()
        self.assertIn('ReleaseAssetRedirectPolicy()',delegate)
        self.assertNotIn('Timer',delegate)

    @unittest.skipUnless(shutil.which('swiftc'),'Production Swift regression runs on macOS')
    def test_production_controller_and_real_progress_delegate(self):
        ui=(ROOT/'RepoPocket/ReleaseManagementUI.swift').read_text()
        state=ui.split('@MainActor final class ReleaseScreenState:',1)[1].split('struct ReleaseListView:',1)[0]
        source=(ROOT/'Tests/Fixtures/ReleaseAssetDownloadHarness.swift').read_text()
        source=source.replace('// PRODUCTION_STATE','@MainActor final class ReleaseScreenState:' + state)
        source=source.replace('// PRODUCTION_PROGRESS',(ROOT/'RepoPocket/ReleaseAssetDownload.swift').read_text())
        source += '\n' + (ROOT/'RepoPocket/ReleaseAssetRedirectPolicy.swift').read_text()
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'main.swift';path.write_text(source)
            subprocess.run(['swiftc','-parse-as-library',str(path),'-o',folder+'/test'],check=True)
            subprocess.run([folder+'/test'],check=True,timeout=30)

if __name__ == '__main__': unittest.main()
