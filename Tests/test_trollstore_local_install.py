"""No downloaded-file installation; manual file actions and online updates stay separate."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

def source(name):
    return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8-sig')


class LocalTrollStoreRemovalTests(unittest.TestCase):
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
        for name in ['project.yml', 'RepoPocket/OpenSourceLicenses.txt']:
            text = (ROOT / name).read_text(encoding='utf-8')
            for token in ['TrollStoreAvailability.swift', 'TrollStoreInbox.swift',
                          'Local TrollStore document handoff', 'TrollStoreDocumentHandoff']:
                self.assertNotIn(token, text)
        # Fila attribution is still required by the independent text-editing adaptation.
        self.assertIn('OwnGoal Studio', source('OpenSourceLicenses.txt'))
        self.assertIn('--- Source text: Fila-MIT.txt ---', source('OpenSourceLicenses.txt'))


if __name__ == '__main__':
    unittest.main()
