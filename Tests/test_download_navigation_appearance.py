"""Navigation/appearance contracts; native interaction is covered by SettingsTests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DownloadNavigationAppearanceTests(unittest.TestCase):
    def test_home_downloads_follow_favorites(self):
        source = (ROOT / 'RepoPocket/RepositorySections.swift').read_text(encoding='utf-8')
        home = source.split('struct RepositoryCollectionView:')[0]
        self.assertLess(home.index('SoftGroupRow("favorites")'), home.index('SoftGroupRow("downloads")'))
        self.assertIn('DownloadCenterView(api: api)', home)

    def test_appearance_is_inline_and_preserves_profile_and_updates(self):
        source = (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text(encoding='utf-8')
        settings = source.split('struct SettingsView:')[1]
        self.assertIn('@State private var appearanceExpanded = false', settings)
        self.assertIn('DisclosureGroup(isExpanded: $appearanceExpanded)', settings)
        self.assertIn('Text("外观")', settings)
        self.assertIn('appearance = mode', settings)
        self.assertIn('.isSelected', settings)
        self.assertIn('GitHubAvatar(', settings)
        self.assertIn('AppUpdateSection(', settings)
        self.assertNotIn('NativeMenuItem.submenu("通用"', settings)
        self.assertNotIn('选择文件夹', settings)
        self.assertNotIn('$downloads.picker', source)


if __name__ == '__main__':
    unittest.main()
