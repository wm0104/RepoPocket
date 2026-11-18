"""Settings stays compact without removing account/update lifecycles."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class SettingsLayoutTests(unittest.TestCase):
    def source(self, name):
        return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')

    def test_default_page_keeps_profile_social_and_about_in_one_group(self):
        page = self.source('RepoPocketApp.swift').split('struct SettingsView:', 1)[1].split('\nstruct ', 1)[0]
        self.assertEqual(page.count('QuotaScrollStack {'), 1)
        self.assertIn('QuotaCard(accessibilityID: "settings-profile-card")', page)
        self.assertIn('QuotaCard(accessibilityID: "settings-about-card")', page)
        self.assertNotIn('Form {', page)
        for value in ['GitHubAvatar(', 'savedAccount?.login', 'settings-social-accounts', 'Text("关于")',
                      'AppUpdateSection(api: api, checker: updateChecker, connected: true)', '.navigationBarTitleDisplayMode(.inline)']:
            self.assertIn(value, page)
        self.assertNotIn('Section("账号与安全")', page)
        self.assertNotIn('Token 仅保存在本机钥匙串', page)
        self.assertNotIn('DownloadLocationSection()', page)
        self.assertNotIn('Picker("主题"', page)

    def test_native_options_restore_reference_menu_without_an_inline_appearance_card(self):
        page = self.source('RepoPocketApp.swift').split('struct SettingsView:', 1)[1]
        for value in ['.toolbar { SettingsOptionsMenu() }', 'struct SettingsOptionsMenu: View',
                      '@AppStorage("appearance.mode")', 'selectedState: { appearance == mode }',
                      'NativeMenuItem.submenu("通用"', 'NativeMenuItem.submenu("主题"',
                      'title: "选择文件夹"', 'downloads.choose()']:
            self.assertIn(value, page)
        self.assertNotIn('SettingsAppearanceRow', page)
        self.assertNotIn('settings-appearance-card', page)
        self.assertNotIn('DisclosureGroup(', page)

    def test_account_and_update_lifecycles_remain_unchanged(self):
        page = self.source('RepoPocketApp.swift').split('struct SettingsView:', 1)[1].split('\nstruct ', 1)[0]
        for value in ['accountPresentation.showing = true', 'await refreshProfile()', 'updateChecker.enterPage()',
                      'if !updateChecker.sharing { updateChecker.leavePage() }', 'api.isCurrentSession']:
            self.assertIn(value, page)
        update = self.source('UpdateFeature.swift')
        self.assertIn('softGroupedRow(top: !connected, cardVerticalPadding: 0)', update)
        self.assertIn('downloadCompletionNotice', update)
        self.assertIn('confirmTrollStore', update)

if __name__ == '__main__':
    unittest.main()
