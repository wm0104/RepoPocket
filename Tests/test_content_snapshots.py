"""Persistent read snapshots must never become write authorization."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    path = ROOT / 'RepoPocket' / name
    return path.read_text(encoding='utf-8') if path.exists() else ''


class ContentSnapshotTests(unittest.TestCase):
    def test_invalid_repository_cache_keys_fail_closed_without_throwing_into_the_ui(self):
        text = source('ContentSnapshotCache.swift')
        self.assertIn('try? cachedContent(Repository.self', text)
        self.assertIn('try? cachedContent([Entry].self', text)
        self.assertIn('try? cachedContent(WorkflowRuns.self', text)
    @unittest.skipUnless(shutil.which('swiftc'), 'Persistent snapshot behavior requires the native Swift compiler')
    def test_production_storage_survives_restart_and_account_removal(self):
        core = source('ContentSnapshotCache.swift').split('extension GitHub {', 1)[0]
        fixture = r'''
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let cache = ContentSnapshotCache(root: root)
let key = ContentSnapshotCache.key("/repos/o/r/contents", query: [.init(name: "ref", value: "feature/a & b")])
cache.save(Data("private-A".utf8), accountID: "A", key: key)
precondition(cache.load(accountID: "A", key: key)?.body == Data("private-A".utf8))
precondition(cache.load(accountID: "B", key: key) == nil)
cache.save(Data("private-B".utf8), accountID: "B", key: key)
precondition(cache.load(accountID: "B", key: key)?.body == Data("private-B".utf8))
let restarted = ContentSnapshotCache(root: root)
precondition(restarted.load(accountID: "A", key: key)?.body == Data("private-A".utf8))
cache.removeAccount("A")
precondition(cache.load(accountID: "A", key: key) == nil)
precondition(cache.load(accountID: "B", key: key)?.body == Data("private-B".utf8))
precondition(ContentSnapshotCache(root: root).load(accountID: "A", key: key) == nil)
cache.save(Data(repeating: 1, count: 8 * 1024 * 1024 + 1), accountID: "B", key: "large")
precondition(cache.load(accountID: "B", key: "large") == nil)
for i in 0..<130 { cache.save(Data("small".utf8), accountID: "B", key: "item-\(i)") }
_ = cache.load(accountID: "B", key: "item-129")
let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
for folder in folders {
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    precondition(files.count <= 128)
}
print("PASS persistent/account-scoped/removed/bounded production snapshots")
'''
        with tempfile.TemporaryDirectory(prefix='repopocket-snapshots-') as directory:
            folder = Path(directory)
            swift = folder / 'main.swift'
            executable = folder / 'fixture'
            swift.write_text(core + '\n' + fixture, encoding='utf-8')
            subprocess.run(['swiftc', str(swift), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=30)

    def test_storage_is_account_scoped_bounded_and_private(self):
        text = source('ContentSnapshotCache.swift')
        for token in ['SHA256.hash', 'accountID', 'savedAt', '.atomic',
                      'completeUntilFirstUserAuthentication', 'maximumAccountBytes',
                      'maximumRecordBytes', 'removeAccount', 'record.key == key']:
            self.assertTrue(token in text, token)

    def test_account_removal_clears_the_corresponding_snapshots(self):
        self.assertIn('ContentSnapshotCache.shared.removeAccount(id)', source('GitHubAccounts.swift'))

    def test_cached_directory_is_shown_without_authorizing_writes(self):
        text = source('RepoPocketApp.swift')
        self.assertIn('cachedContents(repo, path: path, branch:', text)
        self.assertIn('metadataFresh && RepositoryWriteRules.canWrite', text)
        self.assertIn('loadID == token', text)
        self.assertNotIn('repositoryInfo = nil\n        busy = true', text)

    def test_collections_revalidate_even_when_initial_data_exists(self):
        text = source('RepositorySections.swift')
        self.assertNotIn('if !loaded && !CredentialStore.read().isEmpty { await load() }', text)
        self.assertIn('ContentFreshnessText', text)

    def test_readme_snapshot_is_scoped_to_repository_and_ref(self):
        text = source('ReadmeDocument.swift')
        self.assertIn('cachedReadmeDocument', text)
        self.assertIn('"readme:" + repo.lowercased() + "\\n" + branch', text)
        self.assertIn('ContentSnapshotCache.shared.save', text)

    def test_return_revalidates_embedded_content_without_recycling_requests(self):
        state = source('RepositoryPageState.swift')
        self.assertIn('self.revalidationID == revalidationID', state)
        browser = source('RepoPocketApp.swift').split('struct BrowserView:', 1)[1].split('struct FileView:', 1)[0]
        self.assertIn('.onAppear { revalidationID = UUID() }', browser)
        self.assertEqual(browser.count('revalidationID: revalidationID'), 2)
        for name in ['RepositoryReadmeSection.swift', 'RepositoryHomeHighlights.swift']:
            text = source(name)
            self.assertIn('revalidationID: revalidationID', text)
            self.assertIn('revalidationID?.uuidString', text)


if __name__ == '__main__':
    unittest.main()
