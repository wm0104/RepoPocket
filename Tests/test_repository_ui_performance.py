"""Compact summaries / targeted search and avatar regressions; no FPS claims."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import shutil
import subprocess
import tempfile
import unittest

ROOT = REPO_ROOT
UI = (ROOT/'RepoPocket/RepositoryUI.swift').read_text()
SEARCH = (ROOT/'RepoPocket/RepositorySearchView.swift').read_text()
APP = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()

class RepositoryUIPerformanceTests(unittest.TestCase):
    def test_summary_is_compact_and_shared(self):
        summary = UI[UI.index('struct RepositoryStatistics'):UI.index('struct LoadingRows')]
        for redundant in ('updated_at', '访问账号', 'repository.private', 'ISO8601DateFormatter'):
            self.assertNotIn(redundant, summary)
        self.assertIn('var descriptionLineLimit: Int? = 2', summary)
        self.assertIn('.lineLimit(descriptionLineLimit)', summary)
        self.assertIn('descriptionLineLimit: nil', APP)
        self.assertIn('.textSelection(.enabled).softGroupedRow', APP)
        self.assertIn('HStack(spacing: 12) { counts }', summary)
        self.assertNotIn('ViewThatFits', summary)
        self.assertNotIn('?? 0', summary)
        self.assertIn('GitHubAvatar(url: avatarURL, size: 24)', summary)
        self.assertIn('.accessibilityElement(children: .combine)', summary)

    def test_avatar_work_is_shared_bounded_and_off_main(self):
        for required in ('actor AvatarPipeline', 'pending: [URL: Task<UIImage?, Never>]',
                         'if let task = pending[url]', 'if active < 4', 'cache.countLimit = 192',
                         'Task.detached(priority: .utility)', 'CGImageSourceCreateThumbnailAtIndex',
                         'kCGImageSourceShouldCacheImmediately: true', '@StateObject private var loader',
                         'guard !Task.isCancelled, currentURL == url', 'completionHandler(nil)',
                         'configuration.urlCredentialStorage = nil'):
            self.assertIn(required, UI)
        self.assertNotIn('let decoded = UIImage(data: data)', UI)

    def test_search_does_not_refresh_home_or_animate_entire_list(self):
        self.assertNotIn('.animation(', SEARCH)
        self.assertIn('requestTask?.cancel()', SEARCH)
        self.assertIn('guard clean != submitted else { return }', SEARCH)
        self.assertIn('RepositorySearchRules.accepts', SEARCH)
        self.assertIn('Task.detached(priority: .utility)', SEARCH)
        self.assertIn('dismissSearch()', SEARCH)
        self.assertNotIn('onDismiss:', APP[APP.index('struct RepositoriesView'):APP.index('struct BrowserView')])
        self.assertIn('.sheet(isPresented: $showSearch)', APP)
        self.assertNotIn('await api.identify()', SEARCH)

    def test_parent_cache_and_collection_search(self):
        api = (ROOT/'RepoPocket/GitHub.swift').read_text()
        section = (ROOT/'RepoPocket/RepositorySections.swift').read_text()
        for value in ('let parent: RepositoryReference?', 'let fork: Bool?', 'repository.fork == true', 'parentActive < 3', 'parentTasks[key]', 'parentCache.count >= 512', 'Date().timeIntervalSince(cached.0) < 300', 'JSONDecoder().decode(Repository.self, from: bytes).parent'):
            self.assertIn(value, api)
        self.assertNotIn('.source', api)
        self.assertIn('Text("复刻自 " + parent.full_name)', UI)
        self.assertIn('guard !Task.isCancelled else { return }', UI)
        self.assertLess(UI.index('Text("复刻自'), UI.index('if let repository {', UI.index('Text("复刻自')))
        self.assertIn('frame(width: 44, height: 44)', section)
        self.assertNotIn('Color.clear.frame(height: 8)', section)
        self.assertIn('bottom: repository.id == repositories.last?.id', section)
        self.assertIn('bottom: !expanded', section)
        for field in ('name.localizedCaseInsensitiveContains', 'full_name.localizedCaseInsensitiveContains', 'description?.localizedCaseInsensitiveContains'):
            self.assertIn(field, section)
        self.assertIn('initialRepositories ?? api.cachedCollection(section)', section)
        self.assertIn('ForEach(filteredRepositories)', section)
        self.assertNotIn('api.searchRepositories', section)
        home = APP[APP.index('struct RepositoriesView'):APP.index('struct BrowserView')]
        self.assertIn('if !loaded && !CredentialStore.read().isEmpty', home)
        self.assertNotIn('.onAppear', home)
        self.assertNotIn('.id(showSearch)', home)

    @unittest.skipUnless(shutil.which('swiftc'), 'production Swift runs on macOS CI')
    def test_production_summary_rules(self):
        source = (ROOT/'RepoPocket/RepositoryPresentationRules.swift').read_text()+r'''
precondition(RepositoryPresentationRules.owner(login: nil, fullName: "alice/tool") == "alice")
precondition(RepositoryPresentationRules.owner(login: "bob", fullName: "alice/tool") == "bob")
precondition(RepositoryPresentationRules.name("", fullName: "alice/tool") == "tool")
precondition(RepositoryPresentationRules.name("name", fullName: "alice/tool") == "name")
precondition(RepositoryPresentationRules.language(nil) == nil)
precondition(RepositoryPresentationRules.language("  ") == nil)
precondition(RepositoryPresentationRules.language(" Swift ") == "Swift")
precondition(RepositoryPresentationRules.avatarURL("https://avatars.githubusercontent.com/u/1?v=4") != nil)
for bad in ["http://avatars.githubusercontent.com/u/1", "https://github.com/u/1", "https://avatars.githubusercontent.com.evil.test/u/1", "https://user:pass@avatars.githubusercontent.com/u/1", "https://avatars.githubusercontent.com:8443/u/1"] {
    precondition(RepositoryPresentationRules.avatarURL(bad) == nil)
}
print("PASS production compact summary and avatar URL rules")
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'main.swift'; path.write_text(source)
            subprocess.run(['swiftc', str(path), '-o', folder+'/tests'], check=True)
            subprocess.run([folder+'/tests'], check=True)

if __name__ == '__main__': unittest.main()
