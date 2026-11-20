from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import unittest, shutil, subprocess, tempfile
rules = Path(REPO_ROOT, 'RepoPocket/DownloadRules.swift').read_text()
store = Path(REPO_ROOT, 'RepoPocket/DownloadStore.swift').read_text()
app = Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text()
account = Path(REPO_ROOT, 'RepoPocket/AccountManagement.swift').read_text()
class DownloadTests(unittest.TestCase):
 def test_remembers_the_user_folder_without_loading_or_deleting_old_history(self):
  for token in ['RepoPocket.download.folder.v1', 'RepoPocket.download.label.v1', 'resolvingBookmarkData', 'startAccessingSecurityScopedResource', 'bookmarkDataIsStale: &stale', 'if stale', 'func choose()', 'func selected(', 'WorkspaceImportRequest(kind: .folder)']:
   self.assertIn(token, store)
  self.assertIn('DownloadRules.initialLabel', store)
  self.assertNotIn('NSHomeDirectory()', store)
  self.assertNotIn('history.json', store)
  self.assertNotIn('Library/Application Support/Downloads', store)
  self.assertNotIn('removeObject(forKey: bookmarkKey)', store)
 def test_authorization_cancellation_and_selection_errors_are_observable(self):
  authorize = store.split('    func requireAuthorization()', 1)[1].split('    func selected(', 1)[0]
  for token in ['Task.checkCancellation()', 'withTaskCancellationHandler', 'withCheckedThrowingContinuation', 'waiters.removeValue(forKey: id)', 'continuation.resume(throwing: CancellationError())']:
   self.assertIn(token, authorize)
  selected = store.split('    func selected(', 1)[1].split('    func begin()', 1)[0]
  for token in ['guard operations == 0', 'waiters = [:]', 'waiter.resume(with: result)', 'error.localizedDescription']:
   self.assertIn(token, selected)
  self.assertIn('func clearError()', store)
  self.assertIn('guard operations == 0, picker == nil', store)
 def test_large_file_transaction_runs_off_main_and_can_be_cancelled(self):
  for token in ['func persist(_ temporary: URL, session: UUID', 'Task.detached(priority: .utility)', 'withTaskCancellationHandler', 'Task.isCancelled', 'volumeAvailableCapacityForImportantUsageKey', 'LocalStore.snapshotFileSHA256']:
   self.assertIn(token, store)
  for name in ['RepoPocketApp.swift', 'WorkflowViews.swift', 'ReleaseAssetDownload.swift']:
   current = Path(REPO_ROOT, 'RepoPocket', name).read_text()
   self.assertIn('.persist(', current)
   self.assertIn('.requireAuthorization()', current)
  self.assertIn('NSFileCoordinator().coordinate(writingItemAt: parent', store)
  self.assertIn('defer { parent.stopAccessingSecurityScopedResource() }', store)
  self.assertIn('DownloadStore.shared.persist(file, session: accountSession)', Path(REPO_ROOT, 'RepoPocket/UpdateFeature.swift').read_text())
 def test_settings_keep_folder_choice_and_update(self):
  self.assertNotIn('CacheSettingsSection', app)
  self.assertIn('NativeMenuItem(id: "download-folder"', app)
  self.assertIn('downloads.choose()', app)
  self.assertIn('AppUpdateSection(api: api, checker: updateChecker, connected: true)', app)
  self.assertNotIn('清缓存', store)

 def test_update_share_keeps_its_original_folder_authorization(self):
  update = Path(REPO_ROOT, 'RepoPocket/UpdateFeature.swift').read_text()
  self.assertIn('func shareBookmark(for url: URL) -> Data?', store)
  sharing = store.split('    func shareScope(', 1)[1]
  self.assertIn('bookmark: Data? = nil', sharing)
  original = sharing.split('if let bookmark {', 1)[1].split('} else {', 1)[0]
  self.assertIn('resolvingBookmarkData: bookmark', original)
  self.assertNotIn('resolve()', original)
  self.assertNotIn('UserDefaults.standard.set', sharing)
  self.assertNotIn('label =', sharing)
  self.assertIn('private(set) var downloadedBookmark: Data?', update)
  for line in update.splitlines():
   if 'downloaded = nil' in line:
    self.assertIn('downloadedBookmark = nil', line)
  saved = update.split('let saved = try await DownloadStore.shared.persist(file, session: accountSession)', 1)[1]
  self.assertLess(saved.index('self.downloadedBookmark = DownloadStore.shared.shareBookmark(for: saved)'), saved.index('self.downloaded = saved'))
  self.assertIn('SharedFile(url: file, bookmark: checker.downloadedBookmark)', update)
  self.assertIn('ShareSheet(url: $0.url, bookmark: $0.bookmark)', update)
  shared = app.split('struct SharedFile:', 1)[1].split('struct ShareSheet:', 1)[0]
  self.assertIn('var bookmark: Data? = nil', shared)
  sheet = app.split('struct ShareSheet:', 1)[1].split('struct RepositoriesView:', 1)[0]
  self.assertIn('var bookmark: Data? = nil', sheet)
  self.assertLess(sheet.index('shareScope(for: url, bookmark: bookmark)'), sheet.index('UIActivityViewController(activityItems:'))
  self.assertIn('completionWithItemsHandler = { _, _, _, _ in context.coordinator.release() }', sheet)
  self.assertIn('coordinator: Coordinator) { coordinator.release() }', sheet)
  self.assertIn('scope?.stopAccessingSecurityScopedResource(); scope = nil', sheet)

 def test_download_error_body_is_read_with_a_fixed_memory_bound(self):
  github = Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text()
  download = github.split('    private func download(', 1)[1].split('    // These bounded endpoints', 1)[0]
  self.assertNotIn('Data(contentsOf:', download)
  self.assertIn('handle.read(upToCount: 8192)', download)
  self.assertIn('defer { try? handle.close() }', download)

 def test_real_callsites_and_lifecycle(self):
  self.assertIn('AccountStore.generation', store)
  self.assertIn('api.downloadZIP(repo, branch: activeBranch, progress:', app)
  self.assertIn('zipRequest == request', app)
  downloader = Path(REPO_ROOT, 'RepoPocket/ReleaseAssetDownload.swift').read_text()
  self.assertIn('api.downloadManagedAssetWithProgress(repo, asset: asset, transfer: update)', downloader)
  management = Path(REPO_ROOT, 'RepoPocket/ReleaseManagementUI.swift').read_text()
  self.assertIn('defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }', management)
  self.assertIn('.onDisappear { state.cancel() }', management)
  update = Path(REPO_ROOT, 'RepoPocket/UpdateFeature.swift').read_text()
  self.assertIn('DownloadStore.shared.persist(file, session: accountSession)', update)
  self.assertNotIn('removeItem(at: downloaded)', update)
  self.assertIn('archive.extract', update)
  self.assertIn('ZStack { AccountRootView().id(accountID) }', app)
  self.assertIn('accounts = AccountStore.accounts', account)
  self.assertIn('verification?.cancel()', account)
  self.assertIn('redirected.setValue(nil, forHTTPHeaderField: "Authorization")', Path(REPO_ROOT, 'RepoPocket/ReleaseAssetRedirectPolicy.swift').read_text())
 @unittest.skipUnless(shutil.which('swiftc'), 'Production folder authorization executes on macOS')
 def test_production_folder_authorization_releases_every_waiter(self):
  source = r'''
import Foundation
import Combine
let domain = "RepoPocket-folder-fixture-" + UUID().uuidString
let fixtureDefaults = UserDefaults(suiteName: domain)!
struct WorkspaceImportRequest { enum Kind { case folder }; let kind: Kind }
struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
enum AccountStore { static var generation = UUID() }
enum RefreshFailure { static func isCancellation(_ error: Error) -> Bool { error is CancellationError } }
enum LocalStore { static func snapshotFileSHA256(_ file: URL) throws -> String { "unused" } }
extension Notification.Name { static let githubAccountChanged = Notification.Name("fixture-account-changed") }
''' + rules + store.replace('UserDefaults.standard', 'fixtureDefaults') + r'''
@main struct Run {
 @MainActor static func wait(_ ready: () -> Bool) async { while !ready() { await Task.yield() } }
 @MainActor static func cancelled(_ task: Task<Void, Error>) async {
  do { try await task.value; preconditionFailure("Authorization unexpectedly succeeded") }
  catch { precondition(error is CancellationError) }
 }
 @MainActor static func main() async {
  defer { fixtureDefaults.removePersistentDomain(forName: domain) }
  let store = DownloadStore()
  let dismissed = Task { try await store.requireAuthorization() }
  await wait { store.picker != nil }
  store.selected(nil); store.selected(nil)
  await cancelled(dismissed)
  precondition(store.picker == nil && store.error.isEmpty)
  let first = Task { try await store.requireAuthorization() }
  await wait { store.picker != nil }
  first.cancel(); await cancelled(first)
  await wait { store.picker == nil }
  let changed = Task { try await store.requireAuthorization() }
  await wait { store.picker != nil }
  AccountStore.generation = UUID()
  NotificationCenter.default.post(name: .githubAccountChanged, object: nil)
  await cancelled(changed)
  precondition(store.picker == nil)
  store.begin(); store.choose(); precondition(store.picker == nil)
  store.selected([URL(fileURLWithPath: "/fixture")])
  precondition(!store.error.isEmpty && fixtureDefaults.data(forKey: "RepoPocket.download.folder.v1") == nil)
  store.selected(nil); precondition(!store.error.isEmpty)
  store.end(); store.clearError(); store.choose()
  precondition(store.picker != nil && store.error.isEmpty)
  store.selected(nil)
  print("PASS production folder authorization: cancellation, dismissal, account changes, active-operation guard and visible selection errors")
 }
}
'''
  with tempfile.TemporaryDirectory() as folder:
   path = Path(folder) / 'main.swift'; path.write_text(source, encoding='utf-8')
   subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', folder + '/test'], check=True)
   subprocess.run([folder + '/test'], check=True, timeout=30)
 @unittest.skipUnless(shutil.which('swiftc'), 'Production download transport runs on macOS')
 def test_production_download_error_and_temporary_file_lifecycle(self):
  github = Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text()
  download = '    func download(' + github.split('    private func download(', 1)[1].split('    // These bounded endpoints', 1)[0]
  progress_support = 'struct ReleaseDownloadProgress' + Path(REPO_ROOT, 'RepoPocket/ReleaseAssetDownload.swift').read_text().split('struct ReleaseDownloadProgress', 1)[1]
  redirect_support = Path(REPO_ROOT, 'RepoPocket/ReleaseAssetRedirectPolicy.swift').read_text()
  source = rules + '\n' + progress_support + '\n' + redirect_support + r'''
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
extension ReleaseAssetDownloadDelegate {
    // This fixture isolates GitHub's HTTP/file lifecycle, not URLSession routing.
    @MainActor func download(using session: DownloadTransport, request: URLRequest) async throws -> (URL, URLResponse) {
        try await session.download(for: request, delegate: self)
    }
}
@MainActor final class GitHub {
    let session: DownloadTransport
    var active = true
    var isCurrentSession: Bool { active }
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
