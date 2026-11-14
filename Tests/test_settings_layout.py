"""Settings stays compact without removing account/update lifecycles."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class SettingsLayoutTests(unittest.TestCase):
    def source(self, name):
        return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')

    def test_default_page_keeps_profile_social_and_about_in_one_group(self):
        page = self.source('RepoPocketApp.swift').split('struct SettingsView:', 1)[1].split('\nstruct ', 1)[0]
        self.assertEqual(page.count('Section {'), 1)
        for value in ['GitHubAvatar(', 'savedAccount?.login', 'settings-social-accounts', 'Text("关于")',
                      'AppUpdateSection(api: api, checker: updateChecker, connected: true)', '.navigationBarTitleDisplayMode(.inline)']:
            self.assertIn(value, page)
        self.assertNotIn('Section("账号与安全")', page)
        self.assertNotIn('Token 仅保存在本机钥匙串', page)
        self.assertNotIn('DownloadLocationSection()', page)
        self.assertNotIn('Picker("主题"', page)

    def test_native_menu_reuses_theme_and_existing_folder_authorization(self):
        page = self.source('RepoPocketApp.swift').split('struct SettingsView:', 1)[1].split('\nstruct ', 1)[0]
        for value in ['NativeActionMenu(title: "设置选项"', 'accessibilityIdentifier: "settings-options"',
                      'NativeMenuItem.submenu("通用"', 'NativeMenuItem.submenu("主题"',
                      'selected: appearance == mode', 'appearance = mode', 'downloads.operations == 0', 'downloads.choose()']:
            self.assertIn(value, page)
        menu = self.source('NativeActionMenu.swift')
        self.assertIn('state: item.selected ? .on : .off', menu)
        self.assertIn('DispatchQueue.main.async', menu)
        self.assertIn('current.enabled', menu)

    def test_account_and_update_lifecycles_remain_unchanged(self):
        page = self.source('RepoPocketApp.swift').split('struct SettingsView:', 1)[1].split('\nstruct ', 1)[0]
        for value in ['accountPresentation.showing = true', 'await refreshProfile()', 'updateChecker.enterPage()',
                      'if !updateChecker.sharing { updateChecker.leavePage() }', 'api.isCurrentSession']:
            self.assertIn(value, page)
        update = self.source('UpdateFeature.swift')
        self.assertIn('softGroupedRow(top: !connected)', update)
        self.assertIn('downloadCompletionNotice', update)
        self.assertIn('confirmTrollStore', update)

if __name__ == '__main__':
    unittest.main()
