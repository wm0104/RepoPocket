"""Account-local favorites and the official Star-list client; no live mutations."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RepositoryCollectionsTests(unittest.TestCase):
    def test_favorites_are_separate_from_star_mutations_and_account_scoped(self):
        source = (ROOT/'RepoPocket/RepositoryFavorites.swift').read_text(encoding='utf-8')
        for marker in ['accountID', 'maximumBytes', 'maximumCount', 'JSONEncoder', 'JSONDecoder', 'Set(', 'removeAccount']:
            self.assertIn(marker, source)
        self.assertNotIn('starRequest', source)
        self.assertNotIn('URLSession', source)

    def test_star_lists_use_official_variables_and_complete_membership(self):
        source = (ROOT/'RepoPocket/GitHubStarLists.swift').read_text(encoding='utf-8')
        for marker in ['createUserList', 'updateUserList', 'deleteUserList', 'updateUserListsForItem',
                       'viewerHasStarred', 'databaseId', 'hasNextPage', 'seenCursors', 'memberIDs',
                       'Task.checkCancellation()', 'isPrivate', 'errors']:
            self.assertIn(marker, source)
        self.assertNotIn('viewerLists', source)
        self.assertNotIn('addStar(', source)
        self.assertNotIn('removeStar(', source)

    def test_shipping_entry_points_account_cleanup_and_ui_regressions_are_connected(self):
        sections = (ROOT/'RepoPocket/RepositorySections.swift').read_text(encoding='utf-8')
        self.assertIn('StarListsView(api: api', sections)
        self.assertIn('RepositoryFavoritesHomeLink(api: api, favorites: api.favorites)', sections)
        self.assertIn('RepositoryFavorites.removeAccount(id)', (ROOT/'RepoPocket/GitHubAccounts.swift').read_text(encoding='utf-8'))
        search = (ROOT/'RepoPocket/RepositorySearchView.swift').read_text(encoding='utf-8')
        self.assertIn('var selectRepository: ((Repository) throws -> Void)? = nil', search)
        self.assertIn('try selectRepository(repository)', search)
        self.assertIn('let repository = try await api.repository(name)', search)
        picker = search.split('if selectRepository != nil {\n                                Button', 1)[1].split('} else {', 1)[0]
        self.assertIn('CompactRepositorySummary(', picker)
        self.assertNotIn('RepositoryCard(', picker)
        views = (ROOT/'RepoPocket/RepositoryCollectionViews.swift').read_text(encoding='utf-8')
        for token in ['SoftGroupRows(spacingBefore: 10)', '.onMove', 'favorites.reorder(order)',
                      'NativeActionMenu', 'confirmationDialog', 'attempted = true',
                      'enabled: editMode.isEditing || (query.isEmpty && !favorites.repositories.isEmpty)',
                      '不会取消仓库的Star', 'initialRepositories: initialRepositories']:
            self.assertIn(token, views)
        github = (ROOT/'RepoPocket/GitHub.swift').read_text(encoding='utf-8')
        transport = github.split('func starListGraphQL(', 1)[1].split('func starRequest', 1)[0]
        for token in ['requireStarSession()', 'OfficialUpdateRedirectPolicy()', 'Task.checkCancellation()']:
            self.assertIn(token, transport)
        self.assertNotIn('requireWriteAccess', transport)
        menu = (ROOT/'RepoPocket/NativeActionMenu.swift').read_text(encoding='utf-8').split('struct RepositoryBrowserActionMenu:', 1)[1]
        self.assertEqual(menu.count('RepositoryFavoriteActionHost'), 2, 'Repository-home and code menus must both offer favorites')
        self.assertIn('if busy && repositories.isEmpty', views)
        member_picker = views.split('private struct StarListRepositoryPicker:', 1)[1]
        self.assertIn('CompactRepositorySummary(', member_picker)
        self.assertNotIn('RepositoryCard(', member_picker)
        self.assertIn('python3 Tests/test_repository_collections.py', (ROOT/'.github/workflows/build.yml').read_text(encoding='utf-8'))
        self.assertTrue((ROOT/'Tests/Fixtures/RepositoryCollectionsHarness.swift').is_file())

    @unittest.skipUnless(shutil.which('swiftc'), 'Production Swift fixtures execute on macOS')
    def test_production_storage_and_official_client(self):
        github = (ROOT/'RepoPocket/GitHub.swift').read_text(encoding='utf-8')
        models = github.split('struct User: Codable {', 1)[1].split('struct Release:', 1)[0]
        fixture = (ROOT/'Tests/Fixtures/RepositoryCollectionsHarness.swift').read_text(encoding='utf-8')
        preamble = github.split('enum CredentialStore {', 1)[0].replace('import Security\n', '')
        def method(signature):
            return signature + github.split(signature, 1)[1].split('\n    }\n', 1)[0] + '\n    }\n'
        transport = '\n'.join(method(signature) for signature in [
            '    private func url(', '    private func request(', '    private func ensureActiveAccount()',
            '    private func check(', '    func requireStarSession()', '    func starListGraphQL(',
        ])
        fixture = preamble + '\nstruct User: Codable {' + models + fixture.replace('// PRODUCTION_TRANSPORT', transport)
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder)/'Harness.swift'; main.write_text(fixture, encoding='utf-8')
            binary = str(Path(folder)/'test')
            subprocess.run(['swiftc', '-parse-as-library', str(ROOT/'RepoPocket/RepositoryInput.swift'),
                            str(ROOT/'RepoPocket/RepositoryFavorites.swift'), str(ROOT/'RepoPocket/GitHubStarLists.swift'),
                            str(ROOT/'RepoPocket/OfficialUpdateRedirectPolicy.swift'),
                            str(main), '-module-cache-path', str(Path(folder)/'ModuleCache'), '-o', binary], check=True, timeout=120)
            subprocess.run([binary], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
