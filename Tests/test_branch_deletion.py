"""Branch deletion: production libgit2 operations and isolated GitHub requests; no live writes."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

import test_local_branches as local
from test_workflow_dispatch import production_method

ROOT = Path(__file__).resolve().parents[1]


def desktop_rules_fixture(source):
    # The branch rule contains a literal "@{"; a brace counter would consume the enum's closing brace.
    return 'enum DesktopRules {' + source.split('enum DesktopRules {', 1)[1].split('\nenum CommitDatePresentation', 1)[0].rstrip()


class BranchDeletionContracts(unittest.TestCase):
    def test_branch_rule_fixture_does_not_emit_an_extra_enum_closing_brace(self):
        source = desktop_rules_fixture((ROOT / 'RepoPocket/DesktopModels.swift').read_text())
        self.assertEqual(source.splitlines()[-2:], ['    }', '}'])
        self.assertEqual(source.count('\n}'), 1)
        self.assertIn('name.contains("@{")', source)

    def test_local_delete_is_pinned_merged_only_and_ref_only(self):
        source = (ROOT / 'Vendor/NativeGit/NativeGitBridge.m').read_text()
        body = source.split('static NSDictionary *RPDeleteBranch(', 1)[1].split('static NSDictionary *', 1)[0]
        for text in ('RPExpected', 'expectedTargetHead', 'RPLockHead', 'RPLockBranch',
                     'git_branch_is_checked_out', 'git_graph_descendant_of', 'RPIsCancelled',
                     'git_transaction_remove', 'git_transaction_commit', 'refs/heads/'):
            self.assertIn(text, body)
        for text in ('git_checkout_', 'git_index_write', 'git_reset', 'git_stash', 'git_remote_'):
            self.assertNotIn(text, body)
        engine = (ROOT / 'RepoPocket/LocalGitEngine.swift').read_text()
        self.assertIn('"deleteBranch"', engine.split('coordinate(root, writing: ', 1)[1].split('.contains(operation)', 1)[0])

    def test_remote_delete_has_native_confirmation_and_current_default_protection(self):
        github = (ROOT / 'RepoPocket/GitHub.swift').read_text()
        body = production_method(github, '    func deleteBranch(')
        for text in ('expectedHead', 'default_branch', 'permissions?.push', '.protected', 'ensureActiveAccount',
                     '"DELETE"', '/git/refs/heads/', 'statusCode == 204', 'OfficialUpdateRedirectPolicy'):
            self.assertIn(text, body)
        view = (ROOT / 'RepoPocket/DesktopViews.swift').read_text().split('struct BranchPickerView:', 1)[1]
        for text in ('.contextMenu', '.confirmationDialog', 'role: .destructive', 'api.deleteBranch(',
                     '删除 GitHub 远端分支', 'defaultBranch', 'b.name != current', 'presenting: deleting',
                     'Text(deletionMessage).font(.footnote).textSelection(.enabled).softGroupedRow(bottom: !busy)',
                     'Text(deletionMessage)', 'deletionMessage = error.localizedDescription'):
            self.assertIn(text, view)

    @unittest.skipUnless(shutil.which('swiftc'), 'swiftc absent: production URLProtocol fixture NOT executed')
    def test_remote_production_requests_permissions_revalidation_and_response(self):
        github = (ROOT / 'RepoPocket/GitHub.swift').read_text()
        signatures = ['    static func component(', '    static func repoPath(', '    static func filePath(',
                      '    private func url(', '    private func request(', '    var isCurrentSession:',
                      '    private func ensureActiveAccount()', '    private func check(', '    private func operation(',
                      '    private func data(', '    private func decoded<', '    func requireWriteAccess(',
                      '    func repository(', '    func deleteBranch(']
        methods = '\n'.join(production_method(github, s) for s in signatures)
        models = '\n'.join(production_method(github, s) for s in ['struct GitHubAPIError:', 'struct RepoAccess:',
                            'struct RepositoryReference:', 'struct Repository:'])
        desktop = (ROOT / 'RepoPocket/DesktopModels.swift').read_text()
        models += '\n' + production_method(desktop, 'struct DesktopBranch:')
        models += '\n' + desktop_rules_fixture(desktop)
        source = HARNESS.replace('// PRODUCTION_METHODS', methods).replace('// PRODUCTION_MODELS', models)
        source += '\n' + (ROOT / 'RepoPocket/RepositoryInput.swift').read_text()
        source += '\n' + (ROOT / 'RepoPocket/OfficialUpdateRedirectPolicy.swift').read_text()
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / 'main.swift'
            main.write_text(source, encoding='utf-8')
            executable = str(Path(folder) / 'delete-branch')
            subprocess.run(['swiftc', '-parse-as-library', str(main), '-o', executable], check=True)
            subprocess.run([executable], check=True, timeout=60)


@unittest.skipUnless(platform.system() == 'Darwin', 'macOS required for Objective-C/Foundation production bridge')
class NativeBranchDeletion(unittest.TestCase):
    setUpClass = classmethod(local.LocalBranchBehavior.setUpClass.__func__)
    setUp = local.LocalBranchBehavior.setUp
    git = local.LocalBranchBehavior.git
    call = local.LocalBranchBehavior.call
    result = local.LocalBranchBehavior.result
    preserved = local.LocalBranchBehavior.preserved
    make_target = local.LocalBranchBehavior.make_target

    def test_delete_merged_branch_preserves_dirty_index_files_and_head(self):
        self.git('branch', '中文/merged')
        (self.work / '代码.py').write_text('staged\n')
        self.git('add', '代码.py')
        (self.work / '代码.py').write_text('unstaged\n')
        (self.work / 'loose').write_text('untracked\n')
        before = self.preserved()
        self.result('deleteBranch', targetRef='refs/heads/中文/merged', expectedTargetHead=self.head)
        refs = self.git('for-each-ref', '--format=%(refname)', 'refs/heads')
        self.assertNotIn('refs/heads/中文/merged', refs)
        self.assertEqual(self.git('symbolic-ref', 'HEAD'), 'refs/heads/main')
        self.assertEqual(self.preserved(), before)

    def test_current_unmerged_stale_and_nonlocal_branches_cannot_be_deleted(self):
        target = self.make_target()
        self.git('branch', 'merged')
        self.git('update-ref', 'refs/remotes/origin/remote', self.head)
        before = self.preserved()
        for values in (
            {'targetRef': 'refs/heads/main', 'expectedTargetHead': self.head},
            {'targetRef': 'refs/heads/feature', 'expectedTargetHead': target},
            {'targetRef': 'refs/remotes/origin/remote', 'expectedTargetHead': self.head},
            {'targetRef': 'refs/heads/merged', 'expectedTargetHead': '0' * 40},
            {'targetRef': 'refs/heads/merged', 'expectedTargetHead': self.head, 'expectedHead': '0' * 40},
            {'targetRef': 'refs/heads/merged', 'expectedTargetHead': self.head, 'expectedRef': 'refs/heads/other'},
        ):
            with self.subTest(values=values):
                self.assertFalse(self.call('deleteBranch', **values)['ok'])
                self.assertEqual(self.preserved(), before)
                self.assertEqual(self.git('rev-parse', 'merged'), self.head)
                self.assertEqual(self.git('rev-parse', 'feature'), target)

    def test_packed_merged_branch_deletes_without_checkout(self):
        self.git('branch', 'merged')
        self.git('pack-refs', '--all')
        before = self.preserved()
        self.result('deleteBranch', targetRef='refs/heads/merged', expectedTargetHead=self.head)
        self.assertEqual(self.git('for-each-ref', '--format=%(refname)', 'refs/heads'), 'refs/heads/main')
        self.assertEqual(self.preserved(), before)

    def test_branch_checked_out_in_another_worktree_is_preserved(self):
        self.git('branch', 'in-use')
        other = Path(self.temp.name) / 'linked'
        self.git('worktree', 'add', str(other), 'in-use')
        response = self.call('deleteBranch', targetRef='refs/heads/in-use', expectedTargetHead=self.head)
        self.assertFalse(response['ok'])
        self.assertEqual(self.git('rev-parse', 'in-use'), self.head)


HARNESS = r'''
import Foundation
struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
struct GitHubMessage: Decodable { let message: String }
struct User: Codable {}
final class ContentSnapshotCache {
    static let shared = ContentSnapshotCache()
    static func key(_ path: String, query: [URLQueryItem] = []) -> String { path }
    func save(_ body: Data, accountID: String, key: String) {}
}
enum RepositoryWriteRules { static func canWrite(push: Bool?) -> Bool { push == true } }
@MainActor enum AccountStore { static var activeID = "fixture"; static var generation = UUID() }
@MainActor enum CredentialStore { static func read(account: String) -> String { "fixture-only" } }
// PRODUCTION_MODELS
@MainActor final class GitHub {
    let accountID = AccountStore.activeID
    let accountGeneration = AccountStore.generation
    let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BranchFixture.self]
        session = URLSession(configuration: config)
    }
    // PRODUCTION_METHODS
}
final class BranchFixture: URLProtocol {
    static var requests: [URLRequest] = []
    static var defaultBranch = "main"
    static var push: Bool? = true
    static var protected = false
    static var head = String(repeating: "a", count: 40)
    static var status = 204
    static var switchOnBranchRead = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        Task { @MainActor in
            let path = request.url!.path
            let payload: [String: Any]
            let status: Int
            if request.httpMethod == "DELETE" {
                status = Self.status; payload = ["message": "fixture rejection"]
            } else if path.contains("/branches/") {
                if Self.switchOnBranchRead { AccountStore.generation = UUID() }
                status = 200
                payload = ["name": "feature/中文", "protected": Self.protected, "commit": ["sha": Self.head]]
            } else {
                status = 200
                var permissions: [String: Any] = [:]
                if let push = Self.push { permissions["push"] = push }
                payload = ["id": 1, "name": "repo", "full_name": "owner/repo", "html_url": "https://github.com/owner/repo",
                           "default_branch": Self.defaultBranch, "permissions": permissions]
            }
            let bytes = try! JSONSerialization.data(withJSONObject: payload)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
    static func reset() {
        requests = []; defaultBranch = "main"; push = true; protected = false
        head = String(repeating: "a", count: 40); status = 204; switchOnBranchRead = false
    }
}
@main struct Harness {
    @MainActor static func main() async throws {
        let name = "feature/中文", head = String(repeating: "a", count: 40)
        func remove(_ api: GitHub, current: String = "main") async throws {
            try await api.deleteBranch("owner/repo", name: name, expectedHead: head, current: current)
        }
        BranchFixture.reset()
        try await remove(GitHub())
        precondition(BranchFixture.requests.count == 3)
        let deletion = BranchFixture.requests.last!
        precondition(deletion.httpMethod == "DELETE")
        precondition(deletion.url!.path == "/repos/owner/repo/git/refs/heads/" + name)
        precondition(deletion.httpBody == nil)
        precondition(deletion.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
        for mode in ["current", "default", "protected", "denied", "unknown", "moved", "account"] {
            BranchFixture.reset()
            let api = GitHub()
            if mode == "default" { BranchFixture.defaultBranch = name }
            if mode == "protected" { BranchFixture.protected = true }
            if mode == "denied" { BranchFixture.push = false }
            if mode == "unknown" { BranchFixture.push = nil }
            if mode == "moved" { BranchFixture.head = String(repeating: "b", count: 40) }
            if mode == "account" { BranchFixture.switchOnBranchRead = true }
            do {
                try await remove(api, current: mode == "current" ? name : "main")
                preconditionFailure("unsafe deletion accepted: " + mode)
            } catch {}
            precondition(!BranchFixture.requests.contains { $0.httpMethod == "DELETE" })
        }
        for status in [200, 202, 302, 403, 409, 422] {
            BranchFixture.reset(); BranchFixture.status = status
            do { try await remove(GitHub()); preconditionFailure("non-204 accepted") } catch {}
            precondition(BranchFixture.requests.filter { $0.httpMethod == "DELETE" }.count == 1)
        }
        BranchFixture.reset()
        let stale = GitHub(); AccountStore.generation = UUID()
        do { try await remove(stale); preconditionFailure("stale account accepted") } catch {}
        precondition(BranchFixture.requests.isEmpty)
        print("Production branch deletion transport passed")
    }
}
'''


if __name__ == '__main__':
    unittest.main()
