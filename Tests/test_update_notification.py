"""Update notification: app-entry checks, 15-minute window, tab dot and settings row (macOS Swift)."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import shutil
import subprocess
import tempfile
import unittest

app = (REPO_ROOT / 'RepoPocket/RepoPocketApp.swift').read_text()
feature = (REPO_ROOT / 'RepoPocket/UpdateFeature.swift').read_text()
rules = (REPO_ROOT / 'RepoPocket/AppUpdateRules.swift').read_text()
session = (REPO_ROOT / 'RepoPocket/AppUpdateSessionRules.swift').read_text()
badge = (REPO_ROOT / 'RepoPocket/UpdateTabBadge.swift').read_text()


class UpdateNotificationTests(unittest.TestCase):
    def test_cooldown_is_fifteen_minutes(self):
        self.assertIn('static let cooldown: TimeInterval = 15 * 60', session)
        self.assertNotIn('6 * 60 * 60', session)

    def test_app_entry_checks_on_launch_and_foreground(self):
        self.assertIn('.task { await updateChecker.appEntryCheck(api: api) }', app)
        self.assertIn('.onChange(of: scenePhase) { phase in', app)
        self.assertIn('guard phase == .active else { return }', app)
        self.assertEqual(app.count('appEntryCheck(api: api)'), 2)
        # One attempt per entry, still keyed by account and gated by the stored timestamp.
        self.assertIn('mutating func beginEntry() { attempted = false }', session)
        self.assertIn('guard !attempted else { return false }', session)
        self.assertIn('"RepoPocket.update.lastCheck." + api.accountID', feature)

    def test_automatic_checks_no_longer_present_a_startup_card(self):
        self.assertFalse((REPO_ROOT / 'RepoPocket/StartupUpdateCard.swift').exists())
        for source in (app, feature, rules, session, (REPO_ROOT / 'project.yml').read_text()):
            for gone in ('startupRelease', 'StartupUpdateCard', 'startupSheetVisible',
                         'startupSheetQueued', 'skipAndDismissStartupRelease',
                         'dismissStartupUpdate', 'startupPromptOffered', 'skippedKey'):
                self.assertNotIn(gone, source)
        self.assertNotIn('.sheet(isPresented: $startupSheetVisible', app)
        # Manual checks keep their feedback, automatic ones stay silent.
        self.assertIn('!automatic { showTransient(AppUpdateRules.conciseCheckError(error)) }', feature)

    def test_tab_dot_is_driven_by_has_update(self):
        self.assertIn('UpdateTabBadge(tabIndex: 3, isVisible: updateChecker.hasUpdate)', app)
        self.assertIn('var hasUpdate: Bool { release != nil }', feature)
        self.assertIn('width: 10, height: 10', badge)
        self.assertIn('backgroundColor = .systemBackground', badge)
        self.assertIn('backgroundColor = .systemRed', badge)
        self.assertNotIn('.badge(', app)
        # The dot is only removed when no update is available, never on settings entry.
        self.assertNotIn('hasUpdate = false', feature)

    def test_settings_row_shows_available_version(self):
        self.assertIn('Text(release.availableVersionText)', feature)
        self.assertIn('return version + " 可更新"', rules)
        row = feature.split('Text("应用更新")', 1)[1].split('Menu {', 1)[0]
        self.assertIn('Text(release.availableVersionText)', row)
        self.assertIn('Menu {', feature.split('Text("应用更新")', 1)[1])
        self.assertIn('Button(checker.checking ? "检查中…" : "检查更新")', feature)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler is available in macOS Actions')
    def test_production_rules(self):
        api = (REPO_ROOT / 'RepoPocket/GitHub.swift').read_text()
        source = 'import Foundation\n' + api[api.index('struct AppError:'):api.index('struct GitHubAPIError:')] \
            + session + rules + (REPO_ROOT / 'RepoPocket/ChinaDate.swift').read_text().replace('import Foundation', '') + r'''
@main struct NotificationTests {
static func main() throws {
// (a) A 15-minute minimum interval between automatic checks.
precondition(AppUpdateSessionRules.cooldown == 15 * 60)
var window = AppUpdateSessionRules()
let start = Date()
precondition(window.claim(now: start, last: nil))
precondition(!window.claim(now: start, last: nil)) // One attempt per app entry.
window.beginEntry()
precondition(!window.claim(now: start.addingTimeInterval(14 * 60), last: start))
window.beginEntry()
precondition(window.claim(now: start.addingTimeInterval(15 * 60), last: start))
func release(_ tag: String) throws -> AppUpdateRelease {
    let raw = "{\"tag_name\":\"\(tag)\",\"html_url\":\"https://github.com/wm0104/RepoPocket/releases/tag/\(tag)\",\"draft\":false,\"prerelease\":false,\"assets\":[]}"
    return try JSONDecoder().decode(AppUpdateRelease.self, from: Data(raw.utf8))
}
// (d) Settings row value: release tag without the leading v plus 可更新.
for tag in ["v1.1.7", "v1.1.7+4", "1.1.7"] {
    let value = try release(tag)
    precondition(value.availableVersionText == "1.1.7 可更新")
}
// (c) hasUpdate is release != nil, and this release is the one a 1.1.6 install would show.
let newer = try AppUpdateRules.isNewer(release("v1.1.7"), local: "1.1.6", localBuild: "1.1.6")
let same = try AppUpdateRules.isNewer(release("v1.1.6"), local: "1.1.6", localBuild: "1.1.6")
precondition(newer && !same)
print("PASS cooldown 15 minutes, single attempt per entry, settings version text, newer-version gate")
}
}
'''
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'notification.swift'
            path.write_text(source)
            subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', d + '/test'], check=True)
            subprocess.run([d + '/test'], check=True)


if __name__ == '__main__':
    unittest.main()
