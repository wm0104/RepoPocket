"""Restore Browser source exactly, execute its production load against request spies."""
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
        for file in ('RepoPocket/GitHub.swift','RepoPocket/ReleaseAssetRedirectPolicy.swift','RepoPocket/RepositoryStar.swift','RepoPocket/RepositoryStarUI.swift','RepoPocket/RepositoryUI.swift'):
            self.assertEqual((ROOT/file).read_text(), subprocess.check_output(['git','show',f'{BASE}:{file}'],cwd=ROOT,text=True))
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
