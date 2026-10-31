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
        self.assertEqual(sections.count('RepositoryCard(repository: repository,'), 1)
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
        self.assertEqual(sections.count('.swipeActions(edge: .trailing, allowsFullSwipe: false)'), 1)
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

    def test_file_and_directory_links_copy_from_list_and_detail(self):
        rules = (ROOT/'RepoPocket/RepositoryLinkRules.swift').read_text()
        for name in ['fileURL', 'rawURL', 'directoryURL']:
            self.assertIn('static func ' + name + '(', rules)
        app = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
        browser = app.split('struct BrowserView:', 1)[1].split('struct FileView:', 1)[0]
        detail = app.split('struct FileView:', 1)[1]
        for text in ['Button("复制目录链接") { copyFeedback.copy(link: link) }',
                     'Button("复制文件链接") { copyFeedback.copy(link: link) }',
                     'Button("复制 raw 链接") { copyFeedback.copy(link: raw) }']:
            self.assertIn(text, browser)
        for text in ['Button("复制文件链接") { copyFeedback.copy(link: link) }',
                     'Button("复制 raw 链接") { copyFeedback.copy(link: raw) }',
                     '.repositoryCopyNotice(copyFeedback)']:
            self.assertIn(text, detail)
        ui = (ROOT/'RepoPocket/RepositoryCopyUI.swift').read_text()
        self.assertIn('func copy(link: URL)', ui)
        self.assertEqual(ui.count('UIPasteboard.general.string ='), 1)

    def test_fork_menu_guards_and_coverage(self):
        source = (ROOT/'RepoPocket/RepositoryForkMenu.swift').read_text()
        for text in ['fixed.fullName', 'fixed.generation == AccountStore.generation',
                     'fixed.accountID == api.accountID', 'guard !busy', 'api.isCurrentSession',
                     'RepositoryInput.parse(input)', 'RepositoryGroupRules.isOwned',
                     'confirmationDialog', 'Text(fixed.fullName +', 'role: .cancel']:
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
struct Repository { let full_name: String; var fork: Bool?; var parent: RepositoryReference?; var source: RepositoryReference? }
struct RepositoryReference { let full_name: String }
@MainActor final class GitHub {
    var accountID = "A"
    var login = "me"
    var isCurrentSession = true
    var message = ""
    var calls: [String] = []
    var forkNames: [String: String] = [:]
    var failCheck = false
    var switchDuringCheck = false
    var suspendCheck = false
    var pendingCheck: CheckedContinuation<Void, Never>?
    var checks = 0
    func existingFork(_ name: String, forceRefresh: Bool = false) async throws -> String? {
        checks += 1
        if suspendCheck {
            await withCheckedContinuation { pendingCheck = $0 }
        } else {
            await Task.yield()
        }
        if switchDuringCheck { AccountStore.generation = UUID() }
        if failCheck { throw CancellationError() }
        return forkNames[name.lowercased()]
    }
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
        api.failCheck = true
        await state.check("other/repo", api: api)
        precondition(state.failed.contains("other/repo") && !state.checked.contains("other/repo"))
        state.prepare("other/repo", api: api)
        precondition(state.target == nil && api.calls.isEmpty)
        let unverified = RepositoryForkTarget(fullName: "other/repo", accountID: api.accountID, generation: AccountStore.generation)
        await state.confirm(unverified, api: api)
        precondition(api.calls.isEmpty)
        api.failCheck = false
        await state.check("other/repo", api: api)
        precondition(state.checked.contains("other/repo") && !state.failed.contains("other/repo"))
        api.switchDuringCheck = true
        await state.check("other/stale", api: api)
        precondition(!state.checked.contains("other/stale") && !state.checking.contains("other/stale"))
        api.switchDuringCheck = false
        api.forkNames["other/existing"] = "me/renamed"
        state.prepare("other/existing", api: api)
        precondition(state.target == nil)
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
        state.target = nil // the confirmation dialog dismisses before its task runs
        api.suspendCheck = true
        let first = Task { await state.confirm(current, api: api) }
        for _ in 0..<1_000 {
            if api.pendingCheck != nil { break }
            await Task.yield()
        }
        precondition(api.pendingCheck != nil && state.busy && api.calls.isEmpty)
        // Keep the first request suspended while the second confirmation arrives.
        // Task.yield alone does not guarantee that two async-let calls overlap.
        api.suspendCheck = false
        await state.confirm(current, api: api)
        precondition(api.calls.isEmpty && state.busy)
        api.pendingCheck?.resume()
        api.pendingCheck = nil
        await first.value
        precondition(api.calls == ["other/repo"] && !state.busy)
        // The dialog may outlive a successful lookup; a failed revalidation cannot write.
        api.failCheck = true
        await state.confirm(current, api: api)
        precondition(api.calls.count == 1 && state.failed.contains("other/repo"))
        state.prepare("other/repo", api: api)
        precondition(state.target == nil)
        api.failCheck = false
        await state.check("other/repo", api: api)
        api.forkNames["other/repo"] = "me/renamed"
        await state.confirm(current, api: api)
        precondition(api.calls.count == 1)
        api.forkNames["other/repo"] = nil
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
precondition(RepositoryLinkRules.fileURL("o/r", branch: "main", path: "rule/Surge/Telegram/Telegram.list")?.absoluteString == "https://github.com/o/r/blob/main/rule/Surge/Telegram/Telegram.list")
precondition(RepositoryLinkRules.rawURL("o/r", branch: "main", path: "rule/Surge/Telegram/Telegram.list")?.absoluteString == "https://raw.githubusercontent.com/o/r/main/rule/Surge/Telegram/Telegram.list")
precondition(RepositoryLinkRules.directoryURL("o/r", branch: "main", path: "rule/Surge/Telegram")?.absoluteString == "https://github.com/o/r/tree/main/rule/Surge/Telegram")
precondition(RepositoryLinkRules.fileURL("o/r", branch: "main", path: "文 档/a.md")?.absoluteString == "https://github.com/o/r/blob/main/%E6%96%87%20%E6%A1%A3/a.md")
precondition(RepositoryLinkRules.fileURL("o/r", branch: "", path: "a.md") == nil)
precondition(RepositoryLinkRules.directoryURL("o/r", branch: "main", path: "") == nil)
precondition(RepositoryLinkRules.rawURL("o/..", branch: "main", path: "a.md") == nil)
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
