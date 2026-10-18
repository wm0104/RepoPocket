from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import subprocess, tempfile, shutil, unittest
root = Path(REPO_ROOT, 'RepoPocket')

class Regressions(unittest.TestCase):
    def test_static_contracts(self):
        home = (root/'RepoPocketApp.swift').read_text()
        section = (root/'RepositorySections.swift').read_text()
        api = (root/'GitHub.swift').read_text()
        search = (root/'RepositorySearchView.swift').read_text()
        upload = (root/'UploadView.swift').read_text()
        self.assertEqual(home.count('RepositoryInlineSection(api:'), 2)
        self.assertNotIn('查看已加星标仓库', home.split('struct BrowserView')[0])
        self.assertIn('RepositoryCollectionView(api: api, section: section', home)
        self.assertNotIn('RepositoryCollectionView', home.split('struct SettingsView:', 1)[1])
        self.assertIn('ForEach(repositories)', section)
        self.assertIn('.swipeActions(edge: .trailing, allowsFullSwipe: false)', section)
        self.assertNotIn('Color.clear.frame(height: 8)', section)
        self.assertIn('softGroupedRow(top: true, bottom: !expanded, animateBackground: false)', section)
        self.assertIn('softGroupedRow(bottom: true, animateBackground: false)', section)
        self.assertNotIn('withAnimation', section)
        self.assertIn('if canWrite { Button("上传")', home)
        self.assertIn('if canWrite { Button("删除"', home)
        self.assertIn('sessionMatches: api.isCurrentSession', home)
        self.assertIn('path.hasPrefix("/repos/")', api)
        self.assertIn('!path.hasSuffix("/forks")', api)
        self.assertIn('try await requireWriteAccess(owner + "/" + name)', api)
        self.assertIn('info.permissions?.push', api)
        self.assertIn('try ensureActiveAccount()', api.split('func requireWriteAccess')[1].split('private func ensureActiveAccount')[0])
        self.assertIn('.task(id: repo) { await loadWriteAccess() }', upload)
        self.assertIn('.searchable(text: $query', search)
        self.assertIn('store.record(submitted, kind: selected)', search)
        self.assertNotIn('.animation(', search)
        self.assertIn('requestTask?.cancel()', search)
        self.assertIn('RepositorySearchRules.accepts', search)
        self.assertIn('store.clear()', search)
        self.assertIn('store.remove(item)', search)
        self.assertNotIn('error.localizedDescription', search)
    @unittest.skipUnless(shutil.which('swiftc'), 'production Swift runs on macOS CI')
    def test_production_rules(self):
        api=(root/'GitHub.swift').read_text()
        models=api[api.index('struct User: Decodable'):api.index('struct Entry: Decodable')]
        source='import Foundation\n'+models+(root/'RepositorySafetyRules.swift').read_text()+(root/'RepositorySearchRules.swift').read_text()+r'''
func check(_ value: Bool) { precondition(value) }
for push in [Optional<Bool>.none, Optional(false)] { check(!RepositoryWriteRules.canWrite(push: push)) }
check(RepositoryWriteRules.canWrite(push: true))
check(!RepositoryWriteRules.canWrite(push: true, sessionMatches: false))
check(RepositoryGroupRules.isOwned("WM0104/repo", login: "wm0104"))
check(!RepositoryGroupRules.isOwned("collaborator/repo", login: "wm0104"))
check(!RepositoryGroupRules.isOwned("wm0104/repo", login: ""))
check(UpdateNoticeRules.latestNanoseconds == 2_000_000_000)
check(UpdateNoticeRules.failureNanoseconds == 6_000_000_000)
let raw = " wm0104 & type:repo 中文+?/# "
let url = RepositorySearchRules.endpoint(kind: .repositories, query: raw, page: 2)
let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
check(parts.queryItems!.first!.value == raw.trimmingCharacters(in: .whitespacesAndNewlines))
check(parts.queryItems!.last!.value == "2")
check(url.host == "api.github.com" && url.path == "/search/repositories")
check(RepositorySearchRules.endpoint(kind: .users, query: "wm0", page: 1).path == "/search/users")
let defaults = UserDefaults(suiteName: "RepoPocketMock-" + UUID().uuidString)!
let one = RepositorySearchHistory(accountID: "one", defaults: defaults)
let two = RepositorySearchHistory(accountID: "two", defaults: defaults)
one.record("  wm0104  ", kind: .repositories)
one.record("WM0104", kind: .repositories)
check(one.read().count == 1 && one.read()[0].query == "WM0104")
one.record("", kind: .repositories); check(one.read().count == 1)
check(two.read().isEmpty)
for i in 0..<20 { one.record("query\(i)", kind: .users) }
check(one.read().count == 15 && one.read()[0].query == "query19")
one.remove(one.read()[0]); check(one.read().count == 14)
two.record("separate", kind: .repositories)
one.clear(); check(one.read().isEmpty && two.read().count == 1)
two.clear()
let current = UUID(), account = UUID()
check(RepositorySearchRules.accepts(current, current: current, account: account, currentAccount: account))
check(!RepositorySearchRules.accepts(UUID(), current: current, account: account, currentAccount: account))
check(!RepositorySearchRules.accepts(current, current: current, account: account, currentAccount: UUID()))
print("PASS production fail-closed push/session rules, owned grouping, exact notice deadlines, search query encoding, history persistence/dedup/limit/isolation/remove/clear, stale results")
'''
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'main.swift'; path.write_text(source)
            subprocess.run(['swiftc',str(path),'-o',folder+'/tests'],check=True)
            subprocess.run([folder+'/tests'],check=True)

if __name__=='__main__': unittest.main()
