"""Navigation contracts for the directory-freeze fix.

Two real-device failures shaped this:

1. freeze — iOS 16 eagerly instantiates a
   `NavigationLink { BrowserView(...) }` destination. BrowserView embeds the
   same link for every subdirectory, so the type graph recursed up front and
   blocked the main thread (repositories with directories froze; a flat
   repository browsed fine). Crash evidence: watchdog process-exit with the main
   thread burning ~47s of user CPU inside dyld shared cache (system SwiftUI).

2. dead click — routing every row through value-driven
   `navigationDestination(for:)`, or wrapping file rows in a lazy container,
   left rows unresponsive because a BrowserView is reached from several entry
   NavigationStacks.

The fix isolates ONLY the recursive directory destination behind
DirectoryBrowserDestination (a lazy closure) while file rows keep the plain
closure form that always opens.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'RepoPocket' / 'RepoPocketApp.swift').read_text()
DEST = (ROOT / 'RepoPocket' / 'DirectoryBrowserDestination.swift')


class DirectoryNavigationTests(unittest.TestCase):
    def browser(self):
        return APP.split('struct BrowserView:', 1)[1].split('struct FileView:', 1)[0]

    def test_directory_rows_use_lazy_destination(self):
        browser = self.browser()
        self.assertIn('NavigationLink { DirectoryBrowserDestination(api: api, repo: repo, path: e.path, branch: activeBranch) }', browser)
        # The eager recursive form must not come back.
        self.assertNotIn('NavigationLink { BrowserView(api: api, repo: repo, path: e.path', browser)

    def test_file_rows_keep_plain_closure(self):
        browser = self.browser()
        self.assertIn('NavigationLink { FileView(api: api, repo: repo, entry: e, branch: activeBranch, canWrite: canWrite) }', browser)
        self.assertNotIn('NavigationLink { LazyView { FileView', browser)
        self.assertNotIn('NavigationLink(value:', browser)

    def test_history_keeps_plain_closure(self):
        browser = self.browser()
        self.assertIn('NavigationLink("提交历史") { HistoryView(api: api, repo: repo, branch: activeBranch) }', browser)

    def test_destination_file_defers_construction(self):
        self.assertTrue(DEST.exists())
        text = DEST.read_text()
        self.assertIn('struct DirectoryBrowserDestination: View', text)
        self.assertIn('private let build: () -> AnyView', text)
        self.assertIn('BrowserView(api: api, repo: repo, path: path, branch: branch)', text)
        self.assertIn('var body: AnyView { build() }', text)

    def test_no_stale_routing_helpers(self):
        self.assertFalse((ROOT / 'RepoPocket' / 'LazyView.swift').exists())
        self.assertFalse((ROOT / 'RepoPocket' / 'BrowserRoute.swift').exists())

    def test_browser_load_resets_repository_info_once(self):
        browser = self.browser()
        load = browser[browser.index('private func load() async'):]
        load = load[:load.index('private func deleteRemote')]
        self.assertEqual(load.count('repositoryInfo = nil'), 1)


if __name__ == '__main__':
    unittest.main()
