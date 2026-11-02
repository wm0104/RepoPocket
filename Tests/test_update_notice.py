"""Network-free production UpdateChecker lifecycle regressions (macOS Swift)."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import unittest, tempfile, subprocess, shutil
feature = Path(REPO_ROOT, 'RepoPocket/UpdateFeature.swift').read_text()

class NoticeTests(unittest.TestCase):
    def test_source_contracts(self):
        self.assertIn('UpdateNoticeRules.failureNanoseconds', feature)
        self.assertIn('noticeTask?.cancel()', feature)
        self.assertIn('!Task.isCancelled', feature)
        self.assertIn('.onDisappear { if !updateChecker.sharing { updateChecker.leavePage() } }', Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text())
        self.assertIn('self.generation == token', feature)
        self.assertNotIn('（build', feature)
        self.assertIn('CFBundleVersion', Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text())
        download = feature.split('    func download() {', 1)[1].split('final class UpdateDownloadDelegate', 1)[0]
        self.assertIn('clearNotice()', download)
        self.assertNotIn('showTransient(', download.split('downloading = true', 1)[1])
        self.assertIn('guard self.generation == token else { throw CancellationError() }', download)
        self.assertIn('defer { if self.generation == token', download)

    def test_update_notification_ui_and_safety(self):
        app = (REPO_ROOT / 'RepoPocket/RepoPocketApp.swift').read_text()
        badge = (REPO_ROOT / 'RepoPocket/UpdateTabBadge.swift').read_text()
        # The startup card is gone: automatic checks only light the 设置 tab dot.
        self.assertFalse((REPO_ROOT / 'RepoPocket/StartupUpdateCard.swift').exists())
        for gone in ['startupSheetVisible', 'startupSheetQueued', 'StartupUpdateCard',
                     'startupRelease', 'queueStartupSheet', 'selectedTab = 4']:
            self.assertNotIn(gone, app)
            self.assertNotIn(gone, feature)
        self.assertIn('UpdateTabBadge(tabIndex: 3, isVisible: updateChecker.hasUpdate)', app)
        self.assertIn('appEntryCheck(api: api)', app)
        # A subtle 10pt dot with a bar-coloured ring, never a number or a custom image.
        for token in ['width: 10, height: 10', 'layer.cornerRadius = 5', 'cornerRadius = 7',
                      'backgroundColor = .systemRed', 'backgroundColor = .systemBackground',
                      'isUserInteractionEnabled = false']:
            self.assertIn(token, badge)
        self.assertNotIn('.badge(', app)
        self.assertNotIn('Image(', badge)
        self.assertNotIn('.animation(', badge)
        self.assertNotIn('Timer', badge)
        # The verdict comes from the release the checker already holds.
        self.assertIn('var hasUpdate: Bool { release != nil }', feature)
        row = feature.split('Text("应用更新")', 1)[1].split('Menu {', 1)[0]
        self.assertIn('Text(release.availableVersionText)', row)
        self.assertNotIn('UIApplication.shared.open', feature.split('    func download() {', 1)[0])
        # The startup path must not evaluate other observable objects while SwiftUI runs body.
        self.assertNotIn('private var startupUpdateReady', app)
        self.assertNotIn('@EnvironmentObject private var downloads', app)

    def test_environment_objects_resolve(self):
        import re
        views = sorted((REPO_ROOT / 'RepoPocket').glob('*.swift'))
        owners, required, injected = {}, [], set()
        for path in views:
            text = path.read_text()
            for name, annotation, ctor in re.findall(
                    r'@(?:StateObject|ObservedObject)\s+(?:private\s+)?var\s+(\w+)\s*(?::\s*(\w+))?\s*=\s*(\w+)', text):
                owners.setdefault(name, annotation or ctor)
            for name, typ in re.findall(r'@EnvironmentObject\s+(?:private\s+)?var\s+(\w+)\s*:\s*(\w+)', text):
                required.append((name, typ))
            injected.update(re.findall(r'\.environmentObject\((\w+)\)', text))
        missing = [f'{name}: {typ}' for name, typ in required
                   if name not in injected and not any(owners.get(c) == typ for c in injected)]
        self.assertEqual(missing, [], f'@EnvironmentObject without injection: {missing}')

    def test_first_launch_network_warmup(self):
        app = (REPO_ROOT / 'RepoPocket/RepoPocketApp.swift').read_text()
        warm = (REPO_ROOT / 'RepoPocket/NetworkWarmup.swift').read_text()
        self.assertIn('.task { await NetworkWarmup.runOnceIfNeeded() }', app)
        self.assertIn('RepoPocket.network.warmed.v1', warm)
        self.assertIn('httpMethod = "HEAD"', warm)
        self.assertNotIn('Authorization', warm)
        self.assertNotIn('CredentialStore', warm)
        self.assertIn('type: application', (REPO_ROOT / 'project.yml').read_text())
        self.assertIn('sources: [RepoPocket, Vendor/DebCodecs, Vendor/NativeGit, SharedInbox]', (REPO_ROOT / 'project.yml').read_text())

    def test_pasted_token_survives_failed_verification(self):
        accounts = (REPO_ROOT / 'RepoPocket/AccountManagement.swift').read_text()
        app = (REPO_ROOT / 'RepoPocket/RepoPocketApp.swift').read_text()
        helper = (REPO_ROOT / 'RepoPocket/TokenVerification.swift').read_text()
        failures = (REPO_ROOT / 'RepoPocket/WorkspaceSelection.swift').read_text()
        # The old flow cleared the field before the first request, so a permission-prompt
        # interruption forced the user to paste the Token again.
        self.assertNotIn('let credential = token; token = ""', accounts)
        self.assertNotIn('let credential = token; token = ""', app)
        self.assertIn('TokenVerification.submit(credential)', accounts)
        self.assertIn('TokenVerification.submit(credential)', app)
        self.assertIn('token = ""', accounts.split('TokenVerification.submit', 1)[1].split('catch', 1)[0])
        self.assertIn('token = ""', app.split('TokenVerification.submit', 1)[1].split('catch', 1)[0])
        self.assertIn('RefreshFailure.isTransient(error)', helper)
        for code in ['NSURLErrorNotConnectedToInternet', 'NSURLErrorNetworkConnectionLost',
                     'NSURLErrorTimedOut', 'NSURLErrorDataNotAllowed']:
            self.assertIn(code, failures)
        self.assertIn('static func isTransient', failures)
        self.assertNotIn('Authorization', helper)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift available on Actions')
    def test_production_checker_with_mock_api(self):
        checker = feature.split('@MainActor final class UpdateChecker', 1)[1].split('    func download() {', 1)[0]
        checker = '@MainActor final class UpdateChecker' + checker + '\n}\n'
        rules = Path(REPO_ROOT, 'RepoPocket/AppUpdateRules.swift').read_text()
        source = '''import Foundation
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
protocol ObservableObject {}
final class UpdateDownloadDelegate: NSObject {}
struct AppError: Error, LocalizedError { let text: String; var errorDescription: String? { text } }
@MainActor final class GitHub {
    let delay: UInt64
    let failure: String
    init(_ failure: String, delay: UInt64 = 0) { self.failure = failure; self.delay = delay }
    var isCurrentSession = true
    var accountID = "fixture"
    var canCheckOfficialUpdate = true
    var calls = 0
    func officialAppUpdateData() async throws -> Data {
        calls += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if failure == "latest" || failure == "new" {
            let tag = failure == "new" ? "v999.0.0" : "v0.0.0"
            return try JSONSerialization.data(withJSONObject: ["tag_name": tag, "html_url": "https://github.com/wm0104/RepoPocket/releases/tag/" + tag, "draft": false, "prerelease": false, "assets": []] as [String: Any])
        }
        throw AppError(text: failure)
    }
}
''' + 'enum AccountStore { static var generation = UUID() }\n' + Path(REPO_ROOT, 'RepoPocket/AppUpdateSessionRules.swift').read_text() + rules + Path(REPO_ROOT, 'RepoPocket/ChinaDate.swift').read_text() + Path(REPO_ROOT, 'RepoPocket/RepositorySafetyRules.swift').read_text() + checker + '''
@MainActor final class MockNoticeClock {
    var delays: [UInt64] = []
    var waits: [CheckedContinuation<Void, Error>] = []
    func sleep(_ nanoseconds: UInt64) async throws {
        delays.append(nanoseconds)
        try await withCheckedThrowingContinuation { waits.append($0) }
    }
    func fire() { waits.removeFirst().resume() }
}
@main struct Tests {
 @MainActor static func main() async throws {
    let anonymous = GitHub("latest")
    anonymous.canCheckOfficialUpdate = false
    let gated = UpdateChecker()
    await gated.check(api: anonymous)
    precondition(anonymous.calls == 0 && gated.message == "请重新打开 App")
    let manual = UpdateChecker()
    let counted = GitHub("latest", delay: 100_000_000)
    for _ in 0..<3 { manual.enterPage(); manual.leavePage() }
    manual.enterPage()
    precondition(counted.calls == 0)
    let clicked = Task { await manual.check(api: counted) }
    for _ in 0..<100 { if counted.calls == 1 { break }; await Task.yield() }
    await manual.check(api: counted)
    await clicked.value
    precondition(counted.calls == 1 && !manual.checking)
    manual.leavePage(); manual.enterPage()
    precondition(counted.calls == 1)
    manual.leavePage()
    print("PASS settings entry/exit zero API calls; manual button one call; busy duplicate rejected")
    let clock = MockNoticeClock()
    let timed = UpdateChecker(noticeSleep: { try await clock.sleep($0) }, installedVersion: { ("1.0.3", "11") })
    await timed.check(api: GitHub("latest"))
    for _ in 0..<100 { if !clock.waits.isEmpty { break }; await Task.yield() }
    precondition(clock.delays == [2_000_000_000] && timed.message == "已是最新版本")
    clock.fire()
    for _ in 0..<100 { if timed.message.isEmpty { break }; await Task.yield() }
    precondition(timed.message.isEmpty)
    await timed.check(api: GitHub("new"))
    precondition(timed.release != nil && clock.delays.count == 1)
    timed.leavePage()
    await timed.check(api: GitHub("failed"))
    for _ in 0..<100 { if !clock.waits.isEmpty { break }; await Task.yield() }
    precondition(clock.delays.last == 6_000_000_000)
    timed.leavePage(); clock.fire(); await Task.yield()
    precondition(timed.message.isEmpty && timed.release != nil)
    print("PASS deterministic production clock: latest 2s, failure 6s, new release untimed, leave-generation protection")
    precondition(AppUpdateSessionRules.cooldown == 15 * 60)
    let automatic = UpdateChecker(installedVersion: { ("1.0.1", "5") })
    let autoAPI = GitHub("new"); autoAPI.accountID = "auto-fixture-" + UUID().uuidString
    let autoKey = "RepoPocket.update.lastCheck." + autoAPI.accountID
    await automatic.appEntryCheck(api: autoAPI)
    await automatic.appEntryCheck(api: autoAPI)
    // Launch and foreground share one attempt per entry and one 15-minute per-account window.
    precondition(autoAPI.calls == 1 && automatic.release != nil && automatic.hasUpdate && automatic.message.isEmpty)
    precondition(UserDefaults.standard.object(forKey: autoKey) as? Date != nil)
    automatic.leavePage(); automatic.enterPage()
    // Opening and leaving Settings keeps the dot: the release is remembered.
    precondition(automatic.hasUpdate)
    await automatic.appEntryCheck(api: autoAPI)
    precondition(autoAPI.calls == 1) // Still inside the 15-minute window.
    UserDefaults.standard.set(Date().addingTimeInterval(-16 * 60), forKey: autoKey)
    await automatic.appEntryCheck(api: autoAPI)
    precondition(autoAPI.calls == 2 && automatic.release != nil && automatic.hasUpdate)
    await automatic.check(api: GitHub("automatic failure"), automatic: true)
    precondition(automatic.release != nil && automatic.message.isEmpty)
    await automatic.check(api: autoAPI)
    precondition(autoAPI.calls == 3) // Explicit manual check bypasses auto cooldown.
    precondition(automatic.hasUpdate)
    let probeAPI = GitHub("new"); probeAPI.accountID = "probe-" + UUID().uuidString
    let probeKey = "RepoPocket.update.lastCheck." + probeAPI.accountID
    let lastDate = Date(); UserDefaults.standard.set(lastDate, forKey: probeKey)
    let probe = UpdateChecker(installedVersion: { ("1.0.3-rc.1", "3") })
    await probe.appEntryCheck(api: probeAPI); await probe.appEntryCheck(api: probeAPI)
    precondition(probeAPI.calls == 1 && probe.hasUpdate)
    // The probe neither inherits nor resets the official app's per-account window.
    precondition(UserDefaults.standard.object(forKey: probeKey) as? Date == lastDate)
    let officialAPI = GitHub("new"); officialAPI.accountID = probeAPI.accountID
    let official = UpdateChecker(installedVersion: { ("1.0.4", "3") })
    await official.appEntryCheck(api: officialAPI)
    precondition(officialAPI.calls == 0 && official.release == nil && !official.hasUpdate)
    let noUpdateAPI = GitHub("latest"); noUpdateAPI.accountID = "latest-" + UUID().uuidString
    let noUpdate = UpdateChecker(installedVersion: { ("1.0.4", "3") })
    await noUpdate.appEntryCheck(api: noUpdateAPI)
    precondition(noUpdate.release == nil && !noUpdate.hasUpdate && noUpdate.message.isEmpty)
    precondition(manual.release == nil && timed.hasUpdate)
    print("PASS app entry check, 15-minute window, silent automatic failure, RC probe bypass, no startup card state")
    let switched = UpdateChecker()
    let lateAPI = GitHub("new", delay: 100_000_000)
    let switchedTask = Task { await switched.check(api: lateAPI) }
    for _ in 0..<100 { if lateAPI.calls == 1 { break }; await Task.yield() }
    AccountStore.generation = UUID()
    await switchedTask.value
    precondition(switched.release == nil)
    print("PASS production automatic once, manual bypass, tab retention, silent failure retains known update, account generation ignores late result")
    let checker = UpdateChecker()
    await checker.check(api: GitHub("first"))
    precondition(checker.message == "检查失败，请稍后重试")
    await Task.yield()
    for _ in 0..<100 {
        if checker.message.isEmpty { break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    precondition(checker.message.isEmpty)
    await checker.check(api: GitHub("速率旧消息"))
    try await Task.sleep(nanoseconds: 1_000_000_000)
    await checker.check(api: GitHub("凭据新消息"))
    try await Task.sleep(nanoseconds: 5_300_000_000)
    precondition(checker.message == "请重新登录")
    checker.leavePage()
    precondition(checker.message.isEmpty && !checker.checking && !checker.downloading && checker.release == nil)
    let late = Task { await checker.check(api: GitHub("late", delay: 200_000_000)) }
    try await Task.sleep(nanoseconds: 50_000_000)
    checker.leavePage()
    await checker.check(api: GitHub("current"))
    await late.value
    precondition(checker.message == "检查失败，请稍后重试" && !checker.checking)
    checker.downloading = true
    try await Task.sleep(nanoseconds: 6_200_000_000)
    precondition(checker.message == "检查失败，请稍后重试")
    checker.cancelDownload()
    precondition(!checker.downloading && checker.message == "已取消下载。")
    checker.leavePage()
    precondition(checker.message.isEmpty)
    print("PASS production checker mocks: six-second expiry, new-message immunity, leave/reenter, stale request rejection, download timer protection, cancel/reset")
 }
}
'''
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'notice.swift'; path.write_text(source)
            subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', d + '/test'], check=True)
            subprocess.run([d + '/test'], check=True)

if __name__ == '__main__': unittest.main()
