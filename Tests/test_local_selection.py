from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import subprocess, tempfile
w=Path(REPO_ROOT, 'RepoPocket/WorkspaceView.swift').read_text()
core=w[w.index('struct LocalSnapshot:'):w.index('\nstruct WorkspaceView:')]
r=Path(REPO_ROOT, 'RepoPocket/WorkspaceRemote.swift').read_text().replace('import Foundation','').replace('import CryptoKit','')
s=Path(REPO_ROOT, 'RepoPocket/WorkspaceSelection.swift').read_text()
tests=r'''
let fm=FileManager.default
let root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at:root,withIntermediateDirectories:true)
defer { try? fm.removeItem(at:root); try? fm.removeItem(at:LocalStore.metadata(root)); try? fm.removeItem(at:LocalStore.bindingURL(root)) }
try Data("old".utf8).write(to:root.appendingPathComponent("modified"))
try Data("gone".utf8).write(to:root.appendingPathComponent("deleted"))
let baseline=try LocalStore.snapshot(root)
try JSONEncoder().encode(baseline).write(to:LocalStore.metadata(root))
try Data("new".utf8).write(to:root.appendingPathComponent("modified"))
try Data("added".utf8).write(to:root.appendingPathComponent("added"))
try fm.removeItem(at:root.appendingPathComponent("deleted"))
let changes=try LocalStore.changes([root])
precondition(Set(changes.map{$0.kind}) == ["新增","修改","删除"])
let paths=Set(changes.map{$0.path})
let local=WorkspaceSelectionScope(accountID:"a",folder:root,repository:"",branch:"")
let remote=WorkspaceSelectionScope(accountID:"a",folder:root,repository:"o/r",branch:"main")
var session=WorkspaceSelectionSession()
for path in paths {session.toggle(path,in:local)}
session.scanSucceeded(Set(try LocalStore.changes([root]).map{$0.path}),in:local)
precondition(session.selected(in:local)==paths)
let current=try LocalStore.snapshot(root)
precondition(WorkspaceCommitEligibility.reason(binding:nil,selected:paths,scanned:current,sameWorkspace:true,message:"edit") != nil)
let binding=WorkspaceBinding(repo:"o/r",branch:"main",head:"h",tree:"t",modes:[:],snapshot:baseline)
try LocalStore.saveBinding(binding,folder:root)
session.associateLocalSelection(from:local,to:remote)
session.scanSucceeded(Set(try LocalStore.changes([root]).map{$0.path}),in:remote)
precondition(session.selected(in:remote)==paths && session.selected(in:local).isEmpty)
precondition(WorkspaceCommitEligibility.reason(binding:binding,selected:paths,scanned:current,sameWorkspace:true,message:"edit") == nil)
precondition(WorkspaceCommitEligibility.reason(binding:binding,selected:paths,scanned:current,sameWorkspace:false,message:"edit") != nil)
let writes=try LocalStore.prepare(root,paths:Set(changes.map{$0.relativePath}),expected:current)
precondition(writes.count==3 && writes.first{$0.path=="deleted"}?.bytes == nil)
// Remote HEAD movement is not part of selection identity; branch/repo/account are.
var advanced=binding; advanced.head="h2"
try LocalStore.saveBinding(advanced,folder:root)
session.scanSucceeded(Set(try LocalStore.changes([root]).map{$0.path}),in:remote)
precondition(session.selected(in:remote)==paths)
for other in [WorkspaceSelectionScope(accountID:"b",folder:root,repository:"o/r",branch:"main"),WorkspaceSelectionScope(accountID:"a",folder:root,repository:"o/r",branch:"feature"),WorkspaceSelectionScope(accountID:"a",folder:root,repository:"o/other",branch:"main")] {
 session.associateLocalSelection(from:remote,to:other)
 precondition(session.selected(in:other).isEmpty)
}
// Remote-downloaded binding path keeps selectable deleted items, even after refresh.
let deleted=changes.first{$0.kind=="删除"}!.path
session.toggle(deleted,in:remote); session.toggle(deleted,in:remote)
session.scanSucceeded(paths,in:remote)
precondition(session.selected(in:remote).contains(deleted))
let legacy=try JSONDecoder().decode(LocalSnapshot.self,from:Data("{\"hashes\":{\"gone\":\"hash\"}}".utf8))
precondition(legacy.texts.isEmpty && legacy.hashes["gone"]=="hash")
do { _=try JSONDecoder().decode(LocalSnapshot.self,from:Data("{\"texts\":{}}".utf8)); preconditionFailure("missing hashes accepted") } catch {}

// Physical readable rename keeps disk binding, baseline, current changes and selections.
let imported=try LocalStore.importFolder(root,name:"owner-repo")
defer {try? fm.removeItem(at:imported); try? fm.removeItem(at:LocalStore.metadata(imported)); try? fm.removeItem(at:LocalStore.bindingURL(imported))}
try JSONEncoder().encode(baseline).write(to:LocalStore.metadata(imported))
try LocalStore.saveBinding(binding,folder:imported)
let oldScope=WorkspaceSelectionScope(accountID:"a",folder:imported,repository:"o/r",branch:"main")
for c in try LocalStore.changes([imported]) {session.toggle(c.path,in:oldScope)}
session.remember(imported,accountID:"a")
let renamed=try LocalStore.renameWorkspace(imported,to:"owner-repo")
defer {try? fm.removeItem(at:renamed); try? fm.removeItem(at:LocalStore.metadata(renamed)); try? fm.removeItem(at:LocalStore.bindingURL(renamed))}
precondition(renamed.lastPathComponent=="owner-repo-2")
session.workspaceRenamed(from:imported,to:renamed)
let newScope=WorkspaceSelectionScope(accountID:"a",folder:renamed,repository:"o/r",branch:"main")
let renameChanges=try LocalStore.changes([renamed])
precondition(Set(renameChanges.map{$0.kind})==["新增","修改","删除"])
precondition(session.selected(in:newScope)==Set(renameChanges.map{$0.path}))
let renamedBinding=try LocalStore.binding(renamed)
precondition(renamedBinding.head==binding.head && session.rememberedFolder(accountID:"a")==renamed)
let bad=try LocalStore.root().appendingPathComponent("rename-failure-"+UUID().uuidString)
try fm.createDirectory(at:bad,withIntermediateDirectories:true)
defer {try? fm.removeItem(at:bad)}
do {_=try LocalStore.renameWorkspace(bad,to:"rollback-fixture");preconditionFailure("missing metadata accepted")}catch{}
precondition(fm.fileExists(atPath:bad.path))
print("PASS physical readable naming, numbered duplicate, metadata+binding+selection rename and rollback")
print("PASS production Swift local add/modify/delete scan, unbound selection, blocked commit, verified association, bound deletion, remote drift, isolation and legacy schema")
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'test.swift'
 p.write_text('import Foundation\nimport CryptoKit\nstruct AppError: LocalizedError { let text:String; var errorDescription:String? {text} }\n'+core+r+s+tests)
 subprocess.run(['swift',str(p)],check=True)
row=w.split('ForEach(changes) { change in',1)[1].split('Button("刷新变更")',1)[0]
assert '.buttonStyle(.plain)' in row and '.frame(width: 44, height: 44).contentShape(Rectangle())' in row
assert '.disabled(busy || binding == nil)' not in row
assert 'HStack {' in row and 'NavigationLink { LocalDiffView' in row
commit=w.split('@MainActor private func commit()',1)[1].split('@MainActor private func scan()',1)[0]
assert 'commitBlockReason == nil' in commit and 'persisted.snapshot.hashes == binding.snapshot.hashes' in commit
assert 'LocalStore.prepare' in commit
api=Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text()
assert '"force": false' in api and '提交准备期间远端已变化' in api
print('PASS independent checkbox static hit area and strict production submit contracts; device hit testing not measured')
