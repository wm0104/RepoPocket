"""Network-free production deletion gates and settings contracts. No HTTP requests."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import shutil
import subprocess
import tempfile
import unittest

api = Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text()
core = Path(REPO_ROOT, 'RepoPocket/RepositoryDeletion.swift').read_text()
ui = Path(REPO_ROOT, 'RepoPocket/RepositoryDeletionView.swift').read_text()
app = Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text()

class DeletionTests(unittest.TestCase):
    def test_production_wiring(self):
        self.assertIn('repositoryInfo?.permissions?.admin != true', app)
        self.assertIn('confirmation == repository.full_name', ui)
        self.assertIn('interactiveDismissDisabled(busy)', ui)
        self.assertIn('guard !busy else { return }', ui)
        self.assertIn('context: api.deletionContext(repositoryInfo)', app)
        self.assertIn('try self.ensureActiveAccount()', api)
        self.assertIn('statusCode == 204', api)
        self.assertIn('delete_repo', core)
        self.assertIn('Administration: write', core)
        self.assertIn('let permissions: Permissions?', api)
        deletion = api[api.index('    func deleteRepository'):api.index('    private func ensureActiveAccount')]
        self.assertIn('method: "DELETE"', deletion)
        self.assertNotIn('FileManager', deletion + core + ui)
        self.assertNotIn('Section("已保存账号")', app)
        self.assertIn('账号管理：切换、添加或移除本机账号', app)
        self.assertIn('.refreshable { await refreshProfile() }', app)
        self.assertIn('不会删除 GitHub 账号、远端仓库或本地工作区', Path(REPO_ROOT, 'RepoPocket/AccountManagement.swift').read_text())
        management = Path(REPO_ROOT, 'RepoPocket/AccountManagement.swift').read_text()
        self.assertIn('AccountStore.activate(account.id)', management)
        self.assertIn('AccountStore.remove(account.id)', management)

    def test_prefill_clear_and_final_confirmation_contract(self):
        self.assertIn('init(api: GitHub, repository: Repository, context: RepositoryDeletionContext,', ui)
        self.assertIn('_confirmation = State(initialValue: repository.full_name)', ui)
        self.assertNotIn('Section("输入完整 owner/repo 确认")', ui)
        self.assertIn('Section("已预填所选仓库，无需输入")', ui)
        self.assertIn('confirmation = ""', ui)
        self.assertIn('.accessibilityLabel("清空仓库删除确认")', ui)
        self.assertIn('.disabled(busy || confirmation.isEmpty)', ui)
        self.assertIn('.toolbar { Button("取消") { dismiss() }.disabled(busy) }', ui)
        self.assertIn('context == api.deletionContext(repository)', ui)
        self.assertIn('repository.permissions?.admin == true', ui)
        entry = ui[ui.index('Button("永久删除远端仓库"'):ui.index('.navigationTitle')]
        self.assertIn('showFinalConfirmation = true', entry)
        self.assertIn('guard canDelete else { return }', entry)
        self.assertNotIn('deleteRepository', entry)
        alert = ui[ui.index('.alert('):]
        self.assertIn('Button("取消", role: .cancel)', alert)
        self.assertIn('.keyboardShortcut(.defaultAction)', alert)
        self.assertIn('role: .destructive', alert)
        self.assertIn('confirmDeletion()', alert)
        self.assertIn('repository.full_name', alert)
        self.assertNotIn('\\(confirmation)', alert)
        self.assertIn('不可撤销', alert)
        execution = ui[ui.index('private func confirmDeletion()'):ui.index('var body: some View')]
        self.assertLess(execution.index('guard canDelete else'), execution.index('busy = true'))
        self.assertIn('let confirmedName = confirmation', execution)
        self.assertIn('deleteRepository(repository, context: context, confirmation: confirmedName)', execution)
        self.assertEqual(ui.count('api.deleteRepository('), 1)
        self.assertIn('guard confirmation == captured.fullName else', core)
        self.assertEqual(app.count('RepositoryDeletionView(api: api, repository: target.repository, context: target.context)'), 1)

    @unittest.skipUnless(shutil.which('swiftc'), 'requires macOS Actions Swift compiler')
    def test_mocked_production_orchestration(self):
        models = api[api.index('struct User:'):api.index('struct Entry:')]
        source = 'import Foundation\n' + api[api.index('struct AppError:'):api.index('struct GitHubAPIError:')] + models + core.replace('import Foundation', '') + r'''
@main struct Tests {
    static func main() async throws {
        let generation = UUID()
        let target = RepositoryDeletionContext(accountID: "alice", generation: generation, repositoryID: 7, fullName: "alice/RepoPocket-releases")
        func repository(_ id: Int = 7, _ name: String = "alice/RepoPocket-releases", _ admin: String = "true") throws -> Repository {
            let json = "{\"id\":\(id),\"full_name\":\"\(name)\",\"name\":\"tool\",\"html_url\":\"https://github.com/alice/RepoPocket-releases\",\"permissions\":{\"admin\":\(admin)}}"
            return try JSONDecoder().decode(Repository.self, from: Data(json.utf8))
        }
        let fresh = try repository()
        // Exact confirmation: no trimming, partial names, case folding or blank bypass.
        for bad in ["", "tool", "bob/tool", "Alice/tool", " alice/RepoPocket-releases", "alice/RepoPocket-releases "] {
            var calls = 0
            do {
                _ = try await RepositoryDeletion.execute(context: target, confirmation: bad, current: { target }, fetch: { calls += 1; return fresh }, remove: { calls += 100 })
                preconditionFailure("confirmation bypass")
            } catch { precondition(calls == 0) }
        }
        // Account, generation (including switch away-and-back), and selected repo changes.
        for changed in [
            RepositoryDeletionContext(accountID: "bob", generation: generation, repositoryID: 7, fullName: "alice/RepoPocket-releases"),
            RepositoryDeletionContext(accountID: "alice", generation: UUID(), repositoryID: 7, fullName: "alice/RepoPocket-releases"),
            RepositoryDeletionContext(accountID: "alice", generation: generation, repositoryID: 8, fullName: "alice/RepoPocket-releases"),
            RepositoryDeletionContext(accountID: "alice", generation: generation, repositoryID: 7, fullName: "alice/other")
        ] {
            var calls = 0
            do {
                _ = try await RepositoryDeletion.execute(context: target, confirmation: target.fullName, current: { changed }, fetch: { calls += 1; return fresh }, remove: { calls += 100 })
                preconditionFailure("isolation bypass")
            } catch { precondition(calls == 0) }
            var current = target
            do {
                _ = try await RepositoryDeletion.execute(context: target, confirmation: target.fullName, current: { current }, fetch: { current = changed; return fresh }, remove: { calls += 100 })
                preconditionFailure("post-await isolation bypass")
            } catch { precondition(calls == 0) }
        }
        // API repo identity and admin permission must be freshly checked.
        for denied in [try repository(8), try repository(7, "alice/renamed"), try repository(7, "alice/RepoPocket-releases", "false"), try repository(7, "alice/RepoPocket-releases", "null")] {
            var deletes = 0
            do {
                _ = try await RepositoryDeletion.execute(context: target, confirmation: target.fullName, current: { target }, fetch: { denied }, remove: { deletes += 1 })
                preconditionFailure("API identity/admin bypass")
            } catch { precondition(deletes == 0) }
        }
        var deletes = 0
        let result = try await RepositoryDeletion.execute(context: target, confirmation: target.fullName, current: { target }, fetch: { fresh }, remove: { deletes += 1 })
        precondition(deletes == 1 && result.contains("已删除远端仓库") && result.contains("本地工作区未删除"))
        // Failure must not manufacture success; mocks include permission, missing repo and transport errors.
        for text in ["403 " + RepositoryDeletion.permissionHelp, "404 missing repo", "network failure"] {
            do {
                _ = try await RepositoryDeletion.execute(context: target, confirmation: target.fullName, current: { target }, fetch: { fresh }, remove: { throw AppError(text: text) })
                preconditionFailure("failure swallowed")
            } catch { precondition(error.localizedDescription == text) }
        }
        do {
            _ = try await RepositoryDeletion.execute(context: target, confirmation: target.fullName, current: { target }, fetch: { throw AppError(text: "GET failed") }, remove: { preconditionFailure("DELETE after GET failure") })
            preconditionFailure("GET failure swallowed")
        } catch { precondition(error.localizedDescription == "GET failed") }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await RepositoryDeletion.execute(context: target, confirmation: target.fullName, current: { target }, fetch: { preconditionFailure("GET after cancel") }, remove: { preconditionFailure("DELETE after cancel") })
                preconditionFailure("cancel ignored")
            } catch { precondition(error is CancellationError) }
        }
        await cancelled.value
        print("PASS: exact confirmation, account/generation/repo isolation, fresh admin/identity, success, 403/404/network/GET errors, cancellation; zero real HTTP")
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'main.swift'
            path.write_text(source)
            executable = str(Path(directory) / 'tests')
            subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', executable], check=True)
            subprocess.run([executable], check=True)

if __name__ == '__main__':
    unittest.main()
