"""Network-free tests: production Swift rules, no real pasteboard access."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import shutil
import subprocess
import tempfile
import unittest

ROOT = REPO_ROOT

class CopyLinkTests(unittest.TestCase):
    def test_shared_list_and_detail_callsites(self):
        ui = (ROOT/'RepoPocket/RepositoryUI.swift').read_text()
        app = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
        sections = (ROOT/'RepoPocket/RepositorySections.swift').read_text()
        search = (ROOT/'RepoPocket/RepositorySearchView.swift').read_text()
        self.assertEqual(sections.count('RepositoryCard(repository: repository,'), 2)
        self.assertEqual(search.count('RepositoryCard(repository: repository,'), 2)
        self.assertNotIn('.contextMenu', sections + search)
        self.assertIn('.contextMenu {', ui)
        self.assertIn('if copyLinkContextMenu', ui)
        self.assertIn('CopyRepositoryLinkButton(repository: repository.full_name, feedback: copyFeedback)', ui)
        self.assertIn('copyLinkContextMenu: false', app)
        browser = app.split('struct BrowserView:', 1)[1].split('struct FileView:', 1)[0]
        self.assertIn('CopyRepositoryLinkButton(repository: repo, feedback: copyFeedback)', browser)
        self.assertNotIn('CopyRepositoryLinkButton(repository: path', browser)
        self.assertIn('.repositoryCopyNotice(copyFeedback)', browser)
        self.assertEqual(sections.count('.swipeActions(edge: .trailing, allowsFullSwipe: false)'), 2)
        self.assertIn('NavigationLink', sections)
        self.assertNotIn('.onLongPressGesture', ui)

    def test_local_notice_and_user_authorized_write_only(self):
        ui = (ROOT/'RepoPocket/RepositoryCopyUI.swift').read_text()
        self.assertEqual(ui.count('UIPasteboard.general.string ='), 1)
        self.assertIn('Button { feedback.copy(repository) }', ui)
        self.assertIn('guard let url = RepositoryLinkRules.canonicalURL(input)', ui)
        for text in ['timeout?.cancel()', '1_500_000_000', 'guard !Task.isCancelled',
                     'notice.expire(token)', '.onDisappear { feedback.cancel() }',
                     '.allowsHitTesting(false)', 'Text("已复制")']:
            self.assertIn(text, ui)
        for forbidden in ['api.message', 'canWrite', 'permissions', 'URLSession', 'GitHub()']:
            self.assertNotIn(forbidden, ui)

    def test_fork_menu_guards_and_coverage(self):
        source = (ROOT/'RepoPocket/RepositoryForkMenu.swift').read_text()
        for text in ['fixed.fullName', 'fixed.generation == AccountStore.generation',
                     'fixed.accountID == api.accountID', 'guard !busy', 'api.isCurrentSession',
                     'RepositoryInput.parse(input)', 'RepositoryGroupRules.isOwned',
                     'confirmationDialog', 'Text(fixed.fullName)', 'role: .cancel']:
            self.assertIn(text, source)
        self.assertNotIn('permissions', source)
        self.assertNotIn('requireWriteAccess', source)
        for file, argument in [('RepositoryUI.swift', 'repository.full_name'), ('RepoPocketApp.swift', 'repo')]:
            self.assertIn('ForkRepositoryMenuButton(repository: ' + argument,
                          (ROOT/'RepoPocket'/file).read_text())
        api = (ROOT/'RepoPocket/GitHub.swift').read_text()
        request = api.split('private func request(', 1)[1].split('private func', 1)[0]
        self.assertIn('try ensureActiveAccount()', request)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production fork state mocks run on macOS CI')
    def test_production_fork_state_with_network_free_mock(self):
        state = (ROOT/'RepoPocket/RepositoryForkMenu.swift').read_text().split('struct ForkRepositoryMenuButton:', 1)[0]
        state = state.replace('import SwiftUI', 'import Foundation')
        source = r'''
import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
enum AccountStore { static var generation = UUID() }
enum CredentialStore { static func read(account: String) -> String { "mock" } }
enum RefreshFailure { static func isCancellation(_ error: Error) -> Bool { false } }
struct Repository { let full_name: String }
@MainActor final class GitHub {
    var accountID = "A"
    var login = "me"
    var isCurrentSession = true
    var message = ""
    var calls: [String] = []
    func fork(_ name: String) async throws -> Repository {
        calls.append(name)
        await Task.yield()
        return Repository(full_name: "me/repo")
    }
}
'''
        source += (ROOT/'RepoPocket/RepositoryInput.swift').read_text()
        source += (ROOT/'RepoPocket/RepositorySafetyRules.swift').read_text().split('enum UpdateNoticeRules')[0]
        source += state + r'''
@main struct Harness {
    @MainActor static func main() async {
        let api = GitHub()
        let state = RepositoryForkMenuState()
        state.prepare("ME/repo", api: api)
        precondition(state.target == nil && api.calls.isEmpty)
        state.prepare("https://github.com/other/repo.git/", api: api)
        let fixed = state.target!
        precondition(fixed.fullName == "other/repo" && api.calls.isEmpty)
        state.target = nil // cancel: no request
        precondition(api.calls.isEmpty)
        AccountStore.generation = UUID()
        await state.confirm(fixed, api: api)
        precondition(api.calls.isEmpty)
        state.prepare("other/repo", api: api)
        let current = state.target!
        async let first: Void = state.confirm(current, api: api)
        async let duplicate: Void = state.confirm(current, api: api)
        _ = await (first, duplicate)
        precondition(api.calls == ["other/repo"] && !state.busy)
        api.isCurrentSession = false
        await state.confirm(current, api: api)
        precondition(api.calls.count == 1)
        api.isCurrentSession = true
        api.login = ""
        state.target = nil
        state.prepare("other/repo", api: api)
        precondition(state.target == nil)
        print("PASS production fixed fork target, cancellation, self/no-login, account-generation and duplicate guards; mock only")
    }
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'Harness.swift'
            path.write_text(source)
            subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', folder+'/test'], check=True)
            subprocess.run([folder+'/test'], check=True)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production Swift rules run on macOS CI')
    def test_production_canonical_and_notice_generation(self):
        source = (ROOT/'RepoPocket/RepositoryInput.swift').read_text()
        source += (ROOT/'RepoPocket/RepositoryLinkRules.swift').read_text()
        source += r'''
let valid = [(" owner/repo ", "https://github.com/owner/repo"),
             ("https://GITHUB.COM/Owner/Repo.git/", "https://github.com/Owner/Repo"),
             ("owner/repo_1-2.3", "https://github.com/owner/repo_1-2.3")]
for (input, expected) in valid {
    precondition(RepositoryLinkRules.canonicalURL(input)?.absoluteString == expected)
}
for bad in ["", "owner/..", "owner/.git", "owner/repo/tree/main", "owner/repo/blob/main/file", "owner/repo%2Ftree", "owner/repo?x", "owner/repo#x", "https://evil.test/a/b", "https://github.com.evil.test/a/b", "https://github.com@evil.test/a/b", "https://user@github.com/a/b", "https://github.com:443/a/b", "http://github.com/a/b", "https://github.com/a/b?", "https://github.com/a/b#", "owner/repo\\name", "owner/re\npo"] {
    precondition(RepositoryLinkRules.canonicalURL(bad) == nil)
}
var notice = RepositoryCopyNoticeState()
let first = notice.show()
let second = notice.show()
notice.expire(first)
precondition(notice.visible)
notice.expire(second)
precondition(!notice.visible)
let third = notice.show()
notice.cancel()
let fourth = notice.show()
notice.expire(third)
precondition(notice.visible)
notice.expire(fourth)
precondition(!notice.visible)
print("PASS production canonical root URL and repeated-copy/disappear lifecycle; zero HTTP/pasteboard writes")
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'main.swift'
            path.write_text(source)
            subprocess.run(['swiftc', str(path), '-o', folder+'/test'], check=True)
            subprocess.run([folder+'/test'], check=True)

if __name__ == '__main__': unittest.main()
