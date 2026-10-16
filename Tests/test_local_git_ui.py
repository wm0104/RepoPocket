"""Scheduling and selection behavior of the actual page-owned state."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LocalGitUITests(unittest.TestCase):
    def test_import_uses_repository_default_branch_when_unspecified(self):
        page = (ROOT/'RepoPocket/LocalProjectImportView.swift').read_text(encoding='utf-8')
        self.assertIn('@State private var branch = ""', page)
        self.assertIn('分支（留空使用仓库默认分支）', page)
        clone = page.split('if clone {\n                    let url', 1)[1].split('let exists =', 1)[0]
        self.assertIn('api.resolvedBranch(name, branch: branch.trimmingCharacters(in: .whitespacesAndNewlines))', clone)
        self.assertIn('branch: selectedBranch', clone)
        association = page.split('if folder.usesPrivateGit && !exists {', 1)[1].split('} else {', 1)[0]
        self.assertIn('api.resolvedBranch(name, branch: branch.trimmingCharacters(in: .whitespacesAndNewlines))', association)
        self.assertIn('workspaceHead(name, branch: selectedBranch)', association)
        self.assertIn('"branch":selectedBranch', association)

    def test_folder_result_is_consumed_before_picker_dismissal(self):
        page = (ROOT/'RepoPocket/LocalProjectImportView.swift').read_text(encoding='utf-8')
        # Files may close its own presentation. The picked URL must be consumed
        # by the delegate callback, while access is valid, without onDismiss.
        self.assertNotIn('onDismiss: acceptPicker', page)
        self.assertNotIn('@State private var pickedURL', page)
        callback = page.split('WorkspaceDocumentPicker(request: request, allowsMultipleSelection: false)', 1)[1].split('.id(request.id)', 1)[0]
        self.assertIn('acceptPicker(url)', callback)
        self.assertLess(callback.index('acceptPicker(url)'), callback.index('picker = nil'))
        self.assertIn('.id(request.id)', page)

    def test_new_pages_keep_old_workspace_disconnected(self):
        for name in ['LocalProjectsView.swift', 'LocalProjectView.swift', 'LocalProjectEditor.swift', 'LocalProjectImportView.swift', 'LocalProjectState.swift']:
            self.assertTrue((ROOT/'RepoPocket'/name).exists(), 'Missing page: ' + name)
        app = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text(encoding='utf-8')
        self.assertIn('LocalProjectsView(api: api, store: localGit)', app)
        self.assertNotIn('GitWorkspaceView().environmentObject', app)
        for path in (ROOT/'RepoPocket').glob('LocalProject*.swift'):
            source = path.read_text(encoding='utf-8')
            self.assertNotIn('.swipeActions', source)
            self.assertNotIn('Timer.', source)
            self.assertNotIn('WorkspaceStore', source)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift runs scheduling fixture on macOS')
    def test_empty_results_coalesce_scroll_and_cancellation_preserves_selection(self):
        fixture = r'''
import Foundation
@main struct Fixture {
 @MainActor static func main() async throws {
  let status=LocalGitStatus(head:String(repeating:"a",count:40),branch:"main",reference:"refs/heads/main",files:[],staged:[],repoState:0)
  let history=LocalGitHistory(commits:[],ahead:0,behind:0,tracking:true,remote:"https://github.com/fixture/repo.git")
  let snapshot=LocalGitSnapshot(status:status,history:history)
  let state=LocalProjectState();var requests=0
  for _ in 0..<20 {await state.check(valid:{true}) {requests+=1;return snapshot}}
  precondition(requests==1 && state.fresh)
  state.cancel()
  await state.check(valid:{true}) {requests+=1;return snapshot}
  precondition(state.fresh && requests==1, "Read-only navigation must preserve a completed check")
  state.selected=["keep.py"]
  await state.check(force:true,valid:{true}) {throw LocalGitError(text:"fixture failure")}
  precondition(state.selected==["keep.py"] && !state.fresh && !state.error.isEmpty)
  await state.check(force:true,valid:{false}) {requests+=1;return snapshot}
  precondition(requests==1)
  state.cancel();precondition(state.selected==["keep.py"])
  let another=LocalProjectState();var valid=true;var loads=0
  let first=Task {await another.check(valid:{valid}) {loads+=1;try await Task.sleep(nanoseconds:20_000_000);return snapshot}}
  await Task.yield()
  let second=Task {await another.check(valid:{valid}) {loads+=1;return snapshot}}
  await first.value;await second.value;precondition(loads==1)
  valid=false
  await another.check(force:true,valid:{valid}) {preconditionFailure("old account loaded")}
  let invalidated=LocalProjectState();var session=true
  let pending=Task {await invalidated.check(valid:{session}) {try await Task.sleep(nanoseconds:20_000_000);return snapshot}}
  await Task.yield();session=false;await pending.value
  precondition(!invalidated.busy && !invalidated.fresh && invalidated.snapshot==nil)
  let cancelled=LocalProjectState();var retried=0
  let interrupted=Task {await cancelled.check(valid:{true}) {try await Task.sleep(nanoseconds:100_000_000);return snapshot}}
  await Task.yield();cancelled.cancel();await interrupted.value
  await cancelled.check(valid:{true}) {retried+=1;return snapshot}
  precondition(cancelled.fresh && retried==1, "A cancelled check must be retryable on return")
  let changed=LocalProjectState();var scans=0
  let old=Task {await changed.check(valid:{true}) {scans+=1;try await Task.sleep(nanoseconds:40_000_000);return snapshot}}
  await Task.yield();changed.filesChanged()
  await changed.check(force:true,valid:{true}) {scans+=1;return snapshot}
  await old.value
  precondition(changed.fresh && scans==2, "A save during an older scan requires one subsequent scan")
  let blocked=LocalGitChange(path:"blocked.py",kind:"modified",fingerprint:"x",blocked:"unsupported")
  let blockedStatus=LocalGitStatus(head:status.head,branch:"main",reference:status.reference,files:[blocked],staged:[],repoState:0)
  changed.selected=["blocked.py"]
  await changed.check(force:true,valid:{true}) {LocalGitSnapshot(status:blockedStatus,history:history)}
  precondition(changed.selected.isEmpty, "Newly unsupported files cannot remain selected for commit")
  print("PASS twenty appearances, empty result, coalesced requests, cancelled selection and account invalidation")
 }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory)/'Fixture.swift'
            file.write_text(fixture, encoding='utf-8')
            output = str(Path(directory)/'check')
            subprocess.run(['swiftc','-parse-as-library',str(ROOT/'RepoPocket/LocalGitModels.swift'),str(ROOT/'RepoPocket/LocalProjectState.swift'),str(file),'-o',output],check=True)
            subprocess.run([output],check=True)


if __name__ == '__main__':
    unittest.main()
