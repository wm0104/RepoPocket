from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import unittest, shutil, subprocess, tempfile
rules = Path(REPO_ROOT, 'RepoPocket/DownloadRules.swift').read_text()
store = Path(REPO_ROOT, 'RepoPocket/DownloadStore.swift').read_text()
app = Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text()
account = Path(REPO_ROOT, 'RepoPocket/AccountManagement.swift').read_text()
class DownloadTests(unittest.TestCase):
 def test_app_owned_storage_does_not_touch_old_external_folders(self):
  self.assertIn('NSHomeDirectory()', store)
  self.assertIn('DownloadRules.canonicalContainer(container)', store)
  self.assertIn('.appendingPathComponent("Library/Application Support/Downloads"', store)
  for removed in ['resolvingBookmarkData', 'startAccessingSecurityScopedResource', 'func choose()', 'func selected(', 'WorkspaceImportRequest']:
   self.assertNotIn(removed, store)
  self.assertNotIn('removeObject(forKey:', store)
 def test_large_file_transaction_runs_off_main_and_can_be_cancelled(self):
  for token in ['func persist(_ temporary: URL, session: UUID', 'Task.detached(priority: .utility)', 'withTaskCancellationHandler', 'Task.isCancelled', 'volumeAvailableCapacityForImportantUsageKey', 'LocalStore.snapshotFileSHA256']:
   self.assertIn(token, store)
  for name in ['RepoPocketApp.swift', 'WorkflowViews.swift', 'ReleaseAssetDownload.swift']:
   self.assertIn('DownloadStore.shared.download(', Path(REPO_ROOT, 'RepoPocket', name).read_text())
  self.assertIn('DownloadStore.shared.persist(file, session: accountSession)', Path(REPO_ROOT, 'RepoPocket/UpdateFeature.swift').read_text())
 def test_settings_remove_folder_choice_but_keep_update(self):
  self.assertNotIn('CacheSettingsSection', app)
  self.assertNotIn('NativeMenuItem(id: "download-folder"', app)
  self.assertNotIn('downloads.choose()', app)
  self.assertIn('AppUpdateSection(api: api, checker: updateChecker, connected: true)', app)
  self.assertNotIn('清缓存', store)

 def test_download_error_body_is_read_with_a_fixed_memory_bound(self):
  github = Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text()
  download = github.split('    private func download(', 1)[1].split('    // These bounded endpoints', 1)[0]
  self.assertNotIn('Data(contentsOf:', download)
  self.assertIn('handle.read(upToCount: 8192)', download)
  self.assertIn('defer { try? handle.close() }', download)

 def test_real_callsites_and_lifecycle(self):
  self.assertIn('AccountStore.generation', store)
  self.assertIn('DownloadStore.shared.download(.archive', app)
  downloader = Path(REPO_ROOT, 'RepoPocket/ReleaseAssetDownload.swift').read_text()
  self.assertIn('DownloadStore.shared.download(.releaseAsset', downloader)
  management = Path(REPO_ROOT, 'RepoPocket/ReleaseManagementUI.swift').read_text()
  self.assertIn('if !self.downloader.keepsDownloadedFile', management)
  self.assertIn('preservingDownload: true', management)
  update = Path(REPO_ROOT, 'RepoPocket/UpdateFeature.swift').read_text()
  self.assertIn('DownloadStore.shared.persist(file, session: accountSession)', update)
  self.assertNotIn('removeItem(at: downloaded)', update)
  self.assertIn('archive.extract', update)
  self.assertIn('ZStack { AccountRootView().id(accountID) }', app)
  self.assertIn('accounts = AccountStore.accounts', account)
  self.assertIn('verification?.cancel()', account)
  self.assertIn('redirected.setValue(nil, forHTTPHeaderField: "Authorization")', Path(REPO_ROOT, 'RepoPocket/ReleaseAssetRedirectPolicy.swift').read_text())
 @unittest.skipUnless(shutil.which('swiftc'), 'Production download transport runs on macOS')
 def test_production_download_error_and_temporary_file_lifecycle(self):
  github = Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text()
  download = '    func download(' + github.split('    private func download(', 1)[1].split('    // These bounded endpoints', 1)[0]
  source = rules + r'''
struct DownloadHTTPError: Error { let status: Int }
final class ArchiveRedirectPolicy: NSObject, URLSessionTaskDelegate {}
@MainActor final class DownloadTransport {
    var temporary: URL
    var status = 500
    init(_ temporary: URL) { self.temporary = temporary }
    func download(for request: URLRequest, delegate: URLSessionTaskDelegate) async throws -> (URL, URLResponse) {
        (temporary, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor final class GitHub {
    let session: DownloadTransport
    var active = true
    var checkedBody: Data?
    init(_ temporary: URL) { session = DownloadTransport(temporary) }
    func ensureActiveAccount() throws { if !active { throw CancellationError() } }
    func check(_ body: Data, _ response: URLResponse, operation: String) throws {
        checkedBody = body
        let status = (response as! HTTPURLResponse).statusCode
        if !(200..<300).contains(status) { throw DownloadHTTPError(status: status) }
    }
// PRODUCTION_DOWNLOAD
}
@main struct DownloadRegression {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DownloadRegression-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let temporary = root.appendingPathComponent("response.tmp")
        let api = GitHub(temporary)
        let request = URLRequest(url: URL(string: "https://api.github.com/fixture")!)
        for (status, body) in [(404, Data("{\"message\":\"Not Found\"}".utf8)),
                               (500, Data(repeating: 65, count: 2 * 1024 * 1024)), (403, Data())] {
            try body.write(to: temporary)
            api.session.status = status
            do {
                _ = try await api.download(request, name: "asset.zip")
                preconditionFailure("HTTP error accepted")
            } catch let error as DownloadHTTPError { precondition(error.status == status) }
            precondition(api.checkedBody == Data(body.prefix(8192)))
            precondition(!fm.fileExists(atPath: temporary.path))
        }
        // An unreadable response still reports the HTTP error, not a file-read error.
        api.session.status = 503
        do {
            _ = try await api.download(request, name: "asset.zip")
            preconditionFailure("missing error body accepted")
        } catch let error as DownloadHTTPError { precondition(error.status == 503) }
        precondition(api.checkedBody == Data())
        let contents = Data("downloaded contents".utf8)
        try contents.write(to: temporary)
        api.session.status = 200
        let saved = try await api.download(request, name: "asset.zip")
        defer { try? fm.removeItem(at: saved.deletingLastPathComponent()) }
        let actual = try Data(contentsOf: saved)
        precondition(actual == contents && saved.lastPathComponent == "asset.zip")
        precondition(api.checkedBody == Data() && !fm.fileExists(atPath: temporary.path))
        try contents.write(to: temporary)
        api.active = false; api.checkedBody = nil
        do {
            _ = try await api.download(request, name: "asset.zip")
            preconditionFailure("stale account accepted")
        } catch is CancellationError {}
        precondition(api.checkedBody == nil && !fm.fileExists(atPath: temporary.path))
        print("PASS production download: bounded error body, empty/unreadable response, success, session rejection and temporary cleanup; no network")
    }
}
'''
  source = source.replace('// PRODUCTION_DOWNLOAD', download)
  with tempfile.TemporaryDirectory() as d:
   p = Path(d) / 'main.swift'; p.write_text(source)
   subprocess.run(['swiftc', '-parse-as-library', str(p), '-o', d + '/test'], check=True)
   subprocess.run([d + '/test'], check=True, timeout=30)
 @unittest.skipUnless(shutil.which('swiftc'), 'Pure Swift mocks run in Actions; no Apple device data touched')
 def test_production_rules_mock(self):
  source = rules + r'''
let fm = FileManager.default
// macOS temporaryDirectory uses /var -> /private/var. Resolve that system alias
// before constructing the fixture; deliberate symlinks below root remain rejected.
let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("DownloadMock-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let parent = root.appendingPathComponent("chosen")
try fm.createDirectory(at: parent, withIntermediateDirectories: true)
let input = root.appendingPathComponent("a.zip")
try Data("fixture".utf8).write(to: input)
// Test fingerprints read only these seven-byte fixtures, production is streaming SHA256.
func fingerprint(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
let first = try DownloadRules.save(input, parent: parent, valid: { true }, fingerprint: fingerprint)
let second = try DownloadRules.save(input, parent: parent, valid: { true }, fingerprint: fingerprint)
precondition(first.lastPathComponent == "a.zip" && second.lastPathComponent == "a (1).zip")
let existingFolder = parent.appendingPathComponent("RepoPocket", isDirectory: true)
let direct = try DownloadRules.save(input, parent: existingFolder, valid: { true }, fingerprint: fingerprint)
precondition(direct.deletingLastPathComponent().path == existingFolder.path)
precondition(direct.lastPathComponent == "a (2).zip")
precondition(!fm.fileExists(atPath: existingFolder.appendingPathComponent("RepoPocket").path))
try fm.removeItem(at: direct)
let neighbor = parent.appendingPathComponent("keep.txt")
try Data("untouched".utf8).write(to: neighbor)
let neighborText = try fingerprint(neighbor)
precondition(neighborText == "untouched")
precondition(try fingerprint(first) == "fixture")
var valid = true
do {
 _ = try DownloadRules.save(input, parent: parent, valid: { valid }, fingerprint: fingerprint, copy: { a,b in try fm.copyItem(at:a,to:b); valid = false })
 preconditionFailure("session bypass")
} catch { precondition(error is CancellationError) }
do {
 _ = try DownloadRules.save(input, parent: parent, valid: { true }, fingerprint: fingerprint, copy: { a,b in try Data("corrupt".utf8).write(to:b) })
 preconditionFailure("integrity bypass")
} catch { }
do {
 _ = try DownloadRules.save(input, parent: parent, valid: { true }, fingerprint: fingerprint, copy: { a,b in try Data("partial".utf8).write(to:b); throw NSError(domain:NSPOSIXErrorDomain,code:28) })
 preconditionFailure("ENOSPC ignored")
} catch { }
precondition(try fm.contentsOfDirectory(atPath: parent.appendingPathComponent("RepoPocket").path).sorted() == ["a (1).zip", "a.zip"])
let linked = root.appendingPathComponent("link")
try fm.createSymbolicLink(at: linked, withDestinationURL: parent)
do { _ = try DownloadRules.save(input, parent: linked, valid:{true}, fingerprint:fingerprint); preconditionFailure("symlink followed") } catch { }
precondition(DownloadRules.safeName("../file.zip") == "file.zip")
print("PASS production pure Swift rules: filename/collision, exclusive save, session switch, copy/integrity/ENOSPC rollback, symlink refusal; mock-only user data")
'''
  # Throwing expressions are evaluated outside precondition's non-throwing autoclosure.
  source = source.replace('precondition(try fingerprint(first) == "fixture")', 'let firstText = try fingerprint(first); precondition(firstText == "fixture")')
  source = source.replace('precondition(try fm.contentsOfDirectory(atPath: parent.appendingPathComponent("RepoPocket").path).sorted() == ["a (1).zip", "a.zip"])', 'let outputs = try fm.contentsOfDirectory(atPath: parent.appendingPathComponent("RepoPocket").path).sorted(); precondition(outputs == ["a (1).zip", "a.zip"])')
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'main.swift'; p.write_text(source)
   subprocess.run(['swiftc',str(p),'-o',d+'/test'],check=True)
   subprocess.run([d+'/test'],check=True)
if __name__=='__main__': unittest.main()
