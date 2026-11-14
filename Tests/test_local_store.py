import subprocess, tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
source = Path(REPO_ROOT, 'RepoPocket/WorkspaceView.swift').read_text()
core = source[source.index('struct LocalSnapshot:'):source.index('\nstruct WorkspaceView:')]
remote = Path(REPO_ROOT, 'RepoPocket/WorkspaceRemote.swift').read_text().replace('import Foundation','').replace('import CryptoKit','')
tests = r'''
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root); try? fm.removeItem(at: LocalStore.metadata(root)); try? fm.removeItem(at: LocalStore.bindingURL(root)) }
func put(_ p: String, _ text: String) throws {
 let u = root.appendingPathComponent(p)
 try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
 try Data(text.utf8).write(to: u)
}
try put("a.txt", "abc")
try put("gone.txt", "deleted")
try put(".github/ci.yml", "hidden")
try put(".git/config", "ignored")
let first = try LocalStore.snapshot(root)
precondition(first.hashes["a.txt"] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
precondition(first.hashes[".github/ci.yml"] != nil && first.hashes[".git/config"] == nil)
try JSONEncoder().encode(first).write(to: LocalStore.metadata(root), options: .atomic)
try put("a.txt", "changed")
try put("new.txt", "added")
try fm.removeItem(at: root.appendingPathComponent("gone.txt"))
let c = try LocalStore.changes([root])
precondition(c.count == 3)
precondition(c.contains { $0.kind == "新增" } && c.contains { $0.kind == "删除" } && c.contains { $0.kind == "修改" })
var binding = WorkspaceBinding(repo: "test/test", branch: "main", head: "h1", tree: "t1", modes: [:], snapshot: first)
let current = try LocalStore.snapshot(root)
try LocalStore.finish(root, binding: binding, snapshot: current, paths: ["a.txt"])
let partial = try LocalStore.binding(root)
precondition(partial.snapshot.hashes["a.txt"] == current.hashes["a.txt"])
precondition(partial.snapshot.hashes["gone.txt"] == first.hashes["gone.txt"] && partial.snapshot.hashes["new.txt"] == nil)
try Data(repeating: 65, count: 11 * 1024 * 1024).write(to: root.appendingPathComponent("big.bin"))
let big = try LocalStore.snapshot(root)
precondition(big.hashes["big.bin"] != nil && big.texts["big.bin"] == nil)
var refused = false
do { _ = try LocalStore.prepare(root, paths: ["big.bin"], expected: big) } catch { refused = true }
precondition(refused)
for path in ["../escape", "/absolute", "a//b", "a\\b", "a/./b"] {
 refused = false
 do { _ = try LocalStore.prepare(root, paths: [path], expected: big) } catch { refused = true }
 precondition(refused, path)
}
try fm.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/etc/passwd")
refused = false
do { _ = try LocalStore.snapshot(root) } catch { refused = true }
precondition(refused)
try fm.removeItem(at: root.appendingPathComponent("link"))
// Exhaustive three-way presence/content matrix: absent, value A, value B.
let values: [String?] = [nil, "A", "B"]
var matrixCount = 0
for b in values { for l in values { for r in values {
 var base = LocalSnapshot(); var local = LocalSnapshot(); var remote = LocalSnapshot()
 base.hashes["file"] = b; local.hashes["file"] = l; remote.hashes["file"] = r
 let conflict = l != b && r != b && l != r
 precondition(!WorkspaceMerge.conflicts(base: base, local: local, remote: remote).isEmpty == conflict)
 if conflict {
  precondition(WorkspaceMerge.remotePaths(base: base, local: local, remote: remote, choices: ["file": false]).isEmpty)
  precondition(WorkspaceMerge.remotePaths(base: base, local: local, remote: remote, choices: ["file": true]) == ["file"])
 } else {
  precondition(WorkspaceMerge.remotePaths(base: base, local: local, remote: remote, choices: [:]).contains("file") == (l == b && (b != nil || l != nil || r != nil)))
 }
 matrixCount += 1
}}}
// Real filesystem pull: preserve edited local file while applying remote addition/deletion.
let checkout = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let downloaded = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
try fm.createDirectory(at: downloaded, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: checkout); try? fm.removeItem(at: downloaded); try? fm.removeItem(at: LocalStore.bindingURL(checkout)) }
try Data("old".utf8).write(to: checkout.appendingPathComponent("local"))
try Data("remove".utf8).write(to: checkout.appendingPathComponent("gone"))
binding.snapshot = try LocalStore.snapshot(checkout)
try LocalStore.saveBinding(binding, folder: checkout)
try Data("edit".utf8).write(to: checkout.appendingPathComponent("local"))
try Data("old".utf8).write(to: downloaded.appendingPathComponent("local"))
try Data("new".utf8).write(to: downloaded.appendingPathComponent("added"))
var latest = binding; latest.head = "h2"; latest.snapshot = try LocalStore.snapshot(downloaded)
let local = try LocalStore.snapshot(checkout)
let pull = WorkspacePull(binding: latest, local: local, remoteFolder: downloaded, conflicts: [])
try LocalStore.applyPull(pull, folder: checkout, original: binding, choices: [:])
let merged = try LocalStore.snapshot(checkout)
precondition(merged.texts["local"] == "edit" && merged.texts["added"] == "new" && merged.hashes["gone"] == nil)
precondition(try LocalStore.binding(checkout).snapshot.hashes == latest.snapshot.hashes)
refused = false
do { try LocalStore.applyPull(pull, folder: checkout, original: binding, choices: [:]) } catch { refused = true }
precondition(refused)
// Import lifecycle: original deletions are independent; copied deletions survive rescan.
let original = fm.temporaryDirectory.appendingPathComponent("import-" + UUID().uuidString, isDirectory: true)
try fm.createDirectory(at: original, withIntermediateDirectories: true)
try Data("delete me".utf8).write(to: original.appendingPathComponent("gone.txt"))
try Data("hidden".utf8).write(to: original.appendingPathComponent(".hidden"))
let imported = try LocalStore.importFolder(original)
let secondImport = try LocalStore.importFolder(original)
precondition(imported != secondImport)
defer {
 try? fm.removeItem(at: original)
 try? LocalStore.removeWorkspace(imported)
 try? LocalStore.removeWorkspace(secondImport)
}
let importedBaseline = try LocalStore.snapshot(imported)
precondition(importedBaseline.hashes[".hidden"] != nil)
try fm.removeItem(at: original.appendingPathComponent("gone.txt"))
let sourceOnly = try LocalStore.changes([imported])
precondition(sourceOnly.isEmpty)
try fm.removeItem(at: imported.appendingPathComponent("gone.txt"))
let copyDeletion = try LocalStore.changes([imported])
let rescanned = try LocalStore.changes([imported])
precondition(copyDeletion.count == 1 && rescanned.count == 1 && rescanned[0].kind == "删除")
precondition(rescanned[0].relativePath == "gone.txt")
try Data("delete me".utf8).write(to: imported.appendingPathComponent("gone.txt"))
let recreated = try LocalStore.changes([imported])
precondition(recreated.isEmpty)
// Real deletion + production selection lifecycle, linked baseline must survive missing files.
let linkedBaseline = try LocalStore.snapshot(imported)
let linked = WorkspaceBinding(repo: "owner/repo", branch: "main", head: "fixture", tree: "fixture", modes: [:], snapshot: linkedBaseline)
try LocalStore.saveBinding(linked, folder: imported)
let scope = WorkspaceSelectionScope(accountID: "alice", folder: imported, repository: linked.repo, branch: linked.branch)
var session = WorkspaceSelectionSession()
try fm.removeItem(at: imported.appendingPathComponent("gone.txt"))
let deletedChanges = try LocalStore.changes([imported])
let linkedAfterDeletion = try LocalStore.binding(imported)
precondition(linkedAfterDeletion.head == linked.head)
let deletedPath = imported.lastPathComponent + "/gone.txt"
precondition(deletedChanges.contains { $0.path == deletedPath && $0.kind == "删除" })
session.scanSucceeded(Set(deletedChanges.map { $0.path }), in: scope)
session.toggle(deletedPath, in: scope)
// Returning foreground has no scanner callback; a later manual scan retains deletion selection.
let manualChanges = try LocalStore.changes([imported])
session.scanSucceeded(Set(manualChanges.map { $0.path }), in: scope)
precondition(session.selected(in: scope) == [deletedPath])
let expectedDeletion = try LocalStore.snapshot(imported)
let deleteWrites = try LocalStore.prepare(imported, paths: ["gone.txt"], expected: expectedDeletion)
precondition(deleteWrites.count == 1)
try Data("delete me".utf8).write(to: imported.appendingPathComponent("gone.txt"))
let restoredChanges = try LocalStore.changes([imported])
session.scanSucceeded(Set(restoredChanges.map { $0.path }), in: scope)
precondition(session.selected(in: scope).isEmpty)
session.toggle(deletedPath, in: scope)
session.remember(imported, accountID: "alice")
let bob = WorkspaceSelectionScope(accountID: "bob", folder: imported, repository: linked.repo, branch: linked.branch)
session.toggle(deletedPath, in: bob)
try LocalStore.removeWorkspace(imported)
session.reconcileWorkspaces([], accountID: "alice")
precondition(session.selected(in: scope).isEmpty && session.rememberedFolder(accountID: "alice") == nil)
precondition(session.selected(in: bob) == [deletedPath])
precondition(!fm.fileExists(atPath: imported.path))
print("PASS production linked file deletion/manual rescan/toggle/prepare/restoration/workspace removal/account-isolated reconciliation")
try fm.createSymbolicLink(atPath: original.appendingPathComponent("unsafe").path, withDestinationPath: "/etc/passwd")
refused = false
do { _ = try LocalStore.importFolder(original) } catch { refused = true }
precondition(refused)
// Actual production diagnostic: exact equality succeeds; all mismatch classes report paths.
precondition(WorkspaceAssociationDiagnostics.mismatch(local: ["a":"1"], remote: ["a":"1"], repo: "owner/repo", branch: "main", head: "abcdef") == nil)
let mismatch = WorkspaceAssociationDiagnostics.mismatch(local: ["changed":"old", "extra":"x"], remote: ["changed":"new", "missing":"y"], repo: "owner/repo", branch: "feature/test", head: "1234567890123456")!
precondition(mismatch.contains("仓库已找到：owner/repo") && mismatch.contains("feature/test") && mismatch.contains("123456789012"))
precondition(mismatch.contains("缺少：missing") && mismatch.contains("多出：extra") && mismatch.contains("内容不同：changed"))
let prefixMismatch = WorkspaceAssociationDiagnostics.mismatch(local: ["repo-main/a":"1"], remote: ["a":"1"], repo: "owner/repo", branch: "main", head: "h")!
precondition(prefixMismatch.contains("缺少：a") && prefixMismatch.contains("多出：repo-main/a"))
// Actual Git blob hashing handles binary bytes and UTF-8 paths, not SHA256 snapshots.
let hashRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: hashRoot, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: hashRoot) }
let binary = Data([0, 255, 10, 13])
try binary.write(to: hashRoot.appendingPathComponent("中文.bin"))
var gitBytes = Data("blob 4\0".utf8); gitBytes.append(binary)
let expectedGit = Insecure.SHA1.hash(data: gitBytes).map { String(format: "%02x", $0) }.joined()
let actualGit = try LocalStore.gitHashes(hashRoot)
precondition(actualGit == ["中文.bin":expectedGit])
print("PASS production association diagnostics: equal/changed/missing/extra/prefix/branch/head and binary Git blob SHA1")
print("PASS actual import lifecycle: fresh copies, hidden files, source deletion isolation, copied deletion/rescan/recreation, pre-copy symlink refusal")
print("PASS: 27 three-way matrix cases; both conflict choices; staged filesystem merge; stale apply rejection; selective baseline; SHA256; scan add/modify/delete; hidden/.git; 11MiB rejection; symlink; unsafe paths")
'''
# Swift precondition autoclosures do not throw.
tests = tests.replace('precondition(try LocalStore.binding(checkout).snapshot.hashes == latest.snapshot.hashes)', 'let saved = try LocalStore.binding(checkout)\nprecondition(saved.snapshot.hashes == latest.snapshot.hashes)')
with tempfile.TemporaryDirectory() as d:
 p = Path(d) / 'tests.swift'
 p.write_text('import Foundation\nimport CryptoKit\nstruct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }\n'+core+remote+Path(REPO_ROOT, 'RepoPocket/WorkspaceSelection.swift').read_text()+tests)
 subprocess.run(['swift', str(p)], check=True)
