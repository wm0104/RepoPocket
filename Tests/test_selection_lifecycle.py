from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import subprocess, tempfile

model = Path(REPO_ROOT, 'RepoPocket/WorkspaceSelection.swift').read_text()
tests = r'''
let folder = URL(fileURLWithPath: "/tmp/workspace")
let scope = WorkspaceSelectionScope(accountID: "alice", folder: folder, repository: "Owner/Repo", branch: "main")
let recreated = WorkspaceSelectionScope(accountID: "alice", folder: folder.appendingPathComponent("child/.."), repository: "owner/repo", branch: "main")
var session = WorkspaceSelectionSession()
let deletions: Set<String> = ["workspace/deleted-a.deb", "workspace/sub/deleted-b.dylib"]
for path in deletions { session.toggle(path, in: scope) }
// Full scanner change paths, NOT current disk files: absent deleted files remain valid.
session.scanSucceeded(deletions, in: scope)
precondition(session.selected(in: recreated) == deletions)
session.remember(folder, accountID: "alice")
precondition(session.rememberedFolder(accountID: "alice") == folder)
// Detail/tab/rotation/background only recreate consumers; the App retains this session.
for _ in 0..<5 { precondition(session.selected(in: recreated).count == 2) }
for other in [WorkspaceSelectionScope(accountID: "bob", folder: folder, repository: "owner/repo", branch: "main"), WorkspaceSelectionScope(accountID: "alice", folder: URL(fileURLWithPath: "/tmp/other"), repository: "owner/repo", branch: "main"), WorkspaceSelectionScope(accountID: "alice", folder: folder, repository: "owner/repo", branch: "feature"), WorkspaceSelectionScope(accountID: "alice", folder: folder, repository: "owner/other", branch: "main")] {
    precondition(session.selected(in: other).isEmpty)
}
// Failures intentionally have no mutation API: catch paths cannot prune the model.
func failedScanOrCommit() throws { throw NSError(domain: "fixture", code: 1) }
do { try failedScanOrCommit() } catch { }
precondition(session.selected(in: scope) == deletions)
session.commitSucceeded(["workspace/deleted-a.deb"], in: scope)
precondition(session.selected(in: scope) == ["workspace/sub/deleted-b.dylib"])
session.scanSucceeded([], in: scope)
precondition(session.selected(in: scope).isEmpty)
session.toggle("explicit", in: scope); session.toggle("explicit", in: scope)
precondition(session.selected(in: scope).isEmpty)
precondition(RefreshFailure.isCancellation(CancellationError()))
precondition(RefreshFailure.isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
precondition(!RefreshFailure.isCancellation(NSError(domain: "fixture", code: 1)))
precondition(WorkspaceSelectionSession().selected(in: scope).isEmpty)
print("PASS production Swift selection session: deleted paths, recreation, isolation, failure, pruning, cancellation, process-only reset")
'''
with tempfile.TemporaryDirectory() as d:
    p = Path(d) / 'main.swift'; p.write_text(model + tests)
    subprocess.run(['swiftc', str(p), '-o', d + '/tests'], check=True)
    subprocess.run([d + '/tests'], check=True)

w = Path(REPO_ROOT, 'RepoPocket/WorkspaceView.swift').read_text()
a = Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text()
h = Path(REPO_ROOT, 'RepoPocket/DesktopViews.swift').read_text()
u = Path(REPO_ROOT, 'RepoPocket/WorkspaceSelectionUI.swift').read_text()
c = Path(REPO_ROOT, 'RepoPocket/RepositoryUI.swift').read_text()
assert '@State private var selected' not in w and 'selected.removeAll()' not in w
assert '@StateObject private var selectionStore' in a and '.environmentObject(selectionStore)' in a
assert '.buttonStyle(.plain)' in w and '.frame(width: 44, height: 44)' in w and 'Text(change.relativePath)' in w
scan = w[w.index('@MainActor private func scan()'):w.index('struct LocalDiffView')]
assert scan.index('before.hashes == after.hashes') < scan.index('roots = result.0') < scan.index('scanSucceeded(')
assert 'folder == requestedFolder' in scan and 'generation == AccountStore.generation' in scan
commit = w[w.index('@MainActor private func commit()'):w.index('@MainActor private func scan()')]
assert 'if succeeded { await scan() }' in commit and 'commitSucceeded(committing' in commit
sections = Path(REPO_ROOT, 'RepoPocket/RepositorySections.swift').read_text()
assert 'if busy && repositories.isEmpty && !refreshing' in sections and 'if busy && entries.isEmpty && !refreshing' in a
assert '.refreshable { refreshing = true; defer { refreshing = false }; await load() }' in sections
assert '.task { if !loaded' in a and '.task { if !hasScanned' in w
assert 'guard !busy else { return }' in a and 'guard !busy else { return }' in scan
assert 'commits = []' not in h and 'if refresh { commits = batch }' in h
assert 'verticalSizeClass == .compact ? .inline : .large' in u
assert 'verticalSizeClass == .compact ? 3 : 7' in c
assert 'accessibilityReduceMotion' in c and '.animation(reduceMotion ? nil' in c
assert 'scenePhase' not in w and '.transition(' not in w and '.animation(' not in w
assert 'UserDefaults' not in model and 'CredentialStore' not in model
print('PASS refresh/landscape/selection/cancellation static contracts; actual device transitions unmeasured')
