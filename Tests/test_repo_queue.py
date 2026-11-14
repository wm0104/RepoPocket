import subprocess, tempfile, hashlib, shutil
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
let overBudget = (0..<6).map { PendingRepoItem(local: URL(fileURLWithPath:"/tmp/file-\($0)"), size: 10*1024*1024, path:"f\($0)", head:"h") }
refuse(overBudget)
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
print("PASS: queue targets/reselection, 50MiB aggregate cap, atomic multi-folder tree/delete, conflicts, 11MiB streamed disk SHA1/SHA256, corruption/overflow")
'''.replace('SIZE',str(len(payload))).replace('"GIT"','"'+git+'"').replace('"SHA"','"'+sha+'"')
# Throwing expressions must be evaluated outside precondition's nonthrowing autoclosure.
tests = tests.replace('precondition(try hash.finish(expectedGit:', 'let verified = try hash.finish(expectedGit:').replace('"'+git+'") == "'+sha+'")','"'+git+'")\nprecondition(verified == "'+sha+'")')
tests = tests.replace('precondition(try LocalStore.snapshotFileSHA256(file) == "'+sha+'")','let diskHash = try LocalStore.snapshotFileSHA256(file)\nprecondition(diskHash == "'+sha+'")')
source = 'import Foundation\nimport CryptoKit\nstruct AppError: Error { let text: String }\nenum LocalStore {}\n' + Path(REPO_ROOT, 'RepoPocket/RepoQueue.swift').read_text() + tests
if shutil.which('swiftc'):
    with tempfile.TemporaryDirectory() as d:
        f=Path(d)/'main.swift'; f.write_text(source)
        subprocess.run(['swiftc', str(f), '-o',d+'/test'],check=True)
        subprocess.run([d+'/test'],check=True)
else:
    print('SKIP native Swift queue harness: swiftc is available on the macOS CI runner.', flush=True)

# Exercise the production file encoder with a file-backed transport stand-in.
# No GitHub connection is made; the captured request JSON must round-trip to
# exactly the selected bytes, including an empty .gitkeep and chunk boundaries.
api_source = Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text()
blob_helper = api_source.split('    private func uploadGitBlobFile(', 1)[1].split('    func history(', 1)[0]
blob_helper = '    private func uploadGitBlobFile(' + blob_helper
blob_fixture = r'''
import Foundation
struct AppError: Error { let text: String }
struct GitObject: Decodable { let sha: String }
@MainActor final class BlobUploadTransport {
    var bodies: [Data] = []
    var files: [URL] = []
    func upload(for request: URLRequest, fromFile file: URL) async throws -> (Data, URLResponse) {
        precondition(request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        bodies.append(try Data(contentsOf: file)); files.append(file)
        let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
        return (Data("{\"sha\":\"fixture-sha\"}".utf8), response)
    }
}
@MainActor final class GitHub {
    let session = BlobUploadTransport()
    var active = true
    func ensureActiveAccount() throws { if !active { throw CancellationError() } }
    func url(_ path: String) -> URL { URL(string: "https://api.github.com" + path)! }
    func request(_ url: URL, method: String) throws -> URLRequest {
        var request = URLRequest(url: url); request.httpMethod = method; return request
    }
    func check(_ bytes: Data, _ response: URLResponse, operation: String) throws {
        guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw AppError(text: operation) }
    }
PRODUCTION_HELPER
    func fixtureUpload(_ file: URL, maximumBytes: Int64, expectedSize: Int64) async throws -> GitObject {
        try await uploadGitBlobFile(file, path: "/repos/fixture/repo/git/blobs", maximumBytes: maximumBytes, expectedSize: expectedSize)
    }
}
@main struct BlobEncoderRegression {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("BlobEncoderRegression-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let api = GitHub()
        let file = root.appendingPathComponent(".gitkeep")
        let maximumBytes: Int64 = 512 * 1024
        if CommandLine.arguments.contains("--expect-empty-rejection") {
            try Data().write(to: file)
            do {
                _ = try await api.fixtureUpload(file, maximumBytes: maximumBytes, expectedSize: 0)
                preconditionFailure("old empty-file guard unexpectedly accepted .gitkeep")
            } catch is AppError {}
            precondition(api.session.bodies.isEmpty)
            print("PASS negative control: original guard rejects empty .gitkeep before upload")
            return
        }
        for size in [0, 1, 2, 3, 192 * 1024 - 1, 192 * 1024, 192 * 1024 + 1, 384 * 1024 + 2] {
            let selected = Data((0..<size).map { UInt8($0 % 251) })
            try selected.write(to: file)
            let before = api.session.bodies.count
            let blob = try await api.fixtureUpload(file, maximumBytes: maximumBytes, expectedSize: Int64(size))
            precondition(blob.sha == "fixture-sha" && api.session.bodies.count == before + 1)
            let object = try JSONSerialization.jsonObject(with: api.session.bodies.last!) as! [String: String]
            precondition(object["encoding"] == "base64")
            precondition(Data(base64Encoded: object["content"]!) == selected)
            precondition(!fm.fileExists(atPath: api.session.files.last!.path))
        }
        // Empty .gitkeep remains a valid upload, while limits and stale size
        // guards still reject before the transport sees a request.
        let beforeRefusals = api.session.bodies.count
        try Data([1, 2]).write(to: file)
        do {
            _ = try await api.fixtureUpload(file, maximumBytes: 1, expectedSize: 2)
            preconditionFailure("oversize file accepted")
        } catch is AppError {}
        do {
            _ = try await api.fixtureUpload(file, maximumBytes: maximumBytes, expectedSize: 1)
            preconditionFailure("changed file size accepted")
        } catch is AppError {}
        do {
            _ = try await api.fixtureUpload(root, maximumBytes: maximumBytes, expectedSize: 0)
            preconditionFailure("directory accepted")
        } catch is AppError {}
        api.active = false
        do {
            _ = try await api.fixtureUpload(file, maximumBytes: maximumBytes, expectedSize: 2)
            preconditionFailure("stale account accepted")
        } catch is CancellationError {}
        precondition(api.session.bodies.count == beforeRefusals)
        print("PASS: production blob helper empty .gitkeep, Base64 carry/chunk round trips, upload-file cleanup, size/account guards; no network")
    }
}
'''.replace('PRODUCTION_HELPER', blob_helper)
baseline_helper = blob_helper.replace('guard sourceSize >= 0,', 'guard sourceSize > 0,', 1)
assert baseline_helper != blob_helper, 'Expected the production empty-file fix for the negative control'
if shutil.which('swiftc'):
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / 'BlobEncoderRegression.swift'
        f.write_text(blob_fixture.replace(blob_helper, baseline_helper, 1))
        subprocess.run(['swiftc', '-parse-as-library', str(f), '-o', d + '/blob-test'], check=True)
        subprocess.run([d + '/blob-test', '--expect-empty-rejection'], check=True)
        f.write_text(blob_fixture)
        subprocess.run(['swiftc', '-parse-as-library', str(f), '-o', d + '/blob-test'], check=True)
        subprocess.run([d + '/blob-test'], check=True)
else:
    print('SKIP production Swift blob encoder regression: empty/chunk fixtures run on the macOS CI runner.', flush=True)
