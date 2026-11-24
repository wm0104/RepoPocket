"""Exercise production Swift upload rules; native presentation lives in UploadEditorTests."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("swiftc"), "Native Swift rules require swiftc (macOS CI)")
class UploadDestinationBehavior(unittest.TestCase):
    def test_staged_files_live_with_the_upload_session(self):
        view = (ROOT / "RepoPocket/UploadView.swift").read_text(encoding="utf-8")
        staging = view[view.index("private final class UploadStaging:"):]
        harness = r"""
func exercise() throws {
    var first: UploadStaging? = UploadStaging()
    let other = UploadStaging()
    let file = first!.root.appendingPathComponent("queued.txt")
    let manager = FileManager.default
    try manager.createDirectory(at: first!.root, withIntermediateDirectories: true)
    try manager.createDirectory(at: other.root, withIntermediateDirectories: true)
    try Data([1]).write(to: file)
    do {
        let transfer = first!
        first = nil
        withExtendedLifetime(transfer) { precondition(manager.fileExists(atPath: file.path)) }
    }
    precondition(!manager.fileExists(atPath: file.path))
    withExtendedLifetime(other) { precondition(manager.fileExists(atPath: other.root.path)) }
}
try exercise()
"""
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory) / "main.swift"
            main.write_text("import Foundation\nprotocol ObservableObject {}\n" + staging + harness, encoding="utf-8")
            subprocess.run(["swift", str(main)], check=True)

    def test_real_pending_item_inheritance_and_conflicts(self):
        source = (ROOT / "RepoPocket/RepoQueue.swift").read_text(encoding="utf-8")
        source = source.split("struct StreamingBlobHash", 1)[0].replace("import CryptoKit", "")
        source += (ROOT / "Tests/Fixtures/UploadIndexFixture.swift").read_text()
        harness = r'''
struct AppError: Error { let text: String }
let file = URL(fileURLWithPath: "/tmp/KeyBridge.deb")
var item = PendingRepoItem(local: file, size: 4)
let id = item.id
let inherited = try item.inheritTarget(folder: "debs", head: "h1", index: UploadPathIndex(files: [:], directories: ["debs"]))
precondition(inherited && item.id == id && item.path == "debs/KeyBridge.deb" && item.head == "h1" && item.sha == nil)
var root = PendingRepoItem(local: file, size: 4)
let rootBound = try root.inheritTarget(folder: "", head: "h2", index: UploadPathIndex(files: [:], directories: []))
precondition(rootBound && root.path == "KeyBridge.deb" && root.head == "h2")
var existing = PendingRepoItem(local: file, size: 4)
let automatic = try existing.inheritTarget(folder: "debs", head: "h2", index: UploadPathIndex(files: ["debs/KeyBridge.deb": "original"], directories: ["debs"]))
precondition(!automatic && existing.path == nil && existing.sha == nil && existing.head == nil)
existing.select(folder: "debs", replacementPath: "debs/KeyBridge.deb", sha: "original", head: "h2")
try RepoQueue.validate([existing], head: "h2", index: UploadPathIndex(files: ["debs/KeyBridge.deb": "original"], directories: ["debs"]))
var refused = false
do { try RepoQueue.validate([existing], head: "h3", index: UploadPathIndex(files: ["debs/KeyBridge.deb": "original"], directories: ["debs"])) } catch { refused = true }
precondition(refused)
func rejects(_ folder: String, files: [String: String] = [:], directories: Set<String> = []) {
    var entry = PendingRepoItem(local: file, size: 4)
    var rejected = false
    do { _ = try entry.inheritTarget(folder: folder, head: "h", index: UploadPathIndex(files: files, directories: directories)) } catch { rejected = true }
    precondition(rejected && entry.path == nil && entry.head == nil)
}
rejects("../debs")
rejects("debs", directories: ["debs", "debs/KeyBridge.deb"])
rejects("debs", files: ["debs/keybridge.deb": "s"], directories: ["debs"])
rejects("debs", files: ["debs": "s"])
var deletion = PendingRepoItem(local: nil, size: 0, path: "old", sha: "s", head: "old-head")
let changedDeletion = try deletion.inheritTarget(folder: "debs", head: "new-head", index: UploadPathIndex(files: [:], directories: ["debs"]))
precondition(!changedDeletion && deletion.path == "old" && deletion.head == "old-head")
var duplicate = PendingRepoItem(local: file, size: 4)
_ = try duplicate.inheritTarget(folder: "", head: "h2", index: UploadPathIndex(files: [:], directories: []))
var duplicateRefused = false
do { try RepoQueue.validate([root, duplicate], head: "h2", index: UploadPathIndex(files: [:], directories: [])) } catch { duplicateRefused = true }
precondition(duplicateRefused)
var remoteIndex = UploadPathIndex()
try remoteIndex.insert(path: "src", sha: nil)
try remoteIndex.insert(path: "src/\u{e9}.swift", sha: "one", mode: "100755")
precondition(remoteIndex.fileMode(at: "src/\u{e9}.swift") == "100755")
try remoteIndex.insert(path: "src/e\u{301}.swift", sha: "two")
try remoteIndex.insert(path: "logs/12:30.txt", sha: "other")
let unaffected = PendingRepoItem(local: file, size: 4, path: "docs/readme.md", head: "h")
try RepoQueue.validate([unaffected], head: "h", index: remoteIndex)
for path in ["SRC/ok", "src/\u{e9}.swift", "src/e\u{301}.swift", "src/\u{e9}.swift/child", "src/../other", "x\\y", "a\0b", "12:30.txt"] {
    let item = PendingRepoItem(local: file, size: 4, path: path, head: "h")
    do { try RepoQueue.validate([item], head: "h", index: remoteIndex); preconditionFailure("accepted \(path)") } catch {}
}
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
