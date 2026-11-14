"""Exercise production Swift upload rules; native presentation lives in UploadEditorTests."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("swiftc"), "Native Swift rules require swiftc (macOS CI)")
class UploadDestinationBehavior(unittest.TestCase):
    def test_real_pending_item_inheritance_and_conflicts(self):
        source = (ROOT / "RepoPocket/RepoQueue.swift").read_text(encoding="utf-8")
        source = source.split("struct StreamingBlobHash", 1)[0].replace("import CryptoKit", "")
        harness = r'''
struct AppError: Error { let text: String }
let file = URL(fileURLWithPath: "/tmp/KeyBridge.deb")
var item = PendingRepoItem(local: file, size: 4)
let id = item.id
let inherited = try item.inheritTarget(folder: "debs", head: "h1", files: [:], directories: ["debs"])
precondition(inherited && item.id == id && item.path == "debs/KeyBridge.deb" && item.head == "h1" && item.sha == nil)
item.replaceLocal(URL(fileURLWithPath: "/tmp/new-name.deb"), size: 5)
precondition(item.id == id && item.path == "debs/KeyBridge.deb" && item.head == "h1")
var root = PendingRepoItem(local: file, size: 4)
let rootBound = try root.inheritTarget(folder: "", head: "h2", files: [:], directories: [])
precondition(rootBound && root.path == "KeyBridge.deb" && root.head == "h2")
var existing = PendingRepoItem(local: file, size: 4)
let automatic = try existing.inheritTarget(folder: "debs", head: "h2", files: ["debs/KeyBridge.deb": "original"], directories: ["debs"])
precondition(!automatic && existing.path == nil && existing.sha == nil && existing.head == nil)
existing.select(folder: "debs", replacementPath: "debs/KeyBridge.deb", sha: "original", head: "h2")
try RepoQueue.validate([existing], head: "h2", files: ["debs/KeyBridge.deb": "original"], directories: ["debs"])
var refused = false
do { try RepoQueue.validate([existing], head: "h3", files: ["debs/KeyBridge.deb": "original"], directories: ["debs"]) } catch { refused = true }
precondition(refused)
func rejects(_ folder: String, files: [String: String] = [:], directories: Set<String> = []) {
    var entry = PendingRepoItem(local: file, size: 4)
    var rejected = false
    do { _ = try entry.inheritTarget(folder: folder, head: "h", files: files, directories: directories) } catch { rejected = true }
    precondition(rejected && entry.path == nil && entry.head == nil)
}
rejects("../debs")
rejects("debs", directories: ["debs", "debs/KeyBridge.deb"])
rejects("debs", files: ["debs/keybridge.deb": "s"], directories: ["debs"])
rejects("debs", files: ["debs": "s"])
var deletion = PendingRepoItem(local: nil, size: 0, path: "old", sha: "s", head: "old-head")
let changedDeletion = try deletion.inheritTarget(folder: "debs", head: "new-head", files: [:], directories: ["debs"])
precondition(!changedDeletion && deletion.path == "old" && deletion.head == "old-head")
var duplicate = PendingRepoItem(local: file, size: 4)
_ = try duplicate.inheritTarget(folder: "", head: "h2", files: [:], directories: [])
var duplicateRefused = false
do { try RepoQueue.validate([root, duplicate], head: "h2", files: [:], directories: []) } catch { duplicateRefused = true }
precondition(duplicateRefused)
print("PASS real upload destination inheritance, explicit overwrite, conflicts, local replacement and stale HEAD")
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            main = path / "main.swift"
            main.write_text(source + harness, encoding="utf-8")
            executable = path / "upload-target-test"
            subprocess.run(["swiftc", str(main), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    unittest.main()
