"""Release target readiness belongs to the editor, not recyclable Form rows."""
from pathlib import Path
import shutil, subprocess, tempfile, unittest
from test_workflow_dispatch import production_method
ROOT = Path(__file__).resolve().parents[1]

class ReleaseTargetLifecycleTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_retry_and_verified_tag_match_the_original_draft_commit(self):
        api = (ROOT/'RepoPocket/GitHub.swift').read_text()
        rules = (ROOT/'RepoPocket/ReleaseManagement.swift').read_text().split('final class ReleaseAPIRedirectPolicy', 1)[0]
        plan = (ROOT/'RepoPocket/ReleasePublishPlan.swift').read_text().split('struct ReleaseAttachment:', 1)[0]
        sha = production_method((ROOT/'RepoPocket/CommitFileRules.swift').read_text(), '    static func isCommitSHA(')
        desktop = (ROOT/'RepoPocket/DesktopModels.swift').read_text()
        start = desktop.index('    static func validBranch(')
        branch = desktop[start:desktop.index('\n    }', start) + len('\n    }')]
        source = rules + plan + 'enum CommitFileRules {\n' + sha + '\n}\nenum DesktopRules {\n' + branch + '\n}\n' + r'''
struct AppError: Error { let text: String }
struct GitObject: Decodable { let sha: String }
struct GitReference: Decodable { let object: GitObject }
final class GitHub {
    let tagPath = "/git/ref/tags/build/v1"
    var records: [String: Data] = [:]
    var current: ManagedRelease!
    var targetOnWrite: String?
    var writes: [[String: Any]] = []
    func managedRelease(_ repo: String, id: Int) async throws -> ManagedRelease { current }
    func managedWriteAccess(_ repo: String) async throws {}
    func verifyManagedTagAvailable(_ repo: String, tag: String, originalID: Int?) async throws {}
    func managedLatestID(_ repo: String, refresh: Bool) async throws -> Int? { nil }
    func managedJSON<T: Decodable>(_ type: T.Type, repo: String, suffix: String, method: String = "GET", object: [String: Any]? = nil) async throws -> T {
        precondition(repo == "org/repo")
        if method == "PATCH", let object {
            precondition(suffix == "/releases/9")
            writes.append(object)
            if let targetOnWrite { try record(tagPath, type: "commit", sha: targetOnWrite) }
            let saved = ManagedRelease(id: 9, tag_name: object["tag_name"] as! String, name: nil, draft: object["draft"] as! Bool,
                                       prerelease: false, created_at: "", published_at: nil, updated_at: nil, body: nil,
                                       target_commitish: object["target_commitish"] as? String ?? current.target_commitish)
            return saved as! T
        }
        precondition(method == "GET")
        guard let bytes = records[suffix] else { throw ManagedReleaseHTTPError(status: 404, tagAlreadyExists: false) }
        return try JSONDecoder().decode(type, from: bytes)
    }
    func record(_ path: String, type: String, sha: String) throws {
        records[path] = try JSONSerialization.data(withJSONObject: ["object": ["sha": sha, "type": type]])
    }
''' + '\n'.join(production_method(api, signature) for signature in (
            '    static func filePath(', '    static func component(', '    func managedTargetHead(',
            '    func verifyManagedTarget(', '    func saveManagedRelease(')) + r'''
}
@main struct Run {
    static func main() async throws {
        let github = GitHub(), a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
        let annotation = String(repeating: "c", count: 40)
        var plan = ReleasePublishPlan()
        plan.begin(); plan.created(9, targetSHA: a); plan.fail(); plan.begin()
        let head = plan.targetSHA!
        precondition(head == a && head != b)
        func release(draft: Bool, target: String) -> ManagedRelease {
            ManagedRelease(id: 9, tag_name: "build/v1", name: nil, draft: draft, prerelease: false,
                           created_at: "", published_at: nil, updated_at: nil, body: nil, target_commitish: target)
        }
        func verify(_ release: ManagedRelease?, expectSuccess: Bool) async {
            do {
                try await github.verifyManagedTarget("org/repo", tag: "build/v1", expected: head, release: release)
                precondition(expectSuccess)
            } catch { precondition(!expectSuccess, error.localizedDescription) }
        }
        await verify(nil, expectSuccess: true)
        await verify(release(draft: true, target: a), expectSuccess: true)
        await verify(release(draft: true, target: b), expectSuccess: false)
        await verify(release(draft: false, target: a), expectSuccess: false)
        try github.record(github.tagPath, type: "commit", sha: b)
        await verify(release(draft: false, target: a), expectSuccess: false)
        try github.record(github.tagPath, type: "tag", sha: annotation)
        try github.record("/git/tags/" + annotation, type: "commit", sha: a)
        await verify(release(draft: false, target: a), expectSuccess: true)
        try github.record("/git/tags/" + annotation, type: "tag", sha: annotation)
        await verify(release(draft: false, target: a), expectSuccess: false)

        let branch = "release/next", repo = "org/repo"
        github.records["/git/commits/" + a] = try JSONSerialization.data(withJSONObject: ["sha": a])
        let pinned = try await github.managedTargetHead(repo, target: a)
        precondition(pinned == a)
        try github.record("/git/ref/heads/" + branch, type: "commit", sha: a)
        github.current = release(draft: true, target: branch)
        var form = ReleaseForm(github.current); form.draft = false
        form.branch = try await github.managedTargetHead(repo, target: github.current.target_commitish!)
        try github.record("/git/ref/heads/" + branch, type: "commit", sha: b)
        let moved = try await github.managedTargetHead(repo, target: branch)
        precondition(form.branch == a && moved != form.branch)

        try github.record(github.tagPath, type: "commit", sha: b)
        do { _ = try await github.saveManagedRelease(repo, original: github.current, form: form); preconditionFailure() }
        catch { precondition(github.writes.isEmpty) }
        github.records[github.tagPath] = nil
        github.targetOnWrite = b
        do { _ = try await github.saveManagedRelease(repo, original: github.current, form: form); preconditionFailure() }
        catch { precondition(github.writes.count == 1 && github.writes.last?["target_commitish"] as? String == a) }
        github.records[github.tagPath] = nil
        github.targetOnWrite = a
        let saved = try await github.saveManagedRelease(repo, original: github.current, form: form)
        precondition(!saved.draft && saved.target_commitish == a && github.writes.count == 2)

        github.current = release(draft: false, target: branch)
        github.records[github.tagPath] = nil; github.targetOnWrite = nil
        var metadata = ReleaseForm(github.current); metadata.title = "edited"
        _ = try await github.saveManagedRelease(repo, original: github.current, form: metadata)
        precondition(github.writes.count == 3 && github.writes.last?["target_commitish"] == nil)
    }
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'VerifyTarget.swift'
            path.write_text(source)
            binary = str(Path(folder) / 'verify')
            subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', binary], check=True, timeout=90)
            subprocess.run([binary], check=True, timeout=30)
        ui = (ROOT/'RepoPocket/ReleaseManagementUI.swift').read_text()
        self.assertIn('if let retained = plan.targetSHA {\n                    reviewHead = retained', ui)
        self.assertIn('original?.draft == true && !form.draft', ui)
        self.assertIn('original?.target_commitish ?? form.branch', ui)
        self.assertIn('if original == nil || publishingExistingDraft', production_method(ui, '    private func fingerprint('))
        operation = production_method(ui, '    private func performConfirmedRelease(')
        self.assertLess(operation.index('fingerprint() == authorized'), operation.index('captured.branch = reviewHead'))
        self.assertIn('else if original == nil || publishingExistingDraft', operation)
        self.assertLess(operation.index('captured.branch = reviewHead'), operation.index('saveManagedRelease'))
        publish = production_method(ui, '    private func publishAttachments(')
        self.assertLess(publish.index('saveManagedRelease(state.repo, original: current'), publish.index('plan.finish()'))

    def test_editor_owns_target_readiness_and_teardown(self):
        source=(ROOT/'RepoPocket/ReleaseManagementUI.swift').read_text()
        editor=source.split('struct ReleaseEditorView: View {',1)[1].split('@MainActor @ViewBuilder private func releaseStatus',1)[0]
        self.assertIn('@StateObject private var targetState = ReleaseBranchState()',editor)
        self.assertIn('private var targetReady: Bool { state.valid && targetState.ready }',editor)
        self.assertIn('state: targetState, selected: $form.branch',editor)
        self.assertIn('targetState.cancel()',editor)
        picker=(ROOT/'RepoPocket/ReleaseBranchPicker.swift').read_text().split('struct ReleaseBranchPicker: View {',1)[1]
        self.assertIn('@ObservedObject var state: ReleaseBranchState',picker)
        self.assertNotIn('.onDisappear',picker)
        self.assertNotIn('.task {',picker)
        self.assertNotIn('@Binding var ready',picker)
        self.assertIn('guard targetReady, !attachments.isEmpty',editor)

    @unittest.skipUnless(shutil.which('swiftc'),'Native Swift lifecycle fixture runs on macOS')
    def test_production_target_state_permissions_cancellation_and_account_change(self):
        state=(ROOT/'RepoPocket/ReleaseBranchPicker.swift').read_text().split('struct ReleaseBranchPicker: View {',1)[0]
        source=r'''
import Foundation
import SwiftUI
struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
enum AccountStore { static var generation = UUID() }
enum RefreshFailure { static func isCancellation(_ e: Error)->Bool { e is CancellationError } }
enum ReleaseManagementRules {
 static func canWrite(_ push: Bool?, session: Bool)->Bool { push == true && session }
}
struct Repo { struct Permissions { let push: Bool? }; let permissions: Permissions?; let default_branch: String? }
struct Branch { let name: String }
struct Commit { let sha: String }
@MainActor final class GitHub {
 var isCurrentSession = true; var push: Bool? = true; var requests = 0
 var pages = [["main","test"]]; var started = false; var gate: CheckedContinuation<Void,Never>?
 var suspended = false
 func managedRepository(_ repo: String) async throws -> Repo {
  requests += 1
  if suspended { started = true; await withCheckedContinuation { gate = $0 } }
  return Repo(permissions:.init(push:push),default_branch:"main")
 }
 func branches(_ repo:String,page:Int) async throws -> [Branch] { (pages.indices.contains(page-1) ? pages[page-1] : []).map { Branch(name:$0) } }
 func requireWriteAccess(_ repo:String) async throws { guard push == true && isCurrentSession else { throw AppError(text:"no write") } }
 func commitDetail(_ repo:String,sha:String,page:Int) async throws -> Commit { Commit(sha:sha) }
}
'''+state+r'''
@main struct Run {
 @MainActor static func settle(_ state:ReleaseBranchState) async throws {
  for _ in 0..<10000 { if !state.loading { return }; await Task.yield() }
  throw AppError(text:"state did not settle")
 }
 @MainActor static func main() async throws {
  var selected=""; let binding=Binding(get:{selected},set:{selected=$0})
  let api=GitHub(), state=ReleaseBranchState()
  state.load(api:api,repo:"owner/repo",preferred:"",selected:binding)
  try await settle(state); precondition(state.ready && selected == "main")
  // Row visibility is not an invalidation event: there is no call to cancel here.
  await Task.yield(); precondition(state.ready && selected == "main" && api.requests == 1)
  state.cancel(); precondition(!state.ready)
  state.load(api:api,repo:"owner/repo",preferred:"test",selected:binding)
  try await settle(state); precondition(state.ready && selected == "test")
  state.verify(api:api,repo:"owner/repo",sha:String(repeating:"a",count:40),selected:binding)
  try await settle(state); precondition(state.ready && selected == String(repeating:"a",count:40))
  let denied=GitHub(); denied.push=false
  state.load(api:denied,repo:"owner/repo",preferred:"main",selected:binding)
  try await settle(state); precondition(!state.ready && !state.error.isEmpty)
  let pending=GitHub(); pending.suspended=true
  state.load(api:pending,repo:"owner/repo",preferred:"main",selected:binding)
  for _ in 0..<10000 { if pending.started { break }; await Task.yield() }
  precondition(pending.started); state.cancel(); pending.gate?.resume(); pending.gate=nil
  try await settle(state); await Task.yield(); precondition(!state.ready)
  let changed=ReleaseBranchState(); AccountStore.generation=UUID()
  changed.load(api:api,repo:"owner/repo",preferred:"main",selected:binding)
  try await settle(changed); precondition(!changed.ready)
  print("PASS production target readiness, permission refusal, explicit cancellation and account isolation")
 }
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'Target.swift';path.write_text(source)
            subprocess.run(['swiftc','-parse-as-library',str(path),'-o',tmp+'/target'],check=True)
            subprocess.run([tmp+'/target'],check=True,timeout=30)

if __name__=='__main__':unittest.main()
