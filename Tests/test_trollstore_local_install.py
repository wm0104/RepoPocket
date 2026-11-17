"""No downloaded-file installation; manual file actions and online updates stay separate."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

def source(name):
    return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8-sig')


class LocalTrollStoreRemovalTests(unittest.TestCase):
    def test_download_center_has_no_install_entry_state_or_fallback(self):
        view = source('DownloadCenterView.swift')
        for token in ['TrollStore', 'installing', 'canShareFallback', 'apple-magnifier',
                      'UIApplication.shared.open', 'pathExtension.lowercased()']:
            self.assertNotIn(token, view)
        self.assertEqual(view.count('.confirmationDialog('), 1)
        self.assertIn('"删除下载文件？" : "删除下载记录？"', view)

    def test_manual_share_is_explicit_and_keeps_preview_upload_delete(self):
        view = source('DownloadCenterView.swift')
        self.assertEqual(view.count('shared = SharedFile('), 1)
        menu = view.split('.contextMenu {', 1)[1].split('private func perform(', 1)[0]
        self.assertEqual(menu.count('Button'), 3)
        self.assertIn('Button { do { shared = SharedFile(url: try store.file(record))', view)
        for token in ['Label("分享"', 'Label("加入待上传文件"', 'ShareSheet(url: $0.url)',
                      'preview = SharedFile(url: try store.file(record))',
                      'ShareInboxStore.live().importFile', 'store.delete(record)']:
            self.assertIn(token, view)
        action = view.split('private func perform(', 1)[1].split('private struct DownloadFilePreview:', 1)[0]
        self.assertNotIn('shared =', action)
        self.assertIn('!RefreshFailure.isCancellation(error)', action)
        self.assertIn('generation == AccountStore.generation', action)
        self.assertIn('action?.cancel()', view)
        self.assertIn('shared = nil; preview = nil; deleting = nil; message = ""', view)

    def test_local_handoff_modules_and_private_api_are_removed(self):
        for name in ['TrollStoreAvailability.swift', 'TrollStoreInbox.swift']:
            self.assertFalse((ROOT / 'RepoPocket' / name).exists(), name)
        for path in (ROOT / 'RepoPocket').glob('*.swift'):
            text = path.read_text(encoding='utf-8-sig')
            for token in ['TrollStoreDocumentHandoff', 'TrollStoreDocumentOpening',
                          'TrollStoreInstallError', 'TrollStoreApplicationDiscovery',
                          'TrollStoreInbox', 'operationToOpenResource:usingApplication:']:
                self.assertNotIn(token, text, str(path))

    def test_only_official_remote_update_bridge_remains(self):
        bridge = source('TrollStoreInstaller.swift')
        for token in ['@MainActor enum TrollStoreInstaller', 'static func open(ipaURL: URL',
                      'TrollStoreInstallRules.installURL(for: ipaURL)',
                      'UIApplication.shared.canOpenURL(url)', 'UIApplication.shared.open(url']:
            self.assertIn(token, bridge)
        for token in ['static func install(', 'installing', 'LSApplicationWorkspace',
                      'NSClassFromString', 'unsafeBitCast', 'FileManager', 'Task.detached']:
            self.assertNotIn(token, bridge)
        self.assertIn('TrollStoreInstaller.open(ipaURL: ipa)', source('UpdateFeature.swift'))
        self.assertIn('enum TrollStoreInstallRules', source('TrollStoreInstallRules.swift'))

    def test_no_dead_project_manifest_or_notice_references(self):
        for name in ['project.yml', 'THIRD_PARTY_NOTICES.md']:
            text = (ROOT / name).read_text(encoding='utf-8')
            for token in ['TrollStoreAvailability.swift', 'TrollStoreInbox.swift',
                          'Local TrollStore document handoff', 'TrollStoreDocumentHandoff']:
                self.assertNotIn(token, text)
        # Fila attribution is still required by the independent text-editing adaptation.
        self.assertIn('## Text editing and search', (ROOT / 'THIRD_PARTY_NOTICES.md').read_text())
        self.assertTrue((ROOT / 'Licenses/SourceText/Fila-MIT.txt').exists())

    def test_ui_covers_no_install_menu_and_preserves_manual_share_cancel_relaunch(self):
        self.assertIn('["插件.deb", "应用.ipa", "应用.tipa"].enumerated()', source('DownloadCenterStylePreview.swift'))
        ui = (ROOT / 'StyleUITests/DownloadCenterTests.swift').read_text(encoding='utf-8')
        flow = ui.split('func testCompletedPackagesOnlyOfferFileActionsAndKeepOriginalOnCancel()', 1)[1].split('private func openFileMenu(', 1)[0]
        for token in ['["插件.deb", "应用.ipa", "应用.tipa"]', 'XCTAssertFalse(app.buttons["用 TrollStore 安装"].exists)',
                      'XCTAssertTrue(app.buttons["分享"].exists)',
                      'XCTAssertTrue(app.buttons["加入待上传文件"].exists)',
                      'XCTAssertTrue(app.buttons["删除文件"].exists)',
                      'download-preview-done', 'done.tap()', 'cancelShare.tap()',
                      'app.buttons["取消"].tap()', 'app.terminate()', '-download-keep-history',
                      'XCTAssertEqual(records.count, count)', 'XCTAssertEqual(persisted.identifier, original)',
                      'download-center-completed-file-actions']:
            self.assertIn(token, flow)
        self.assertNotIn('testTrollStoreActionRequiresConfirmation', ui)
        exporter = (ROOT / 'Scripts/export_style_attachments.py').read_text(encoding='utf-8')
        self.assertNotIn('download-center-trollstore-', exporter)
        self.assertEqual(exporter.count("'download-center-completed-file-actions'"), 2,
                         'Keep file-action evidence in download and full recovery scopes')


if __name__ == '__main__':
    unittest.main()
