import subprocess, tempfile, hashlib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
payload = b'0123456789abcdef' * (11 * 1024 * 1024 // 16)
git = hashlib.sha1(b'blob ' + str(len(payload)).encode() + b'\0' + payload).hexdigest()
sha = hashlib.sha256(payload).hexdigest()
tests = r'''
var replacement = PendingRepoItem(local: URL(fileURLWithPath: "/tmp/old.deb"), size: 1, path: "目录/原名.deb", sha: "original", head: "h")
let identity = replacement.id
replacement.replaceLocal(URL(fileURLWithPath: "/tmp/new.deb"), size: 2)
precondition(replacement.id == identity && replacement.path == "目录/原名.deb" && replacement.sha == "original" && replacement.head == "h")
precondition(RepoQueue.readiness([], repo: "r", message: "m") != nil)
precondition(RepoQueue.readiness([replacement], repo: "", message: "m") != nil)
precondition(RepoQueue.readiness([replacement], repo: "r", message: "m") != nil) // missing file
var a = PendingRepoItem(local: URL(fileURLWithPath: "/tmp/a"), size: 3)
a.select(folder: "one", replacementPath: nil, sha: nil, head: "h")
precondition(a.path == "one/a")
a.select(folder: "two", replacementPath: nil, sha: nil, head: "h")
precondition(a.path == "two/a")
a.select(folder: "", replacementPath: "existing", sha: "s", head: "h")
precondition(a.path == "existing" && a.sha == "s")
a.select(folder: "two", replacementPath: nil, sha: nil, head: "h")
precondition(a.sha == nil)
let b = PendingRepoItem(local: URL(fileURLWithPath: "/tmp/b"), size: 3, path: "three/b", head: "h")
let d = PendingRepoItem(local: nil, size: 0, path: "gone", sha: "s", head: "h")
try RepoQueue.validate([a,b,d], head: "h", files: ["gone":"s"], directories: ["two", "three"])
let entries = RepoQueue.treeEntries([("two/a", "blobA", "100644"), ("three/b", "blobB", "100755"), ("gone", nil, "100644")])
let object: [String: Any] = ["base_tree":"base", "tree":entries]
let json = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: object)) as! [String:Any]
let tree = json["tree"] as! [[String:Any]]
precondition(tree.count == 3 && tree[2]["sha"] is NSNull && tree[1]["mode"] as? String == "100755")
func refuse(_ items: [PendingRepoItem], head: String = "h", files: [String:String] = [:], dirs: Set<String> = []) {
 var failed = false
 do { try RepoQueue.validate(items, head: head, files: files, directories: dirs) } catch { failed = true }
 precondition(failed)
}
refuse([a,a]); refuse([a], head:"changed")
refuse([d], files:["gone":"changed"])
refuse([a], files:["two":"s"])
refuse([a], dirs:["two/a"])
refuse([PendingRepoItem(local: b.local, size: 11*1024*1024, path:"b", head:"h")])
refuse([PendingRepoItem(local:b.local,size:1,path:"../b",head:"h")])
refuse([a,PendingRepoItem(local:b.local,size:1,path:"two/a/child",head:"h")])
refuse([a,PendingRepoItem(local:b.local,size:1,path:"TWO/A",head:"h")])
let fm = FileManager.default
let file = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? fm.removeItem(at:file) }
fm.createFile(atPath:file.path,contents:nil)
let out = try FileHandle(forWritingTo:file)
var hash = StreamingBlobHash(size: SIZE)
let chunk = Data(String(repeating:"0123456789abcdef", count:4096).utf8)
for _ in 0..<(SIZE/chunk.count) { try hash.update(chunk); try out.write(contentsOf:chunk) }
try out.close()
precondition(try hash.finish(expectedGit:"GIT") == "SHA")
precondition(try LocalStore.snapshotFileSHA256(file) == "SHA")
var bad = StreamingBlobHash(size:1)
var failed = false
try bad.update(Data([0]))
do { _ = try bad.finish(expectedGit:"bad") } catch { failed = true }
precondition(failed)
failed = false
do { try bad.update(Data([0])) } catch { failed = true }
precondition(failed)
print("PASS: queue targets/reselection, atomic multi-folder tree/delete, conflicts, 11MiB streamed disk SHA1/SHA256, corruption/overflow")
'''.replace('SIZE',str(len(payload))).replace('"GIT"','"'+git+'"').replace('"SHA"','"'+sha+'"')
# Throwing expressions must be evaluated outside precondition's nonthrowing autoclosure.
tests = tests.replace('precondition(try hash.finish(expectedGit:', 'let verified = try hash.finish(expectedGit:').replace('"'+git+'") == "'+sha+'")','"'+git+'")\nprecondition(verified == "'+sha+'")')
tests = tests.replace('precondition(try LocalStore.snapshotFileSHA256(file) == "'+sha+'")','let diskHash = try LocalStore.snapshotFileSHA256(file)\nprecondition(diskHash == "'+sha+'")')
source = 'import Foundation\nimport CryptoKit\nstruct AppError: Error { let text: String }\nenum LocalStore {}\n' + Path(REPO_ROOT, 'RepoPocket/RepoQueue.swift').read_text() + tests
with tempfile.TemporaryDirectory() as d:
    f=Path(d)/'main.swift'; f.write_text(source)
    subprocess.run(['swiftc', str(f), '-o',d+'/test'],check=True)
    subprocess.run([d+'/test'],check=True)
