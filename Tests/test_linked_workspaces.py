"""Run production directory association/deletion against disposable macOS fixtures.

Only OS sandbox grants and registry storage location are substituted: a Swift CLI
does not receive UIDocumentPicker grants. Bookmark serialization, coordination,
hashing, baselines, and actual filesystem mutation remain production code.
"""
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'RepoPocket/WorkspaceView.swift').read_text(encoding='utf-8')
assert '.swipeActions' not in source
assert 'if !zip { return try LinkedWorkspaces.register(source) }' in source
assert '永久删除所选实际目录及其全部内容' in source
assert 'let name = try LinkedWorkspaces.identifier(folder)' in source
if not shutil.which('swift'):
    print('SKIP native linked workspace fixtures: Swift unavailable')
else:
    core = source[source.index('struct LocalSnapshot:'):source.index('\nstruct WorkspaceView:')]
    remote = (ROOT / 'RepoPocket/WorkspaceRemote.swift').read_text(encoding='utf-8').replace('import Foundation', '').replace('import CryptoKit', '')
    # Isolate registry and model successful picker authorization in a CLI process.
    core = core.replace('try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LinkedWorkspaces.json")', 'fixture.appendingPathComponent("registry.json")')
    core = core.replace('url.startAccessingSecurityScopedResource()', 'allowScope')
    core = core.replace('url.stopAccessingSecurityScopedResource()', 'fixtureRelease()')
    core = core.replace('scopes.removeValue(forKey: records[i].id)?.stopAccessingSecurityScopedResource()', '_ = scopes.removeValue(forKey: records[i].id)')
    core = core.replace('scopes.removeValue(forKey: entry.id)?.stopAccessingSecurityScopedResource()', '_ = scopes.removeValue(forKey: entry.id)')
    core = core.replace('let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)', 'let documents = fixture.appendingPathComponent("owned")')
    core = core.replace('enum LinkedWorkspaces {', 'enum LinkedWorkspaces {\n static func fixtureCloseScopes() { scopes.removeAll(); scopedIDs.removeAll() }')
    tests = r'''
let fm = FileManager.default
let a = fixture.appendingPathComponent("one/same", isDirectory: true)
let b = fixture.appendingPathComponent("two/same", isDirectory: true)
try fm.createDirectory(at: a, withIntermediateDirectories: true)
try fm.createDirectory(at: b, withIntermediateDirectories: true)
try Data("original".utf8).write(to: a.appendingPathComponent("中文.py"))
try Data("neighbor".utf8).write(to: b.appendingPathComponent("keep.txt"))
let linkedA = try LinkedWorkspaces.register(a)
let linkedB = try LinkedWorkspaces.register(b)
precondition(linkedA.path == a.path && linkedB.path == b.path)
let metaA = try LocalStore.metadata(a), metaB = try LocalStore.metadata(b)
precondition(metaA != metaB)
defer { try? fm.removeItem(at: metaA); try? fm.removeItem(at: metaB) }
try Data("edited outside app".utf8).write(to: a.appendingPathComponent("中文.py"))
let changes = try LocalStore.changes([linkedA])
precondition(changes.count == 1 && changes[0].after == "edited outside app")
_ = try LinkedWorkspaces.register(a) // Reassociation must retain old baseline.
let repeated = try LocalStore.changes([a])
precondition(repeated.count == 1)
allowScope = false
let denied = fixture.appendingPathComponent("denied", isDirectory: true)
try fm.createDirectory(at: denied, withIntermediateDirectories: true)
var rejected = false
do { _ = try LinkedWorkspaces.register(denied) } catch { rejected = true }
let deniedID = try LinkedWorkspaces.identifier(denied)
precondition(rejected && deniedID == nil)
let own = fixture.appendingPathComponent("owned/project", isDirectory: true)
try fm.createDirectory(at: own, withIntermediateDirectories: true)
_ = try LinkedWorkspaces.register(own) // Own app container needs no sandbox grant.
try LinkedWorkspaces.detach(own)
precondition(fm.fileExists(atPath: own.path))
let ownRoot = own.deletingLastPathComponent()
_ = try LinkedWorkspaces.register(ownRoot)
rejected = false
do { try LocalStore.removeWorkspace(ownRoot) } catch { rejected = true }
precondition(rejected && fm.fileExists(atPath: own.path))
try LinkedWorkspaces.detach(ownRoot)
LinkedWorkspaces.fixtureCloseScopes() // Model a new process with no retained grants.
rejected = false
do { _ = try LinkedWorkspaces.roots() } catch { rejected = true }
precondition(rejected)
allowScope = true
let restored = try LinkedWorkspaces.roots()
precondition(restored.count == 2 && LocalStore.matchingRoot(a, in: restored) != nil && LocalStore.matchingRoot(b, in: restored) != nil, "Cold-start bookmarks must restore both original directories despite Darwin path aliases; got \(restored.map(\.path)); expected \([a.path, b.path])")
// Preserve the second selection when the OS bookmark resolves the /var alias
// to /private/var. This must return the authorized root URL, not a rebuilt URL.
let aliasB = URL(fileURLWithPath: b.path.replacingOccurrences(of: "/private/var/", with: "/var/"), isDirectory: true)
let selectedB = LocalStore.matchingRoot(aliasB, in: restored)
precondition(selectedB == LocalStore.matchingRoot(b, in: restored) && selectedB != LocalStore.matchingRoot(a, in: restored), "Canonical path aliases must retain selected B rather than falling back to first A")
rejected = false
do { _ = try LocalStore.renameWorkspace(a, to: "moved") } catch { rejected = true }
precondition(rejected && fm.fileExists(atPath: a.path))
rejected = false
do { try LocalStore.removeWorkspace(a.deletingLastPathComponent()) } catch { rejected = true }
precondition(rejected && fm.fileExists(atPath: a.path))
// Moving the registered original and replacing its old path must not target
// the replacement, even though its display name and path are identical.
let moved = fixture.appendingPathComponent("one/original", isDirectory: true)
try fm.moveItem(at: a, to: moved)
try fm.createDirectory(at: a, withIntermediateDirectories: false)
try Data("replacement".utf8).write(to: a.appendingPathComponent("keep.txt"))
rejected = false
do { try LocalStore.removeWorkspace(a) } catch { rejected = true }
precondition(rejected && fm.fileExists(atPath: moved.path) && fm.fileExists(atPath: a.path))
try fm.removeItem(at: a)
try fm.moveItem(at: moved, to: a)
try LocalStore.removeWorkspace(a)
precondition(!fm.fileExists(atPath: a.path))
precondition(fm.fileExists(atPath: a.deletingLastPathComponent().path))
let neighbor = try String(contentsOf: b.appendingPathComponent("keep.txt"), encoding: .utf8)
precondition(neighbor == "neighbor")
let remaining = try LinkedWorkspaces.roots()
precondition(remaining.count == 1 && LocalStore.matchingRoot(b, in: remaining) != nil, "Removing A must retain precisely registered B")
let survivor = fixture.appendingPathComponent("survivor", isDirectory: true)
try fm.createDirectory(at: survivor, withIntermediateDirectories: true)
_ = try LinkedWorkspaces.register(survivor)
// A missing provider root must throw; never publish an empty replacement list.
try fm.removeItem(at: b)
rejected = false
do { _ = try LinkedWorkspaces.roots() } catch { rejected = true }
precondition(rejected)
try LinkedWorkspaces.detach(b) // Recover without permission to access the lost root.
let recovered = try LinkedWorkspaces.roots()
precondition(recovered.count == 1 && LocalStore.matchingRoot(survivor, in: recovered) != nil, "Detaching lost B must recover the survivor root")
try LinkedWorkspaces.detach(survivor)
precondition(fm.fileExists(atPath: survivor.path))
print("PASS linked original changes, persistent bookmarks, same-name isolation, preserved baseline, exact deletion and unavailable-root refusal")
'''
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / 'test.swift'
        prefix = 'import Foundation\nimport CryptoKit\nstruct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }\nlet fixture = URL(fileURLWithPath: "' + d.replace('\\', '\\\\') + '").resolvingSymlinksInPath().standardizedFileURL\nvar allowScope = true\nfunc fixtureRelease() {}\n'
        path.write_text(prefix + core + remote + tests, encoding='utf-8')
        subprocess.run(['swift', str(path)], check=True)
