"""Production TrollStore URL encoding and update eligibility, without launching apps."""
import pathlib, shutil, subprocess, tempfile, unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class TrollStoreUpdateTests(unittest.TestCase):
    def test_ui_bridge_and_fallback(self):
        bridge = (ROOT / 'RepoPocket/TrollStoreInstaller.swift').read_text()
        ui = (ROOT / 'RepoPocket/UpdateFeature.swift').read_text()
        project = (ROOT / 'project.yml').read_text()
        self.assertIn('LSApplicationQueriesSchemes:', project)
        self.assertIn('- apple-magnifier', project)
        for token in ['@MainActor', 'canOpenURL(url)', 'UIApplication.shared.open(url', 'completion(opened)']:
            self.assertIn(token, bridge)
        self.assertNotIn('completionHandler: nil', bridge)
        for token in ['Button("TrollStore 更新安装")', 'TrollStoreInstallRules.installURL(for: ipa)',
                      'Button("下载更新")', 'Button("分享 IPA 安装")', 'URL Scheme',
                      '不经过 RepoPocket 的本地 SHA256 校验', '可能打开放大器',
                      'confirmTrollStore = true', 'session == AccountStore.generation',
                      'checker.release?.ipaURL == ipa', '无法打开链接安装']:
            self.assertIn(token, ui)
        self.assertNotIn('.badge(updateChecker.hasUpdate', (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text())
        self.assertNotIn('Circle().fill(Color.red)', ui)
        self.assertNotIn('hasInstallMarker', bridge + ui)

    def test_production_url_encoding_and_rc_offer(self):
        if not shutil.which('swiftc'):
            self.skipTest('swiftc unavailable; production executable runs in macOS CI')
        harness = r'''
import Foundation
struct AppError: Error { let text: String }
func expect(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
let links = [
    "https://github.com/wm0104/RepoPocket/releases/download/v1.0.3/RepoPocket-1.0.3.ipa",
    "https://github.com/wm0104/RepoPocket/releases/download/v1.0.3+2/RepoPocket.ipa?download=1&name=a+b%20c",
    "https://github.com/wm0104/RepoPocket/releases/download/v1.0.3/RepoPocket-1.0.3.ipa?value=%26%23%25"
]
for link in links {
    let source = URL(string: link)!
    let target = TrollStoreInstallRules.installURL(for: source)!
    let components = URLComponents(url: target, resolvingAgainstBaseURL: false)!
    expect(components.scheme == "apple-magnifier" && components.host == "install", "wrong command")
    expect(components.queryItems?.count == 1, "nested query leaked")
    expect(components.queryItems?.first?.name == "url", "wrong query key")
    expect(components.queryItems?.first?.value == source.absoluteString, "nested URL changed")
    expect(target.absoluteString.contains("url=https%3A%2F%2F"), "URL not encoded")
    expect(!target.absoluteString.contains("&"), "unencoded delimiter")
}
for bad in [
    "http://github.com/wm0104/RepoPocket/releases/download/v1.0.3/RepoPocket.ipa",
    "https://evil.example/wm0104/RepoPocket/releases/download/v1.0.3/RepoPocket.ipa",
    "https://github.com.evil.example/wm0104/RepoPocket/releases/download/v1.0.3/RepoPocket.ipa",
    "https://github.com/wm0104/Other/releases/download/v1.0.3/RepoPocket.ipa",
    "https://github.com/other/RepoPocket/releases/download/v1.0.3/RepoPocket.ipa",
    "https://github.com/wm0104/RepoPocket/releases/latest/download/RepoPocket.ipa",
    "https://user:password@github.com/wm0104/RepoPocket/releases/download/v1.0.3/RepoPocket.ipa",
    "https://github.com:443/wm0104/RepoPocket/releases/download/v1.0.3/RepoPocket.ipa",
    "https://github.com/wm0104/RepoPocket/releases/download/v1.0.3/RepoPocket.ipa#fragment",
    "https://github.com/wm0104/RepoPocket/releases/download/v1.0.3/Other.ipa",
    "https://github.com/wm0104/RepoPocket/releases/download/v1.0.3/RepoPocket.zip",
    "https://github.com/wm0104/RepoPocket/releases/download/v1.0.3/nested/RepoPocket.ipa"
] { expect(TrollStoreInstallRules.installURL(for: URL(string: bad)!) == nil, "accepted unsafe URL: " + bad) }
let release = AppUpdateRelease(tag_name: "v1.0.3", html_url: URL(string: "https://github.com/wm0104/RepoPocket/releases/tag/v1.0.3")!, draft: false, prerelease: false, assets: [.init(name: "RepoPocket-1.0.3.ipa", browser_download_url: URL(string: links[0])!)], body: "修复已知问题")
expect(release.ipaURL != nil, "official package not matched")
expect(try AppUpdateRules.isNewer(release, local: "1.0.3-rc.1", localBuild: "2"), "RC cannot detect final")
expect(try AppUpdateRules.isNewer(release, local: "1.0.2", localBuild: "10"), "old build cannot detect final")
expect(try !AppUpdateRules.isNewer(release, local: "1.0.3", localBuild: "2"), "final offers itself")
print("TrollStore URL encoding, rejection and RC update eligibility passed")
'''
        with tempfile.TemporaryDirectory() as temp:
            main = pathlib.Path(temp) / 'main.swift'
            binary = pathlib.Path(temp) / 'test'
            main.write_text(harness)
            sources = [ROOT / 'RepoPocket' / name for name in ['TrollStoreInstallRules.swift', 'ChinaDate.swift', 'AppUpdateRules.swift', 'AppUpdateSessionRules.swift']]
            subprocess.run(['swiftc', *map(str, sources), str(main), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

if __name__ == '__main__':
    unittest.main()
