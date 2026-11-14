from pathlib import Path
import unittest, shutil, tempfile, subprocess
ROOT = Path(__file__).resolve().parents[1]
class ForkStatusTests(unittest.TestCase):
    def test_existing_fork_state_is_discovered_and_shared(self):
        api = (ROOT/'RepoPocket/GitHub.swift').read_text()
        menu = (ROOT/'RepoPocket/RepositoryForkMenu.swift').read_text()
        self.assertIn('func existingFork(', api)
        self.assertIn('affiliations: [OWNER]', api)
        self.assertIn('let source: RepositoryReference?', api)
        self.assertIn('RepositoryForkRules.matches', api)
        self.assertIn('networkCount == directCount', api)
        self.assertIn('Date().timeIntervalSince(date) < 300', api)
        self.assertNotIn('return try await pending.value', api)
        self.assertNotIn('复刻或定位已有复刻', menu)
        self.assertIn('forkNames[', menu)
        self.assertIn('已复刻', menu)
        self.assertIn('.task(id: name + "\\n" + String(refreshID))', menu)
        self.assertIn('await state.check(name, api: api)', menu)
        self.assertNotIn('scenePhase', menu)
    def test_fallback_and_write_guardrails(self):
        api = (ROOT/'RepoPocket/GitHub.swift').read_text()
        fallback = api.split('var detailCount = 0', 1)[1].split('func fork(', 1)[0]
        for text in ['for page in 1...3', 'detailCount < 20', 'owned.count < 100', 'affiliation=owner&per_page=100', 'try ensureActiveAccount()', 'RepositoryForkRules.matches']:
            self.assertIn(text, fallback)
        self.assertNotIn('try?', fallback)
        lookup = api.split('func existingFork(', 1)[1].split('private func findExistingFork(', 1)[0]
        self.assertLess(lookup.index('guard forkCheckIDs[key] == requestID else'), lookup.index('forkNames[key] = result'))
        self.assertIn('throw CancellationError()', lookup)
        write = api.split('func fork(', 1)[1].split('func createRepository(', 1)[0]
        self.assertLess(write.index('guard try await existingFork(repo) == nil'), write.index('endpoint + "/forks"'))
        menu = (ROOT/'RepoPocket/RepositoryForkMenu.swift').read_text()
        self.assertIn('forceRefresh: true', menu)
        for scope in ['func prepare(', 'func confirm(']:
            guard = menu.split(scope, 1)[1].split('else { return }', 1)[0]
            self.assertIn('checked.contains(', guard)
            self.assertIn('!failed.contains(', guard)
        self.assertEqual(menu.split('struct ForkRepositoryMenuButton:', 1)[1].split('private struct RepositoryForkConfirmation:', 1)[0].count('Button {'), 1)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production fork lookup mocks run on macOS CI')
    def test_production_lookup_network_free(self):
        api = (ROOT/'RepoPocket/GitHub.swift').read_text()
        methods = '    func existingFork(' + api.split('    func existingFork(',1)[1].split('    func createRepository(',1)[0]
        rules = (ROOT/'RepoPocket/RepositoryForkMenu.swift').read_text().split('struct RepositoryForkTarget:',1)[0].replace('import SwiftUI','import Foundation')
        source = r'''
import Foundation
struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
struct GitHubAPIError: Error { let status: Int }
enum RepositoryHomeSection { case owned }
struct RepositoryReference: Decodable { let full_name: String }
struct Repository: Decodable {
 let full_name: String
 var fork: Bool?
 var parent: RepositoryReference?
 var source: RepositoryReference?
}
@MainActor final class GitHub {
 var login = "me", current = true
 var forkNames: [String: String] = [:]
 var forkChecks: [String: Task<String?, Error>] = [:]
 var forkCheckIDs: [String: UUID] = [:]
 var forkCheckedAt: [String: Date] = [:]
 var collectionCache: [RepositoryHomeSection: [Repository]] = [:]
 var fixtures: [String: Repository] = [:], reads: [String] = []
 var graphCalls = 0, posts = 0, switchOnRead = false
 var ownedPages: [[Repository]] = [[]], ownedCalls = 0
 var denyOwned = false, denyOwnedStatus = 403
 var holdGraph = false
 var graphGate: CheckedContinuation<Void, Never>?
 var holdReads = false
 var readGate: CheckedContinuation<Void, Never>?
 var graph = #"{"data":{"root":{"forkCount":0,"direct":{"totalCount":0},"forks":{"nodes":[]}},"target":{"forks":{"nodes":[]}}}}"#
 func requireStarSession() throws { try ensureActiveAccount() }
 func ensureActiveAccount() throws { if !current { throw AppError(text: "stale") } }
 func identify() async throws { try ensureActiveAccount() }
 static func repoPath(_ name: String) throws -> String { "/repos/" + (try RepositoryInput.parse(name)) }
 func repository(_ name: String) async throws -> Repository {
  reads.append(name)
  if holdReads { await withCheckedContinuation { readGate = $0 } } else { await Task.yield() }
  if switchOnRead { current = false }
  try ensureActiveAccount()
  guard let result = fixtures[name.lowercased()] else { throw GitHubAPIError(status: 404) }
  return result
 }
 func decoded<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET", object: [String: Any]? = nil) async throws -> T {
  try ensureActiveAccount()
  if path == "/graphql" {
   graphCalls += 1
   if holdGraph { await withCheckedContinuation { graphGate = $0 } }
   try ensureActiveAccount()
   return try JSONDecoder().decode(type, from: Data(graph.utf8))
  }
  if path.hasPrefix("/user/repos?") {
   ownedCalls += 1
   if denyOwned { throw GitHubAPIError(status: denyOwnedStatus) }
   let rows = ownedPages[min(ownedCalls - 1, ownedPages.count - 1)]
   let payload = rows.map { row -> [String: Any] in
    var result: [String: Any] = ["full_name": row.full_name]
    if let fork = row.fork { result["fork"] = fork }
    if let parent = row.parent { result["parent"] = ["full_name": parent.full_name] }
    if let source = row.source { result["source"] = ["full_name": source.full_name] }
    return result
   }
   return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: payload))
  }
  precondition(path == "/repos/up/tool/forks" && method == "POST")
  posts += 1
  return try JSONDecoder().decode(type, from: Data(#"{"full_name":"me/tool","fork":true}"#.utf8))
 }
''' + methods + "}\n"
        source += (ROOT/'RepoPocket/RepositoryInput.swift').read_text()
        source += (ROOT/'RepoPocket/RepositorySafetyRules.swift').read_text().split('enum UpdateNoticeRules')[0]
        source += rules + r'''
@main struct Harness {
 @MainActor static func main() async throws {
  let upstream = Repository(full_name: "up/tool")
  let fork = Repository(full_name: "me/tool", fork: true, parent: RepositoryReference(full_name: "up/tool"))
  let api = GitHub()
  api.fixtures = ["up/tool": upstream, "me/tool": fork]
  let found = try await api.existingFork("UP/tool")
  precondition(found == "me/tool" && api.posts == 0 && api.graphCalls == 0)
  let reads = api.reads.count
  _ = try await api.existingFork("up/TOOL")
  precondition(api.reads.count == reads)
  api.collectionCache[.owned] = [fork]
  api.forkCheckedAt["up/tool"] = Date().addingTimeInterval(-301)
  let refreshedPositive = try await api.existingFork("up/tool")
  precondition(refreshedPositive == "me/tool" && api.reads.count > reads)
  // Cancelling the first waiter cannot stop a second waiter publishing shared state.
  let shared = GitHub(); shared.fixtures = ["up/tool": upstream, "me/tool": fork]
  shared.holdReads = true
  let firstWaiter = Task { try await shared.existingFork("up/tool") }
  while shared.readGate == nil { await Task.yield() }
  var secondStarted = false
  let secondWaiter = Task { secondStarted = true; return try await shared.existingFork("up/tool") }
  while !secondStarted { await Task.yield() }
  firstWaiter.cancel()
  shared.holdReads = false
  shared.readGate?.resume(); shared.readGate = nil
  _ = try? await firstWaiter.value
  let sharedResult = try await secondWaiter.value
  precondition(sharedResult == "me/tool" && shared.forkNames["up/tool"] == "me/tool")
  // An old owned-cache positive finishing after fresh nil must return the
  // published fresh nil, never republish its stale positive.
  let interleaved = GitHub(); interleaved.fixtures = ["up/tool": upstream]
  interleaved.collectionCache[.owned] = [fork]; interleaved.holdReads = true
  let oldLookup = Task { try await interleaved.existingFork("up/tool") }
  while interleaved.readGate == nil { await Task.yield() }
  interleaved.holdReads = false
  let freshNone = try await interleaved.existingFork("up/tool", forceRefresh: true)
  precondition(freshNone == nil && interleaved.forkCheckedAt["up/tool"] != nil)
  interleaved.readGate?.resume(); interleaved.readGate = nil
  let oldResult = try await oldLookup.value
  precondition(oldResult == nil && interleaved.forkNames["up/tool"] == nil)
  // If the fresh lookup is still pending, the superseded waiter cancels rather
  // than populating the cache with its owned-cache positive.
  let pendingFresh = GitHub(); pendingFresh.fixtures = ["up/tool": upstream]
  pendingFresh.collectionCache[.owned] = [fork]; pendingFresh.holdReads = true
  let superseded = Task { try await pendingFresh.existingFork("up/tool") }
  while pendingFresh.readGate == nil { await Task.yield() }
  pendingFresh.holdReads = false; pendingFresh.holdGraph = true
  let refresh = Task { try await pendingFresh.existingFork("up/tool", forceRefresh: true) }
  while pendingFresh.graphGate == nil { await Task.yield() }
  pendingFresh.readGate?.resume(); pendingFresh.readGate = nil
  do { _ = try await superseded.value; fatalError("superseded lookup published") }
  catch is CancellationError {} catch { throw error }
  precondition(pendingFresh.forkNames.isEmpty && pendingFresh.forkCheckedAt.isEmpty)
  pendingFresh.graphGate?.resume(); pendingFresh.graphGate = nil
  let pendingResult = try await refresh.value
  precondition(pendingResult == nil && pendingFresh.forkCheckedAt["up/tool"] != nil)
  // Both successful coalesced waiters can consume the first published result.
  let coalesced = GitHub(); coalesced.fixtures = ["up/tool": upstream, "me/tool": fork]; coalesced.holdReads = true
  let waiterA = Task { try await coalesced.existingFork("up/tool") }
  while coalesced.readGate == nil { await Task.yield() }
  var waiterBStarted = false
  let waiterB = Task { waiterBStarted = true; return try await coalesced.existingFork("up/tool") }
  while !waiterBStarted { await Task.yield() }
  coalesced.holdReads = false; coalesced.readGate?.resume(); coalesced.readGate = nil
  let resultA = try await waiterA.value, resultB = try await waiterB.value
  precondition(resultA == "me/tool" && resultB == "me/tool" && coalesced.reads.count == 2)
  // A genuine accepted POST still wins over a running empty lookup.
  let postedDuringRead = GitHub(); postedDuringRead.fixtures = ["up/tool": upstream]; postedDuringRead.holdReads = true
  let emptyLookup = Task { try await postedDuringRead.existingFork("up/tool") }
  while postedDuringRead.readGate == nil { await Task.yield() }
  postedDuringRead.forkCheckedAt["up/tool"] = Date() // separately confirmed no fork
  _ = try await postedDuringRead.fork("up/tool")
  postedDuringRead.holdReads = false; postedDuringRead.readGate?.resume(); postedDuringRead.readGate = nil
  let afterPost = try await emptyLookup.value
  precondition(afterPost == "me/tool" && postedDuringRead.forkNames["up/tool"] == "me/tool" && postedDuringRead.posts == 1)
  // A same-named unrelated repository must not be claimed as a fork.
  let other = GitHub()
  other.fixtures = ["up/tool": upstream, "me/tool": Repository(full_name: "me/tool")]
  precondition(try await other.existingFork("up/tool") == nil)
  precondition(other.forkNames.isEmpty && other.graphCalls == 1)
  // Renamed fork discovery survives a fresh API/session object.
  let renamed = GitHub()
  renamed.fixtures = ["up/tool": upstream, "me/renamed": Repository(full_name: "me/renamed", fork: true, source: RepositoryReference(full_name: "up/tool"))]
  renamed.graph = #"{"data":{"root":{"forks":{"nodes":[{"nameWithOwner":"me/renamed"}]}},"target":{"forks":{"nodes":[]}}}}"#
  precondition(try await renamed.existingFork("up/tool") == "me/renamed")
  precondition(renamed.graphCalls == 1 && renamed.posts == 0)
  // A GraphQL HTTP-200 permission/error payload stays unknown, without negative cache.
  let denied = GitHub(); denied.fixtures = ["up/tool": upstream]
  denied.graph = #"{"data":null,"errors":[{"message":"Resource not accessible"}]}"#
  do { _ = try await denied.existingFork("up/tool"); fatalError("silently accepted lookup error") } catch {}
  precondition(denied.forkNames.isEmpty && denied.forkCheckedAt.isEmpty && denied.posts == 0)
  // Direct-forks filtering cannot rule out my renamed second-generation fork.
  // A/root -> B/tool -> me/renamed requires owned enumeration and detail metadata.
  let indirect = GitHub(); indirect.fixtures = ["up/tool": upstream]
  indirect.graph = #"{"data":{"root":{"forkCount":2,"direct":{"totalCount":1},"forks":{"nodes":[]}},"target":{"forks":{"nodes":[]}}}}"#
  indirect.ownedPages = [[Repository(full_name: "me/renamed", fork: true)]]
  indirect.fixtures["me/renamed"] = Repository(full_name: "me/renamed", fork: true, parent: RepositoryReference(full_name: "middle/tool"), source: RepositoryReference(full_name: "up/tool"))
  precondition(try await indirect.existingFork("up/tool") == "me/renamed")
  precondition(indirect.ownedCalls == 1 && indirect.posts == 0)
  let complete = GitHub(); complete.fixtures = ["up/tool": upstream]; complete.graph = indirect.graph
  precondition(try await complete.existingFork("up/tool") == nil)
  precondition(complete.ownedCalls == 1 && complete.forkCheckedAt["up/tool"] != nil)
  let budget = GitHub(); budget.fixtures = ["up/tool": upstream]; budget.graph = indirect.graph
  budget.ownedPages = [Array(repeating: Repository(full_name: "me/plain", fork: false), count: 100)]
  do { _ = try await budget.fork("up/tool"); fatalError("page budget allowed POST") } catch {}
  precondition(budget.ownedCalls == 3 && budget.posts == 0 && budget.forkCheckedAt.isEmpty)
  let detailBudget = GitHub(); detailBudget.fixtures = ["up/tool": upstream]; detailBudget.graph = indirect.graph
  detailBudget.ownedPages = [(1...21).map { Repository(full_name: "me/f\($0)", fork: true) }]
  for i in 1...21 { detailBudget.fixtures["me/f\(i)"] = Repository(full_name: "me/f\(i)", fork: true, source: RepositoryReference(full_name: "unrelated/root")) }
  do { _ = try await detailBudget.fork("up/tool"); fatalError("detail budget allowed POST") } catch {}
  precondition(detailBudget.reads.filter { $0.hasPrefix("me/f") }.count == 20 && detailBudget.posts == 0 && detailBudget.forkCheckedAt.isEmpty)
  let ownedDenied = GitHub(); ownedDenied.fixtures = ["up/tool": upstream]; ownedDenied.graph = indirect.graph; ownedDenied.denyOwned = true
  do { _ = try await ownedDenied.fork("up/tool"); fatalError("permission denied allowed POST") } catch {}
  precondition(ownedDenied.posts == 0 && ownedDenied.forkCheckedAt.isEmpty)
  let limited = GitHub(); limited.fixtures = ["up/tool": upstream]; limited.graph = indirect.graph; limited.denyOwned = true; limited.denyOwnedStatus = 429
  do { _ = try await limited.fork("up/tool"); fatalError("rate limit allowed POST") } catch {}
  precondition(limited.posts == 0 && limited.forkCheckedAt.isEmpty)
  let incomplete = GitHub(); incomplete.fixtures = ["up/tool": upstream, "me/incomplete": Repository(full_name: "me/incomplete", fork: true)]; incomplete.graph = indirect.graph
  incomplete.ownedPages = [[Repository(full_name: "me/incomplete", fork: true)]]
  do { _ = try await incomplete.fork("up/tool"); fatalError("incomplete metadata allowed POST") } catch {}
  precondition(incomplete.posts == 0 && incomplete.forkCheckedAt.isEmpty)
  // Only validated ownership plus parent/source metadata can seed renamed matches.
  let cached = GitHub(); cached.fixtures = ["up/tool": upstream]
  cached.collectionCache[.owned] = [Repository(full_name: "me/renamed", fork: true, parent: RepositoryReference(full_name: "UP/TOOL"))]
  precondition(try await cached.existingFork("up/tool") == "me/renamed")
  precondition(cached.reads.count == 1 && cached.graphCalls == 0)
  // Confirmation forces fresh metadata rather than trusting the owned-list positive.
  do { _ = try await cached.existingFork("up/tool", forceRefresh: true) } catch {}
  precondition(cached.graphCalls == 1 && cached.forkNames["up/tool"] == nil)
  precondition(!RepositoryForkRules.matches(Repository(full_name: "other/tool", fork: true, parent: RepositoryReference(full_name: "up/tool")), upstream: upstream, login: "me"))
  // Account switch during the network await must publish nothing.
  let stale = GitHub(); stale.fixtures = ["up/tool": upstream]; stale.switchOnRead = true
  do { _ = try await stale.existingFork("up/tool"); fatalError("accepted stale session") } catch {}
  precondition(stale.forkNames.isEmpty && stale.forkCheckedAt.isEmpty)
  let own = GitHub()
  precondition(try await own.existingFork("ME/tool") == nil && own.reads.isEmpty)
  // Accepted POST immediately records fork status without a follow-up read/poll.
  let posted = GitHub(); posted.fixtures = ["up/tool": upstream]
  _ = try await posted.fork("up/tool")
  precondition(posted.forkNames["up/tool"] == "me/tool" && posted.posts == 1 && !posted.reads.isEmpty)
  print("PASS existing, renamed, unrelated name, permission error, account switch, own repository and POST propagation; no real HTTP")
 }
}
'''
        # Swift precondition uses a non-async/non-throwing autoclosure.
        import re
        counter = 0
        def evaluated(match):
            nonlocal counter
            counter += 1
            return 'let value%d = try await %s\n  precondition(value%d%s)' % (counter, match[1], counter, match[2])
        source = re.sub(r'precondition\(try await (\w+\.existingFork\("[^"\n]+"\))(.*)\)', evaluated, source)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'Harness.swift'; path.write_text(source)
            subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', folder+'/test'], check=True)
            subprocess.run([folder+'/test'], check=True)

if __name__ == '__main__': unittest.main()
