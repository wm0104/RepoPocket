from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import unittest, shutil, subprocess, tempfile
rules = Path(REPO_ROOT, 'RepoPocket/DownloadRules.swift').read_text()
store = Path(REPO_ROOT, 'RepoPocket/DownloadStore.swift').read_text()
app = Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text()
account = Path(REPO_ROOT, 'RepoPocket/AccountManagement.swift').read_text()
class DownloadTests(unittest.TestCase):
 def test_launch_migrates_relative_labels_without_provider_io(self):
  initializer = store.split('    init() {', 1)[1].split('    private func resolve()', 1)[0]
  self.assertIn('DownloadRules.initialLabel(cached, hasBookmark:', initializer)
  self.assertNotIn('resolve()', initializer)
  self.assertNotIn('startAccessingSecurityScopedResource', initializer)
  self.assertNotIn('removeObject(forKey: bookmarkKey)', initializer)
 def test_display_and_share_use_the_same_destination_as_save(self):
  self.assertIn('label = DownloadRules.destinationFolder(in: url).path', store)
  self.assertNotIn('label = url.lastPathComponent', store)
  self.assertIn('DownloadRules.destinationFolder(in: parent).standardizedFileURL.path', store)
 def test_large_file_transaction_runs_off_main_and_can_be_cancelled(self):
  self.assertIn('func persist(_ temporary: URL, session: UUID) async throws -> URL', store)
  self.assertIn('Task.detached(priority: .utility)', store)
  self.assertIn('withTaskCancellationHandler', store)
  self.assertIn('Task.isCancelled', store)
  for name in ['RepoPocketApp.swift', 'UploadView.swift', 'UpdateFeature.swift', 'WorkflowViews.swift', 'ReleaseManagementUI.swift']:
   self.assertIn('try await DownloadStore.shared.persist(', Path(REPO_ROOT, 'RepoPocket', name).read_text())

 def test_real_callsites_and_lifecycle(self):
  for text in ['resolvingBookmarkData', 'bookmarkDataIsStale', 'startAccessingSecurityScopedResource', 'stopAccessingSecurityScopedResource', 'NSFileCoordinator', 'volumeAvailableCapacityForImportantUsageKey', 'LocalStore.snapshotFileSHA256', 'AccountStore.generation']:
   self.assertIn(text, store)
  self.assertNotIn('Data(contentsOf:', store + rules)
  self.assertNotIn('downloadsDirectory', store)
  self.assertIn('DownloadStore.shared.persist(temporary, session: generation)', app)
  upload = Path(REPO_ROOT, 'RepoPocket/UploadView.swift').read_text()
  self.assertIn('api.downloadAsset(repo, asset: asset)', upload)
  self.assertIn('DownloadStore.shared.persist(temporary, session: generation)', upload)
  update = Path(REPO_ROOT, 'RepoPocket/UpdateFeature.swift').read_text()
  self.assertIn('DownloadStore.shared.persist(file, session: accountSession)', update)
  self.assertNotIn('removeItem(at: downloaded)', update)
  self.assertIn('archive.extract', update)
  self.assertIn('shareScope(for: url)', app)
  self.assertIn('completionWithItemsHandler', app)
  self.assertIn('coordinator.release()', app)
  self.assertIn('ZStack { AccountRootView().id(accountID) }', app)
  self.assertIn('accounts = AccountStore.accounts', account)
  self.assertIn('if active { close() }', account)
  self.assertIn('Button("完成") { close() }', account)
  self.assertNotIn('Button("完成") { close() }.disabled', account)
  self.assertIn('verification?.cancel()', account)
  self.assertIn('try Task.checkCancellation()\n        try CredentialStore.save', Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text())
  cache = Path(REPO_ROOT, 'RepoPocket/CacheSettings.swift').read_text()
  self.assertIn('confirmationDialog', cache)
  self.assertIn('clearIfIdle()', cache)
  self.assertIn('downloads.operations > 0', cache)
  self.assertIn('CacheRules.clear(root: root', cache)
  redirect = Path(REPO_ROOT, 'RepoPocket/ReleaseAssetRedirectPolicy.swift').read_text()
  self.assertIn('redirected.setValue(nil, forHTTPHeaderField: "Authorization")', redirect)
  self.assertIn('canCheckAppUpdate', Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text())
 @unittest.skipUnless(shutil.which('swiftc'), 'Pure Swift mocks run in Actions; no Apple device data touched')
 def test_production_rules_mock(self):
  source = rules + r'''
let fm = FileManager.default
precondition(DownloadRules.initialLabel("File Provider Storage/RepoPocket", hasBookmark: true) == "已保留下载位置；下次下载时更新完整路径，也可重新选择。")
precondition(DownloadRules.initialLabel(nil, hasBookmark: true) == "已保留下载位置；下次下载时更新完整路径，也可重新选择。")
precondition(DownloadRules.initialLabel("/provider/Downloads/RepoPocket", hasBookmark: true) == "/provider/Downloads/RepoPocket")
precondition(DownloadRules.initialLabel("/provider/Downloads/RepoPocket", hasBookmark: false) == "请选择保存位置")
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
let cache = root.appendingPathComponent("Caches")
try fm.createDirectory(at: cache, withIntermediateDirectories:true)
for name in ["RepoPocketCache", "RepoPocketAvatars", "Documents", "Downloads", "workspaces", "drafts", "Keychain"] { try fm.createDirectory(at:cache.appendingPathComponent(name),withIntermediateDirectories:true) }
var removed:[String] = []
do { try CacheRules.clear(root:cache,busy:true) { removed.append($0.lastPathComponent) }; preconditionFailure("busy ignored") } catch { precondition(removed.isEmpty) }
try CacheRules.clear(root:cache,busy:false) { removed.append($0.lastPathComponent) }
precondition(removed == ["RepoPocketCache", "RepoPocketAvatars"])
try fm.removeItem(at:cache.appendingPathComponent("RepoPocketAvatars"))
try fm.createSymbolicLink(at:cache.appendingPathComponent("RepoPocketAvatars"),withDestinationURL:parent)
do { try CacheRules.clear(root:cache,busy:false) { _ in }; preconditionFailure("cache symlink followed") } catch { }
print("PASS production pure Swift rules: filename/collision, exclusive save, session switch, copy/integrity/ENOSPC rollback, symlink refusal, cache whitelist/busy; mock-only user data")
'''
  # Throwing expressions are evaluated outside precondition's non-throwing autoclosure.
  source = source.replace('precondition(try fingerprint(first) == "fixture")', 'let firstText = try fingerprint(first); precondition(firstText == "fixture")')
  source = source.replace('precondition(try fm.contentsOfDirectory(atPath: parent.appendingPathComponent("RepoPocket").path).sorted() == ["a (1).zip", "a.zip"])', 'let outputs = try fm.contentsOfDirectory(atPath: parent.appendingPathComponent("RepoPocket").path).sorted(); precondition(outputs == ["a (1).zip", "a.zip"])')
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'main.swift'; p.write_text(source)
   subprocess.run(['swiftc',str(p),'-o',d+'/test'],check=True)
   subprocess.run([d+'/test'],check=True)
if __name__=='__main__': unittest.main()
