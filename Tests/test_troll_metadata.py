"""Removal contract: no app-specific plugin/index mutation; common files remain usable."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'RepoPocket'

class TrollRemovalTests(unittest.TestCase):
    def test_dedicated_pages_and_services_are_removed(self):
        self.assertFalse((APP / 'TrollMetadata.swift').exists())
        self.assertFalse((APP / 'TrollMetadataView.swift').exists())
        for path in APP.glob('*.swift'):
            text = path.read_text()
            for token in ('TrollFools', 'TrollMetadata', 'TrollPublishResult', 'func trollPublish', 'func metadataSnapshot', 'func saveMetadata', 'func trollSize', 'maximumTrollPluginBytes'):
                self.assertNotIn(token, text, str(path))

    def test_trollstore_update_installation_is_not_removed(self):
        self.assertIn('enum TrollStoreInstaller', (APP / 'TrollStoreInstaller.swift').read_text())
        self.assertIn('enum TrollStoreInstallRules', (APP / 'TrollStoreInstallRules.swift').read_text())
        self.assertIn('TrollStoreInstaller', (APP / 'UpdateFeature.swift').read_text())
        self.assertIn('canCheckOfficialUpdate', (APP / 'GitHub.swift').read_text())

    def test_common_download_and_nonforce_write_guards_remain(self):
        api = (APP / 'GitHub.swift').read_text()
        self.assertIn('func saveRemoteDeb(', api)
        self.assertIn('func downloadFile(', api)
        self.assertIn('func commitQueue(', api)
        self.assertIn('"force": false', api)
        self.assertIn('RepoQueue.validate', api)
        self.assertNotIn('trollpackages.json', api)
        # No repository/remote file cleanup is introduced by removing a module.
        app = (APP / 'RepoPocketApp.swift').read_text()
        self.assertNotIn('trollpackages.json', app)
        self.assertNotIn('hasSuffix(".dylib")', app)

if __name__ == '__main__': unittest.main()
