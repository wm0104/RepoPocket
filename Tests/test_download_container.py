"""Container boundary/recovery contracts; native cases extend DownloadCenterHarness."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
def source(name):
    return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8-sig')

class DownloadContainerContracts(unittest.TestCase):
    def test_only_trusted_container_is_canonicalized(self):
        rules, store = source('DownloadRules.swift'), source('DownloadStore.swift')
        self.assertIn('static func canonicalContainer(', rules)
        self.assertEqual(rules.count('.resolvingSymlinksInPath()'), 1)
        self.assertNotIn('resolvingSymlinksInPath', source('DownloadCenterModels.swift'))
        self.assertIn('DownloadRules.canonicalContainer(container)', store)
        self.assertIn('NSHomeDirectory()', store)
        self.assertIn('self.root = root ??', store)
        self.assertNotIn('resolvingSymlinksInPath', store)
        self.assertIn('拒绝节点：', rules)
        self.assertIn('"rejectedPath": current', rules)

    def test_failed_load_is_retried_before_network_without_clearing_records(self):
        store = source('DownloadStore.swift')
        load = store.split('private func load()', 1)[1].split('private func saveHistory()', 1)[0]
        self.assertNotIn('catch { records = []', load)
        self.assertIn('func retryHistory() throws', store)
        run = store.split('private func run(', 1)[1].split('private func update(', 1)[0]
        self.assertLess(run.index('try retryHistory()'), run.index('api.downloadForCenter'))
        self.assertIn('if !historyLoaded', run)

if __name__ == '__main__':
    unittest.main()
