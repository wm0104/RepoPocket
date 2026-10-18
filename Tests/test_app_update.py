from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import unittest, tempfile, subprocess, shutil

rules = Path(REPO_ROOT, 'RepoPocket/AppUpdateRules.swift').read_text()
feature = Path(REPO_ROOT, 'RepoPocket/UpdateFeature.swift').read_text()

class UpdateTests(unittest.TestCase):
    def test_manual_safe_contract(self):
        self.assertIn('.task { updateChecker.enterPage() }', Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text())
        entry = feature.split('func enterPage()', 1)[1].split('private func clearNotice', 1)[0]
        self.assertNotIn('check(api:', entry)
        self.assertNotIn('officialAppUpdateData', entry)
        self.assertEqual(feature.count('await checker.check(api: api)'), 1)
        self.assertNotIn('forHTTPHeaderField: "Authorization"', feature)
        # The authorized TrollStore handoff is isolated from the normal verified download path.
        for forbidden in ['apple-magnifier://', 'URLQueryItem(name: "url"']:
            self.assertNotIn(forbidden, feature)
        self.assertIn('TrollStoreInstallRules.installURL(for: ipa)', feature)
        self.assertIn('Button("下载更新")', feature)
        self.assertIn('不经过 RepoPocket 的本地 SHA256 校验', feature)
        for value in ['downloadTask?.cancel()', 'snapshotFileSHA256', 'archive.extract', 'HTTPURLResponse', 'https://github.com/wm0104/RepoPocket/releases']:
            self.assertIn(value, feature)
        self.assertIn('AppUpdateSection(api: api, checker: updateChecker)', Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text())
        api = Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text()
        update = api.split('func officialAppUpdateData()', 1)[1].split('func descriptionContext', 1)[0]
        self.assertEqual(update.count('try ensureActiveAccount()'), 2)
        self.assertIn('CredentialStore.read(account: accountID)', api)
        self.assertIn('guard canCheckOfficialUpdate else', update)
        # Signed-out checks build the request directly and attach the token only when present.
        self.assertIn('URLRequest(url: endpoint)', update)
        self.assertNotIn('var r = try request(endpoint)', update)
        self.assertIn('let authenticated = !token.isEmpty', update)
        self.assertIn('if authenticated { r.setValue("Bearer \\(token)"', update)
        self.assertIn('guard api.canCheckOfficialUpdate else', feature)
        self.assertIn('session.data(for: r, delegate: OfficialUpdateRedirectPolicy())', update)
        self.assertIn('https://api.github.com/repos/wm0104/RepoPocket/releases/latest', update)
        self.assertNotIn('forHTTPHeaderField: "Authorization"', feature.split('func download()', 1)[1])
        redirect = Path(REPO_ROOT, 'RepoPocket/OfficialUpdateRedirectPolicy.swift').read_text()
        self.assertIn('completionHandler(nil)', redirect)
        self.assertNotIn('completionHandler(request)', redirect)
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler is available in macOS Actions')
    def test_production_version_and_asset_rules(self):
        api = Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text()
        source = 'import Foundation\n' + api[api.index('struct AppError:'):api.index('struct GitHubAPIError:')] + Path(REPO_ROOT, 'RepoPocket/AppUpdateSessionRules.swift').read_text() + rules.replace('import Foundation', '') + r'''
precondition(AppVersion("1.0.5")! < AppVersion("1.0.5.1")!)
precondition(AppVersion("1.0.5.2")! < AppVersion("1.0.5.10")!)
precondition(AppVersion("1.0.5.99")! < AppVersion("1.0.6")!)
precondition(AppVersion("1.0.5.0")! == AppVersion("1.0.5")!)
precondition(AppVersion("1.0.5.1-rc.1")! < AppVersion("1.0.5.1")!)
for bad in ["1.0.5.01","1.0.5.1.0","1.0.5.","1.0.5.x"] { precondition(AppVersion(bad) == nil) }
precondition(AppVersion("1.0.9")! < AppVersion("1.0.10")!)
precondition(AppVersion("1.0.1-rc.9")! < AppVersion("1.0.1-rc.10")!)
precondition(AppVersion("1.0.1-rc.10")! < AppVersion("1.0.1")!)
precondition(AppVersion("1.0.1+8")! == AppVersion("1.0.1+7")!)
for bad in ["nightly", "1.0", "01.0.1", "1.0.1-", "1.0.1+", "1.0.1-01"] { precondition(AppVersion(bad) == nil) }
func release(_ tag: String, _ draft: Bool = false, _ pre: Bool = false, _ assets: String = "[]") throws -> AppUpdateRelease {
    let raw = "{\"tag_name\":\"\(tag)\",\"html_url\":\"https://github.com/wm0104/RepoPocket/releases/tag/\(tag)\",\"draft\":\(draft),\"prerelease\":\(pre),\"assets\":\(assets)}"
    return try JSONDecoder().decode(AppUpdateRelease.self, from: Data(raw.utf8))
}
precondition(try AppUpdateRules.isNewer(release("v1.0.5.1"), local: "1.0.5", localBuild: "10"))
precondition(try !AppUpdateRules.isNewer(release("v1.0.5.1"), local: "1.0.5.1", localBuild: "11"))
precondition(try !AppUpdateRules.isNewer(release("v1.0.5"), local: "1.0.5.1", localBuild: "11"))
precondition(try AppUpdateRules.isNewer(release("v1.0.6"), local: "1.0.5.1", localBuild: "11"))
precondition(try AppUpdateRules.isNewer(release("v1.1.0"), local: "1.0.1", localBuild: "7"))
precondition(try AppUpdateRules.isNewer(release("v1.0.1+8"), local: "1.0.1", localBuild: "7"))
precondition(try !AppUpdateRules.isNewer(release("v1.0.1"), local: "1.0.1", localBuild: "7"))
// Legacy installs still interpret +1 as build1: document rather than conceal it.
precondition(try !AppUpdateRules.isNewer(release("v1.0.1+1"), local: "1.0.1", localBuild: "6"))
precondition(try !AppUpdateRules.isNewer(release("v1.0.1+1"), local: "1.0.1+1", localBuild: "7"))
precondition(try AppUpdateRules.isNewer(release("v1.0.1+2"), local: "1.0.1+1", localBuild: "7"))
precondition(try !AppUpdateRules.isNewer(release("v1.0.1"), local: "1.0.1+1", localBuild: "7"))
precondition(try AppUpdateRules.isNewer(release("v1.0.0+4"), local: "1.0.0", localBuild: "3"))
precondition(try !AppUpdateRules.isNewer(release("v1.0.0+4"), local: "1.0.0", localBuild: "4"))
precondition(try !AppUpdateRules.isNewer(release("v1.0.1+other"), local: "1.0.1+1", localBuild: "7"))
precondition(try AppUpdateRules.isNewer(release("v1.0.2"), local: "1.0.1+1", localBuild: "7"))
for bad in [try release("v1.1.0", true), try release("v1.1.0", false, true), try release("v1.1.0-rc.1")] {
    do { _ = try AppUpdateRules.isNewer(bad, local: "1.0.1", localBuild: "7"); fatalError("invalid release accepted") } catch {}
}
let asset = #"[{"name":"RepoPocket.ipa","browser_download_url":"https://github.com/wm0104/RepoPocket/releases/download/v1.1.0/RepoPocket.ipa"}]"#
precondition(try release("v1.1.0+42").displayVersion == "v1.1.0")
precondition(try release("v1.1.0", false, false, asset).ipaURL != nil)
precondition(try release("v1.1.0", false, false, asset.replacingOccurrences(of: "github.com", with: "evil.invalid")).ipaURL == nil)
precondition(AppUpdateRules.statusError(404).contains("尚无"))
func response(_ status: Int, _ headers: [String: String] = [:], _ message: String = "", _ auth: Bool = false) -> String {
    let bytes = try! JSONSerialization.data(withJSONObject: ["message": message])
    let http = HTTPURLResponse(url: URL(string: "https://api.github.com/repos/wm0104/RepoPocket/releases/latest")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    return AppUpdateRules.statusError(http.statusCode, headers: http.allHeaderFields, body: bytes, authenticated: auth)
}
let primary = response(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1791777600"], "API rate limit exceeded")
precondition(primary.contains("匿名出口 IP") && primary.contains("主速率") && primary.contains("预计"))
precondition(response(403, ["x-ratelimit-remaining": "0"], "", true).contains("当前账号主速率"))
precondition(response(403, [:], "API rate limit exceeded").contains("主速率"))
precondition(response(403, ["Retry-After": "120"], "You have exceeded a secondary rate limit").contains("120 秒"))
precondition(response(429, [:], "secondary rate limit").contains("次级"))
precondition(response(403, [:], "Resource not accessible by personal access token").contains("未确认是速率限制"))
precondition(response(429).contains("请求过于频繁"))
precondition(response(401).contains("凭据无效"))
precondition(response(404).contains("尚无"))
precondition(response(500).contains("HTTP 500"))
for status in [401, 403, 404, 429, 500] { precondition(response(status).contains("官方仓库下载页")) }
print("PASS mocked primary/secondary limits, reset/retry, generic403/401/404/429/500 and official download fallback")
precondition(AppUpdateRules.conciseCheckError(URLError(.notConnectedToInternet)).contains("网络未连接"))
precondition(AppUpdateRules.conciseCheckError(URLError(.timedOut)).contains("超时"))
precondition(AppUpdateRules.conciseCheckError(AppError(text: "发布版本格式无效或不是正式版本")).contains("版本号无法识别"))
print("PASS production SemVer/build, draft/prerelease, missing/equal/new versions, trusted IPA and public API errors")
'''
        # Throwing expressions cannot be evaluated in precondition's nonthrowing autoclosure.
        source = source.replace('precondition(try ', 'check(try ')
        source = 'func check(_ value: Bool) { precondition(value) }\n' + source
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder) / 'main.swift'; file.write_text(source)
            subprocess.run(['swiftc', str(file), '-o', folder + '/tests'], check=True)
            subprocess.run([folder + '/tests'], check=True)

if __name__ == '__main__': unittest.main()
