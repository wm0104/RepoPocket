"""Preserve original load/navigation; allow a separate root-only single-row presence probe."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import shutil, subprocess, tempfile, unittest
ROOT = REPO_ROOT
BASE = '92e8da57ce9d06d064c4f36740712697af90cd72'
APP = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
BROWSER = APP.split('struct BrowserView: View {',1)[1].split('struct FileView:',1)[0]
LOAD = BROWSER[BROWSER.index('    private func load() async {'):BROWSER.index('    private func deleteRemote(')]

class BrowserRollbackTests(unittest.TestCase):
    def test_exact_stable_navigation_and_api(self):
        if subprocess.run(['git', 'cat-file', '-e', BASE+'^{commit}'], cwd=ROOT, capture_output=True).returncode:
            subprocess.run(['git', 'fetch', '--depth=1', 'origin', BASE], cwd=ROOT, check=True)
        for file in ('RepoPocket/ReleaseAssetRedirectPolicy.swift','RepoPocket/RepositoryStar.swift','RepoPocket/RepositoryUI.swift'):
            current = (ROOT/file).read_text()
            historic = subprocess.check_output(['git','show',f'{BASE}:{file}'],cwd=ROOT,text=True)
            if file.endswith('/RepositoryUI.swift'):
                # Only the newly approved star/fork count destinations differ.
                begin, end = 'struct RepositoryStatistics:', '/// The same compact summary'
                self.assertEqual(current.split(begin)[0], historic.split(begin)[0])
                self.assertEqual(current.split(end)[1], historic.split(end)[1])
                self.assertIn('RepositorySocialView', current)
            else: self.assertEqual(current, historic)
        # RepoPocketApp.swift is not compared byte-for-byte: the directory-nav
        # freeze fix intentionally changes BrowserView's destination form. Its
        # release-removal and menu contracts are asserted below instead.
        self.assertNotIn('RepositoryRelease', APP)
        for token in ('RepositoryRelease', 'repositoryReleasePage', 'repositoryLatestRelease', 'releases.load', 'releases.reset'):
            for file in (ROOT/'RepoPocket').glob('*.swift'):
                self.assertNotIn(token,file.read_text())
        for file in ('RepositoryReleaseUI.swift','RepositoryReleases.swift'):
            self.assertFalse((ROOT/'RepoPocket'/file).exists())
        self.assertNotIn('/releases',BROWSER)
        self.assertIn('if path.isEmpty && !showFiles { repositoryOverview } else { directoryRows }', BROWSER)
        self.assertEqual(BROWSER.count('RepositoryHomeHighlights(api: api, repo: repo, releaseState: homeRelease, runState: homeRuns)'), 1)
        highlights = (ROOT/'RepoPocket/RepositoryHomeHighlights.swift').read_text()
        self.assertEqual(highlights.count('ReleaseManagementDestination(api: api, repo: repo)'), 1)
        self.assertNotIn('managedReleases', LOAD)
        api_original = subprocess.check_output(['git','show',f'{BASE}:RepoPocket/GitHub.swift'],cwd=ROOT,text=True)
        api_new = (ROOT/'RepoPocket/GitHub.swift').read_text()
        added_start = api_new.index('    // These bounded endpoints')
        # Only the explicitly approved default workspace naming expression differs
        # outside the bounded Release endpoints. Normalize that single expression;
        # the complete historic API baseline remains byte-for-byte protected.
        approved = 'name: binding.repo.replacingOccurrences(of: "/", with: "-") + "-" + binding.branch + "-" + (binding.remoteCommitterDate.map { ISO8601DateFormatter().string(from: $0) } ?? String(binding.head.prefix(8)))'
        historic = 'name: binding.repo.replacingOccurrences(of: "/", with: "-") + (binding.branch == "main" || binding.branch == "master" ? "" : "-" + binding.branch)'
        self.assertEqual(api_new.count(approved), 1)
        # Community additions are read-only and still use the original data()
        # account/host/error guards. Normalize only those exact additions before
        # comparing the complete historic write/download implementation.
        normalized = api_new[:added_start].replace(approved, historic)
        # Authorized description-only PATCH is verified by its dedicated owner,
        # permission and account-race fixtures; freeze all unrelated transport.
        description_start = normalized.index('    func descriptionContext(')
        description_end = normalized.index('    func deletionContext(', description_start)
        normalized = normalized[:description_start] + normalized[description_end:]
        normalized = normalized.replace('page: Int, options: RepositorySearchOptions = .init()) async throws -> RepositorySearchResponse',
                                        'page: Int) async throws -> RepositorySearchResponse')
        normalized = normalized.replace('query: query, page: page, options: options)', 'query: query, page: page)')
        gateway_start = normalized.index('    // Read-only gateway')
        gateway_end = normalized.index('    func searchUsers(', gateway_start)
        gateway = normalized[gateway_start:gateway_end]
        self.assertIn('let bytes = try await data(path, query: query)', gateway)
        self.assertIn('try Task.checkCancellation()', gateway)
        self.assertNotIn('method:', gateway.split('    // Native collaboration transport:')[0])
        normalized = normalized[:gateway_start] + normalized[gateway_end:]
        # Explicit fork-status fix: new lookup and accepted-POST bookkeeping are
        # covered by test_repository_fork_status.py. Keep every unrelated byte
        # of the historic transport and mutation guards protected below.
        normalized = normalized.replace('    let source: RepositoryReference?\n', '')
        normalized = normalized.replace('    @Published private(set) var forkNames: [String: String] = [:]\n', '')
        normalized = normalized.replace('    private var forkChecks: [String: Task<String?, Error>] = [:]\n', '')
        normalized = normalized.replace('    private var forkCheckedAt: [String: Date] = [:]\n', '')
        normalized = normalized.replace('    private var forkCheckIDs: [String: UUID] = [:]\n', '')
        fork_start = normalized.index('    // Fork status is read only, on demand, and scoped to this account generation.')
        fork_end = normalized.index('    func fork(_ repo: String)', fork_start)
        normalized = normalized[:fork_start] + normalized[fork_end:]
        accepted_post = '''        let result = try await decoded(Repository.self, endpoint + "/forks", method: "POST", object: [:])
        try ensureActiveAccount()
        // The accepted POST itself confirms this relationship, even before metadata is ready.
        if RepositoryGroupRules.isOwned(result.full_name, login: login) {
            let key = (try RepositoryInput.parse(repo)).lowercased()
            forkNames[key] = result.full_name
            forkCheckedAt[key] = Date()
        }
        return result'''
        assert normalized.count(accepted_post) == 1
        normalized = normalized.replace(accepted_post, '        return try await decoded(Repository.self, endpoint + "/forks", method: "POST", object: [:])')
        # Explicit fork-write revalidation is covered by production fork fixtures.
        revalidation = '        guard try await existingFork(repo) == nil else { throw AppError(text: "此仓库已复刻。") }\n        try ensureActiveAccount()\n'
        assert normalized.count(revalidation) == 1
        normalized = normalized.replace(revalidation, '')
        # The bounded file-backed upload path and its two consumers are covered
        # by focused queue/Troll tests. Normalize those complete methods here so
        # this exact comparison still protects every unrelated historic API.
        helper_start = normalized.index('    private func uploadGitBlobFile(')
        helper_end = normalized.index('    func history(', helper_start)
        normalized = normalized[:helper_start] + normalized[helper_end:]
        for signature, next_signature in (
            ('    func commitQueue(', '    func identify('),
            ('    func trollPublish(', '    func metadataSnapshot('),
        ):
            current_start = normalized.index(signature)
            current_end = normalized.index(next_signature, current_start)
            old_start = api_original.index(signature)
            old_end = api_original.index(next_signature, old_start)
            normalized = normalized[:current_start] + api_original[old_start:old_end] + normalized[current_end:]
        normalized = normalized.replace('session.data(for: r, delegate: GitHubAPIRedirectPolicy())',
                                        'session.data(for: r, delegate: OfficialUpdateRedirectPolicy())')
        self.assertEqual(normalized.rstrip() + '\n}\n', api_original)
        self.assertEqual(BROWSER.count('.task { if !loaded { await load() } }'),1)
        for menu in ('CopyRepositoryLinkButton','ForkRepositoryMenuButton','RepositoryStarMenuButton'):
            self.assertIn(menu,BROWSER)
        for file in ('RepoPocket/RepositoryStar.swift','RepoPocket/RepositoryStarUI.swift'):
            text=(ROOT/file).read_text()
            self.assertNotIn('DispatchSemaphore',text); self.assertNotIn('.wait()',text)
        api=(ROOT/'RepoPocket/GitHub.swift').read_text()
        for method in ('func releases(', 'func createRelease(', 'func downloadAsset(', 'func officialAppUpdateData()'):
            self.assertIn(method,api)
        update=api.split('func officialAppUpdateData()',1)[1].split('func deletionContext',1)[0]
        self.assertIn('https://api.github.com/repos/wm0104/RepoPocket/releases/latest',update)

    @unittest.skipUnless(shutil.which('swiftc'),'Production load mocks run on macOS CI')
    def test_production_load_owned_other_root_and_folder_zero_release_calls(self):
        source='''import Foundation
struct Entry { let name: String }
struct Repository { let full_name: String }
enum AccountStore { static var generation = UUID() }
enum RefreshFailure { static func isCancellation(_ error: Error) -> Bool { false } }
final class GitHub {
 var calls: [String] = []; var isCurrentSession = true; var message = ""
 func resolvedBranch(_ repo: String, branch: String) async throws -> String { calls.append("branch:"+repo); return "main" }
 func contents(_ repo: String, path: String, branch: String) async throws -> [Entry] { calls.append("contents:"+repo+":"+path); return [Entry(name:"README.md")] }
 func repository(_ repo: String) async throws -> Repository { calls.append("metadata:"+repo); return Repository(full_name:repo) }
 func releases(_ repo: String) async throws -> [Int] { calls.append("releases:"+repo); return [] }
}
final class BrowserHarness {
 let api: GitHub; let repo: String; let path: String
 var activeBranch = ""; var repositoryInfo: Repository?; var busy = false
 var selectedBranch = ""; var entries: [Entry] = []; var loaded = false
 init(_ api: GitHub, _ repo: String, _ path: String) { self.api=api; self.repo=repo; self.path=path }
 func enter() async { if !loaded { await load() } }
'''+LOAD+'''}
@main struct Run {
 static func main() async {
  for repo in ["wm0104/RepoPocket", "other/public-repo"] {
   for path in ["", "Sources"] {
    let api=GitHub(); let browser=BrowserHarness(api,repo,path)
    await browser.enter(); await browser.enter()
    precondition(browser.loaded && browser.entries.count == 1 && !browser.busy)
    precondition(api.calls == ["branch:"+repo,"contents:"+repo+":"+path,"metadata:"+repo])
    precondition(!api.calls.contains { $0.contains("releases") })
   }
  }
  print("PASS production Browser load: owned/other root/folder, zero repository release calls")
 }
}
'''
        with tempfile.TemporaryDirectory() as folder:
            file=Path(folder)/'main.swift'; file.write_text(source)
            subprocess.run(['swiftc','-parse-as-library',str(file),'-o',folder+'/tests'],check=True)
            subprocess.run([folder+'/tests'],check=True)

if __name__ == '__main__': unittest.main()
