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

    def test_startup_card_ui_and_safety(self):
        app = (REPO_ROOT / 'RepoPocket/RepoPocketApp.swift').read_text()
        card = (REPO_ROOT / 'RepoPocket/StartupUpdateCard.swift').read_text()
        for token in ['.sheet(isPresented: $startupSheetVisible', '.task(id: startupSheetQueued)',
                      '.onReceive(updateChecker.$startupRelease)', 'StartupUpdateCard(api: api',
                      'DownloadStore.shared.picker == nil', 'api.message.isEmpty',
                      'selectedTab = 4']:
            self.assertIn(token, app)
        for token in ['ScrollView {', 'Text(verbatim: notes)', 'prefix(16_384)',
                      'VStack(spacing: 6)', 'minHeight: 46', 'minHeight: 44',
                      '.presentationDetents', '.height(300)', '.presentationDragIndicator(.visible)',
                      '跳转TrollStore安装需启用 URL Scheme', 'TrollStore 安装', '暂不更新',
                      '关闭更新提示', 'checker.skipAndDismissStartupRelease(accountID: api.accountID)',
                      'TrollStoreInstaller.open(ipaURL: ipa)',
                      'session == AccountStore.generation', 'checker.release?.ipaURL == ipa',
                      'requestID == id', '前往应用更新']:
            self.assertIn(token, card)
        self.assertNotIn('SHA256', card)
        self.assertNotIn('.animation(', card)
        self.assertNotIn('Timer', card)
        self.assertNotIn('exit(', card)
        self.assertNotIn('UIApplication.shared.open', feature.split('    func download() {', 1)[0])
        self.assertLess(card.index('ScrollView {'), card.index('// The footer does not scroll'))
        # RC regression: reading an un-injected @EnvironmentObject traps on the first update.
        self.assertNotIn('@EnvironmentObject private var downloads', app)
        # The startup path must not evaluate other observable objects while SwiftUI runs body.
        self.assertNotIn('private var startupUpdateReady', app)
        queue = app.split('.onReceive(updateChecker.$startupRelease)', 1)[1].split('.sheet(isPresented: $startupSheetVisible', 1)[0]
        for foreign in ['accountPresentation.showing', 'DownloadStore.shared.picker', 'api.message.isEmpty']:
            self.assertNotIn(foreign, queue)
        self.assertIn('DownloadStore.shared.picker == nil', app.split('private func queueStartupSheet', 1)[1])

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
        self.assertIn('sources: [RepoPocket, Vendor/DebCodecs, SharedInbox]', (REPO_ROOT / 'project.yml').read_text())

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
    var canCheckAppUpdate = true
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
''' + 'enum AccountStore { static var generation = UUID() }\n' + Path(REPO_ROOT, 'RepoPocket/AppUpdateSessionRules.swift').read_text() + rules + Path(REPO_ROOT, 'RepoPocket/RepositorySafetyRules.swift').read_text() + checker + '''
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
    anonymous.canCheckAppUpdate = false
    let gated = UpdateChecker()
    await gated.check(api: anonymous)
    precondition(anonymous.calls == 0 && gated.message == "请登录账号")
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
    let automatic = UpdateChecker(installedVersion: { ("1.0.1", "5") })
    AppUpdateSessionRules.startupPromptOffered = false
    let autoAPI = GitHub("new"); autoAPI.accountID = "auto-fixture-" + UUID().uuidString
    await automatic.automaticCheck(api: autoAPI)
    await automatic.automaticCheck(api: autoAPI)
    precondition(autoAPI.calls == 1 && automatic.release != nil && automatic.message.isEmpty)
    automatic.leavePage(); automatic.enterPage()
    precondition(automatic.release != nil)
    await automatic.check(api: GitHub("automatic failure"), automatic: true)
    precondition(automatic.release != nil && automatic.message.isEmpty)
    await automatic.check(api: autoAPI)
    precondition(autoAPI.calls == 2) // Explicit manual check bypasses auto cooldown.
    precondition(automatic.startupRelease != nil)
    automatic.dismissStartupUpdate()
    precondition(automatic.startupRelease == nil && automatic.release != nil)
    await automatic.check(api: autoAPI, automatic: true)
    precondition(automatic.startupRelease == nil) // Dismissed prompt stays dismissed this session.
    let probeAPI = GitHub("new"); probeAPI.accountID = "probe-" + UUID().uuidString
    let probeKey = "RepoPocket.update.lastCheck." + probeAPI.accountID
    let lastDate = Date(); UserDefaults.standard.set(lastDate, forKey: probeKey)
    AppUpdateSessionRules.startupPromptOffered = false
    let probe = UpdateChecker(installedVersion: { ("1.0.3-rc.1", "3") })
    await probe.automaticCheck(api: probeAPI); await probe.automaticCheck(api: probeAPI)
    precondition(probeAPI.calls == 1 && probe.startupRelease != nil)
    precondition(UserDefaults.standard.object(forKey: probeKey) as? Date == lastDate)
    probe.dismissStartupUpdate()
    await probe.automaticCheck(api: probeAPI)
    precondition(probe.startupRelease == nil && probeAPI.calls == 1)
    AppUpdateSessionRules.startupPromptOffered = false
    let nextLaunch = UpdateChecker(installedVersion: { ("1.0.3-rc.1", "3") })
    await nextLaunch.automaticCheck(api: probeAPI)
    precondition(probeAPI.calls == 2 && nextLaunch.startupRelease != nil)
    // Dismissing the card remembers the version: the next cold launch stays quiet.
    let skippedTag = nextLaunch.startupRelease?.tag_name
    nextLaunch.skipAndDismissStartupRelease(accountID: probeAPI.accountID)
    precondition(UserDefaults.standard.string(forKey: AppUpdateRules.skippedKey(probeAPI.accountID)) == skippedTag)
    AppUpdateSessionRules.startupPromptOffered = false
    let quietLaunch = UpdateChecker(installedVersion: { ("1.0.3-rc.1", "3") })
    await quietLaunch.automaticCheck(api: probeAPI)
    precondition(probeAPI.calls == 3 && quietLaunch.startupRelease == nil && quietLaunch.release != nil)
    UserDefaults.standard.removeObject(forKey: AppUpdateRules.skippedKey(probeAPI.accountID))
    AppUpdateSessionRules.startupPromptOffered = false
    let promptedAgain = UpdateChecker(installedVersion: { ("1.0.3-rc.1", "3") })
    await promptedAgain.automaticCheck(api: probeAPI)
    precondition(probeAPI.calls == 4 && promptedAgain.startupRelease != nil)
    let officialAPI = GitHub("new"); officialAPI.accountID = probeAPI.accountID
    let official = UpdateChecker(installedVersion: { ("1.0.4", "3") })
    await official.automaticCheck(api: officialAPI)
    precondition(officialAPI.calls == 0 && official.startupRelease == nil)
    let noUpdateAPI = GitHub("latest"); noUpdateAPI.accountID = "latest-" + UUID().uuidString
    let noUpdate = UpdateChecker(installedVersion: { ("1.0.4", "3") })
    await noUpdate.automaticCheck(api: noUpdateAPI)
    precondition(noUpdate.release == nil && noUpdate.startupRelease == nil && noUpdate.message.isEmpty)
    precondition(manual.startupRelease == nil && timed.startupRelease == nil)
    print("PASS startup prompt, no auto-install, dismiss once, RC cold-launch cache bypass, official six-hour cache preserved, no latest/manual popup")
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
