"""Restored folder destination and native settings menu wiring contracts."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DownloadNavigationAppearanceTests(unittest.TestCase):
    def test_home_keeps_collections_without_download_management(self):
        source = (ROOT / 'RepoPocket/RepositorySections.swift').read_text(encoding='utf-8')
        home = source.split('struct RepositoryCollectionView:')[0]
        self.assertIn('SoftGroupRow("favorites")', home)
        self.assertNotIn('SoftGroupRow("downloads")', home)

    def test_settings_restore_native_menu_and_folder_sheet(self):
        source = (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text(encoding='utf-8')
        settings = source.split('struct SettingsView:', 1)[1]
        self.assertIn('NativeActionMenu(', settings)
        self.assertIn('.submenu("通用"', settings)
        self.assertIn('.submenu("主题"', settings)
        self.assertIn('selectedState: { appearance == mode }', settings)
        self.assertIn('downloads.choose()', settings)
        self.assertIn('DownloadFolderPresentation(downloads: downloads)', source)
        self.assertIn('downloads.picker', source)
        self.assertIn('downloads.selected(', source)
        self.assertIn('GitHubAvatar(', settings)
        self.assertIn('AppUpdateSection(', settings)
        self.assertNotIn('DisclosureGroup(isExpanded: $appearanceExpanded)', settings)

    def test_folder_authorization_is_persisted_not_an_internal_root(self):
        store = (ROOT / 'RepoPocket/DownloadStore.swift').read_text(encoding='utf-8')
        for token in ['RepoPocket.download.folder.v1', 'RepoPocket.download.label.v1',
                      'URL(resolvingBookmarkData:', 'startAccessingSecurityScopedResource()',
                      'stopAccessingSecurityScopedResource()', 'NSFileCoordinator()',
                      'WorkspaceImportRequest(kind: .folder)']:
            self.assertIn(token, store)
        self.assertNotIn('Library/Application Support/Downloads', store)


if __name__ == '__main__':
    unittest.main()
