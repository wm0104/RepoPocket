"""Release target readiness belongs to the editor, not recyclable Form rows."""
from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]

class ReleaseTargetLifecycleTests(unittest.TestCase):
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
