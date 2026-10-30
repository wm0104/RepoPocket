"""Scheduling and selection behavior of the actual page-owned state."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LocalGitUITests(unittest.TestCase):
    def test_current_project_exposes_file_import_and_bulk_selection(self):
        page = (ROOT / 'RepoPocket/LocalProjectView.swift').read_text(encoding='utf-8')
        for label in ['导入文件', '导入文件夹', '全选', '取消全选']:
            self.assertTrue(label in page, 'Missing local Git action: ' + label)

    def test_pull_result_is_separate_from_uncommitted_workspace_changes(self):
        page = (ROOT/'RepoPocket/LocalProjectView.swift').read_text(encoding='utf-8')
        self.assertIn('if let pullSummary { pullResultSection(pullSummary) }', page)
        summary = page.split('    private func pullResultSection(', 1)[1].split('    private func changesSection(', 1)[0]
        for text in ['Section("本次拉取结果")', 'SoftGroupRows(animateBackground: false)',
                     '远端没有新提交', 'summary.commits', 'summary.added', 'summary.modified',
                     'summary.deleted', 'summary.totalFiles', 'summary.files.prefix(1000)',
                     'if pullFilesExpanded', 'summary.truncated', 'UIRules.withoutAnimation']:
            self.assertIn(text, summary)
        for unwanted in ['LocalGitEngine', 'state.snapshot', 'state.selected', '.task', '.onAppear', 'Task {']:
            self.assertNotIn(unwanted, summary, 'Pull disclosure must only render the completed pull reply')
        sync = page.split('    private func sync(', 1)[1].split('\n}\n', 1)[0]
        self.assertIn('if action == "pull" { pullSummary = nil; pullFilesExpanded = false }', sync)
        self.assertIn('if action == "pull" { pullSummary = reply.pullSummary }', sync)
        self.assertLess(sync.index('Task.checkCancellation()'), sync.index('pullSummary = reply.pullSummary'))
        self.assertLess(sync.index('guard valid else'), sync.index('pullSummary = reply.pullSummary'))

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift production pull-summary decoding regression runs on macOS')
    def test_pull_summary_decodes_legacy_noop_and_fast_forward_replies(self):
        fixture = r'''
import Foundation
@main struct PullSummaryFixture {
 static func reply(_ value: String) throws -> LocalGitReply {
  try JSONDecoder().decode(LocalGitReply.self, from: Data(value.utf8))
 }
 static func main() throws {
  let empty = try reply("{}"), legacy = try reply(#"{"commit":"old","head":"head"}"#)
  precondition(empty.pullSummary == nil && legacy.pullSummary == nil)
  precondition(LocalGitReply(commit:nil,head:"legacy fixture").pullSummary == nil)
  let noop = try reply(#"{"head":"same","pullSummary":{"commits":0,"files":[],"totalFiles":0,"added":0,"modified":0,"deleted":0,"truncated":false}}"#).pullSummary!
  precondition(noop.commits == 0 && noop.files.isEmpty && noop.totalFiles == 0)
  precondition(noop.added == 0 && noop.modified == 0 && noop.deleted == 0 && !noop.truncated)
  let changed = try reply(#"{"head":"new","pullSummary":{"commits":2,"files":[{"path":"新增.txt","kind":"added"},{"path":"src/main.swift","kind":"modified"},{"path":"old.txt","kind":"deleted"}],"totalFiles":3,"added":1,"modified":1,"deleted":1,"truncated":false}}"#).pullSummary!
  precondition(changed.commits == 2 && changed.totalFiles == 3 && changed.files.count == 3)
  precondition(changed.added == 1 && changed.modified == 1 && changed.deleted == 1)
  precondition(changed.files.map(\.label) == ["新增","修改","删除"])
  precondition(changed.files.map(\.id) == ["新增.txt","src/main.swift","old.txt"])
  let limited = try reply(#"{"pullSummary":{"commits":4,"files":[{"path":"one.txt","kind":"added"}],"totalFiles":1001,"added":1001,"modified":0,"deleted":0,"truncated":true}}"#).pullSummary!
  precondition(limited.truncated && limited.totalFiles > limited.files.count)
  print("PASS production pull summary: backward-compatible replies, zero updates, fast-forward counts and bounded file-list metadata")
 }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory)/'PullSummaryFixture.swift'
            file.write_text(fixture, encoding='utf-8')
            output = str(Path(directory)/'check')
            subprocess.run(['swiftc', '-parse-as-library', str(ROOT/'RepoPocket/ChinaDate.swift'),
                            str(ROOT/'RepoPocket/LocalGitModels.swift'), str(file), '-o', output], check=True)
            subprocess.run([output], check=True)

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
        self.assertFalse((ROOT/'RepoPocket/GitWorkspaceView.swift').exists())
        for path in (ROOT/'RepoPocket').glob('*.swift'):
            self.assertNotIn('GitWorkspaceView', path.read_text(encoding='utf-8'), path.name)
        for path in (ROOT/'RepoPocket').glob('LocalProject*.swift'):
            source = path.read_text(encoding='utf-8')
            self.assertNotIn('.swipeActions', source)
            self.assertNotIn('Timer.', source)
            self.assertNotIn('WorkspaceStore', source)

    def test_repository_picker_reuses_group_rows_without_changing_lifecycle(self):
        page = (ROOT/'RepoPocket/LocalGitPickers.swift').read_text(encoding='utf-8')
        page = page.split('struct LocalGitBranchPicker:', 1)[0]
        group = page.split('Section("当前账号可访问的仓库") {', 1)[1].split('if busy { ProgressView', 1)[0]
        for text in ['let matches = visible', 'SoftGroupRows {', 'for repository in matches',
                     'SoftGroupRow("repository:" + String(repository.id))', 'SoftGroupRow("empty")',
                     'if matches.isEmpty && !busy && failure.isEmpty',
                     'query.isEmpty ? "暂无可访问仓库" : "没有匹配的仓库"',
                     'Button { select(repository); dismiss() }', 'repository.private == true',
                     'repository.default_branch']:
            self.assertIn(text, page)
        self.assertNotIn('.softGroupedRow(', group)
        self.assertNotIn('visible.first', page)
        self.assertNotIn('visible.last', page)
        for text in ['localizedCaseInsensitiveContains(query)', '.searchable(text: $query',
                     '.refreshable { await load() }', 'guard !attempted else',
                     'Button("重试") { Task { await load() } }',
                     'guard !busy, api.isCurrentSession else', 'api.cachedCollection(.owned)',
                     'Task.checkCancellation()', 'guard api.isCurrentSession else',
                     '!RefreshFailure.isCancellation(error)']:
            self.assertIn(text, page)

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
  let files = (1...44).map { LocalGitChange(path:"debs/package-\($0).deb",kind:"added",fingerprint:"x",blocked:"") }
  let nested = LocalGitChange(path:"debs/nested/代码.py",kind:"added",fingerprint:"y",blocked:"")
  let rootFile = LocalGitChange(path:"README.md",kind:"modified",fingerprint:"z",blocked:"")
  let collapsed = LocalGitChangeTree.rows(files+[nested,rootFile,blocked],expanded:[])
  precondition(collapsed.count==3 && collapsed[0].folder && collapsed[0].name=="debs")
  precondition(collapsed[0].files.count==45 && collapsed[0].selectable.count==45)
  let expanded = LocalGitChangeTree.rows(files+[nested,rootFile],expanded:["debs"])
  precondition(expanded.filter{$0.depth==1}.count==45)
  precondition(expanded.contains{$0.path=="debs/nested" && $0.folder})
  let migrated = LocalGitChange(path:"debs",kind:"deleted",fingerprint:"missing",blocked:"")
  let transition = LocalGitChangeTree.rows([migrated,nested],expanded:["debs","debs/nested"])
  precondition(transition.count==4 && Set(transition.map(\.id)).count==4)
  let bulk=LocalProjectState()
  await bulk.check(valid:{true}) {LocalGitSnapshot(status:LocalGitStatus(head:status.head,branch:"main",reference:status.reference,files:files+[blocked],staged:[],repoState:0),history:history)}
  bulk.selectAll();precondition(bulk.selected.count==44 && !bulk.selected.contains(blocked.path))
  bulk.toggleSelection(Set(files.map(\.path)));precondition(bulk.selected.isEmpty)
  bulk.toggleSelection(Set(files.map(\.path)));precondition(bulk.selected.count==44)
  print("PASS twenty appearances, empty result, coalesced requests, cancelled selection and account invalidation")
 }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory)/'Fixture.swift'
            file.write_text(fixture, encoding='utf-8')
            output = str(Path(directory)/'check')
            subprocess.run(['swiftc','-parse-as-library',str(ROOT/'RepoPocket/ChinaDate.swift'),str(ROOT/'RepoPocket/LocalGitModels.swift'),str(ROOT/'RepoPocket/LocalProjectState.swift'),str(file),'-o',output],check=True)
            subprocess.run([output],check=True)


if __name__ == '__main__':
    unittest.main()
