"""No real GitHub mutation: execute production Swift store with an isolated mock."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import unittest, shutil, tempfile, subprocess
ROOT = REPO_ROOT

class StarTests(unittest.TestCase):
    def test_menu_and_auth_contract(self):
        api = (ROOT/'RepoPocket/GitHub.swift').read_text()
        ui = (ROOT/'RepoPocket/RepositoryStarUI.swift').read_text()
        card = (ROOT/'RepoPocket/RepositoryUI.swift').read_text()
        app = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
        sections = (ROOT/'RepoPocket/RepositorySections.swift').read_text()
        endpoint = api.split('func starRequest(',1)[1].split('func applyStarChange',1)[0]
        self.assertIn('"/user/starred/"', endpoint)
        self.assertIn('try requireStarSession()', endpoint)
        self.assertNotIn('requireWriteAccess', endpoint)
        self.assertIn('checking: method == "GET"', endpoint)
        self.assertIn('RepositoryStarMenuButton(name: repository.full_name',card)
        self.assertIn('RepositoryStarMenuButton(name: repo',app)
        self.assertNotIn('api.stars.status',card)
        self.assertIn('.task(id: name)',ui)
        self.assertIn('正在查询星标',ui)
        self.assertIn('.disabled(true)',ui)
        self.assertIn('请登录账号',ui)
        self.assertIn('star.fill',ui)
        self.assertIn('fixed.generation == AccountStore.generation',ui)
        self.assertNotIn('confirmationDialog',ui)
        self.assertNotIn('isOwned',ui)
        for source in [app,sections]: self.assertIn('.onChange(of: api.starRevision)',source)
        self.assertIn('CURRENT_PROJECT_VERSION: "1.0.7"',(ROOT/'project.yml').read_text())

    @unittest.skipUnless(shutil.which('swiftc'), 'Production Swift mocks run on macOS CI')
    def test_production_store_network_free(self):
        store = (ROOT/'RepoPocket/RepositoryStar.swift').read_text().replace('import Combine','')
        harness = r'''
import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
enum AccountStore { static var generation = UUID() }
enum RepositoryHomeSection { case owned, starred }
struct Repository { let full_name: String; let stargazers_count: Int? }
@MainActor final class GitHub {
 var accountID = "A", authenticated = true, current = true
 var code = 404, failMetadata = false, switchDuring = false, slow = false
 var reads = 0, writes: [String] = [], active = 0, peak = 0
 var collectionCache: [RepositoryHomeSection: [Repository]] = [.starred: [], .owned: []]
 var starRevision = 0
 var isCurrentSession: Bool { current }
 var list: [Repository] { collectionCache[.starred] ?? [] }
 var count: Int? = 7
 func requireStarSession() throws {
  if !authenticated { throw AppError(text: "请登录账号") }
  if !current { throw AppError(text: "旧会话") }
 }
 func cachedCollection(_ section: RepositoryHomeSection) -> [Repository]? { collectionCache[section] }
 func starRequest(_ name: String, method: String) async throws -> Bool {
  try requireStarSession()
  active += 1; peak = max(peak, active); defer { active -= 1 }
  if method == "GET" { reads += 1 } else { writes.append(method + ":" + name) }
  if slow { try await Task.sleep(nanoseconds: 30_000_000) }
  await Task.yield()
  if switchDuring { current = false; AccountStore.generation = UUID() }
  try requireStarSession()
  return try RepositoryStarRules.status(code, checking: method == "GET")
 }
 func repository(_ name: String) async throws -> Repository {
  if failMetadata { throw AppError(text: "metadata failed") }
  return Repository(full_name: name, stargazers_count: count)
 }
 func applyStarChange(name: String, starred: Bool, repository: Repository?) {
  list.removeAll { $0.full_name.lowercased() == name.lowercased() }
  if starred, let repository { list.insert(repository, at: 0) }
 }
}
'''
        production_cache = (ROOT/'RepoPocket/GitHub.swift').read_text().split('    func applyStarChange(',1)[1].split('    func clearMemoryCaches()',1)[0]
        mock_cache = ''' func applyStarChange(name: String, starred: Bool, repository: Repository?) {
  list.removeAll { $0.full_name.lowercased() == name.lowercased() }
  if starred, let repository { list.insert(repository, at: 0) }
 }
'''
        harness = harness.replace(mock_cache, '    func applyStarChange(' + production_cache)
        harness += (ROOT/'RepoPocket/RepositoryInput.swift').read_text() + store
        harness += r'''
@main struct Harness {
 @MainActor static func main() async throws {
  precondition(try RepositoryStarRules.status(204, checking: true))
  precondition(try RepositoryStarRules.status(404, checking: true) == false)
  for code in [401,403,429,500,200,404] {
   do { _ = try RepositoryStarRules.status(code, checking: false); fatalError("accepted invalid write") } catch {}
  }
  for code in [401,403,429,500,200] {
   do { _ = try RepositoryStarRules.status(code, checking: true); fatalError("accepted invalid status") } catch {}
  }
  precondition(RepositoryStarRules.clampedCount(-1) == 0)
  precondition(RepositoryStarRules.clampedCount(nil) == nil)
  let api = GitHub(), store = RepositoryStarStore(api: GitHub())
  _ = store // use stores whose owner is retained below
  let s = RepositoryStarStore(api: api)
  api.authenticated = false
  do { _ = try await s.status("a/b"); fatalError() } catch {}
  precondition(api.reads == 0 && api.writes.isEmpty)
  api.authenticated = true; api.slow = true
  async let first = s.status("a/b")
  async let second = s.status("a/b")
  let values = try await (first,second)
  precondition(!values.0 && !values.1 && api.reads == 1)
  let target = try s.target("https://github.com/a/b.git", desired: true)
  api.code = 204
  async let add: Void = s.perform(target, repository: nil)
  async let duplicate: Void = s.perform(target, repository: nil)
  _ = try await (add,duplicate)
  precondition(api.writes == ["PUT:a/b"] && s.known("A/B") == true)
  precondition(api.list.count == 1 && api.list[0].stargazers_count == 7)
  let reads = api.reads
  precondition(try await s.status("A/B"))
  precondition(api.reads == reads)
  let remove = try s.target("a/b", desired: false)
  api.code = 403
  do { try await s.perform(remove, repository: nil); fatalError() } catch {}
  precondition(s.known("a/b") == true && api.list.count == 1)
  api.code = 204; api.count = nil
  try await s.perform(remove, repository: nil)
  precondition(s.known("a/b") == false && api.list.isEmpty)
  precondition(s.display(Repository(full_name: "a/b", stargazers_count: 5)).stargazers_count == nil)
  let stale = try s.target("a/b", desired: true), writes = api.writes.count
  AccountStore.generation = UUID()
  do { try await s.perform(stale, repository: nil); fatalError() } catch {}
  precondition(api.writes.count == writes)
  let live = try s.target("a/b", desired: true)
  api.switchDuring = true
  do { try await s.perform(live, repository: nil); fatalError() } catch {}
  precondition(s.known("a/b") == false && api.list.isEmpty)
  api.switchDuring = false; api.current = true; api.code = 404
  s.invalidate()
  _ = try await s.status("a/b")
  let metaTarget = try s.target("a/b", desired: true)
  api.code = 204; api.failMetadata = true
  try await s.perform(metaTarget, repository: nil)
  precondition(s.known("a/b") == true && api.collectionCache[.starred] == nil)
  api.collectionCache[.starred] = []
  s.invalidate(); api.code = 404
  _ = try await s.status("a/b")
  let suppliedTarget = try s.target("a/b", desired: true)
  api.code = 204
  try await s.perform(suppliedTarget, repository: Repository(full_name: "a/b", stargazers_count: nil))
  precondition(api.list.count == 1 && api.list[0].stargazers_count == nil)
  api.applyStarChange(name: "A/B", starred: true, repository: Repository(full_name: "a/b", stargazers_count: nil))
  precondition(api.list.count == 1)
  api.applyStarChange(name: "a/b", starred: false, repository: nil)
  precondition(api.list.isEmpty)
  api.code = 404
  s.invalidate()
  await withTaskGroup(of: Void.self) { group in
   for n in 0..<12 { group.addTask { _ = try? await s.status("a/r\(n)") } }
  }
  precondition(api.peak <= 3)
  s.invalidate(); precondition(s.known("a/b") == nil)
  print("PASS: production star status/write, dedup, auth, session, count, list, concurrency mocks")
 }
}
'''
        # Swift precondition is a nonthrowing autoclosure; evaluate throws before assertions.
        harness = harness.replace('precondition(try RepositoryStarRules.status(204, checking: true))','let ok = try RepositoryStarRules.status(204, checking: true); precondition(ok)')
        harness = harness.replace('precondition(try RepositoryStarRules.status(404, checking: true) == false)','let missing = try RepositoryStarRules.status(404, checking: true); precondition(!missing)')
        harness = harness.replace('precondition(try await s.status("A/B"))','let known = try await s.status("A/B"); precondition(known)')
        harness = harness.replace('let api = GitHub(), store = RepositoryStarStore(api: GitHub())\n  _ = store // use stores whose owner is retained below','let api = GitHub()')
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp); (p/'main.swift').write_text(harness)
            subprocess.run(['swiftc','-parse-as-library',str(p/'main.swift'),'-o',str(p/'tests')],check=True)
            subprocess.run([str(p/'tests')],check=True)

if __name__ == '__main__': unittest.main()
