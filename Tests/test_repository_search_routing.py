from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]

class SearchRoutingTests(unittest.TestCase):
    def test_search_submission_and_owner_destination(self):
        ui = (ROOT/'RepoPocket/RepositorySearchView.swift').read_text()
        self.assertIn('RepositorySearchRouting.repository(clean)', ui)
        self.assertIn('.onSubmit(of: .search) { begin(kind) }', ui)
        self.assertIn('Picker("搜索类型"', ui)
        self.assertIn('directRepository = target', ui)
        app = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
        self.assertIn('openOwner: { showingRepositoryOwner = true }', app)
        self.assertIn('UserRepositoriesView(api: api, user:', app)
        self.assertIn('repositoryInfo.owner?.login', app)
        cards = (ROOT/'RepoPocket/RepositoryUI.swift').read_text()
        self.assertIn('openOwner ?? { showOwnerProfile = true }', cards)
        self.assertIn('UserRepositoriesView(api: api, user: ownerProfile)', cards)
        issues = (ROOT/'RepoPocket/CollaborationViews.swift').read_text()
        self.assertIn('CommunityAuthorLink(api: api, user: item.user, opensInSheet: true)', issues)
        self.assertIn('issue-list-author-', issues)
        social = (ROOT/'RepoPocket/RepositorySocial.swift').read_text()
        self.assertIn('CommunityAuthorLink(api: api, user: forkUser(fork), opensInSheet: true)', social)

    @unittest.skipUnless(shutil.which('swiftc'), 'Native Swift runs on macOS')
    def test_production_route_validation(self):
        source = '\n'.join((ROOT/'RepoPocket'/n).read_text() for n in ['RepositoryInput.swift','RepositorySearchRouting.swift'])
        source += r'''
precondition(RepositorySearchRouting.repository(" https://github.com/Jond-ie/triggr-beta ") == "Jond-ie/triggr-beta")
precondition(RepositorySearchRouting.repository("github.com/opa334/Dopamine.git/") == "opa334/Dopamine")
precondition(RepositorySearchRouting.repository("opa334/Dopamine") == "opa334/Dopamine")
for bad in ["opa334", "Dopamine language:Swift", "https://evil.example/opa334/Dopamine", "https://github.com.evil/opa334/Dopamine", "https://user@github.com/opa334/Dopamine", "https://github.com/opa334/Dopamine/tree/main", "https://github.com/opa334/Dopamine?token=secret"] {
 precondition(RepositorySearchRouting.repository(bad) == nil)
}
precondition(RepositorySearchRouting.isLink("https://github.com/opa334/Dopamine/tree/main"))
precondition(!RepositorySearchRouting.isLink("opa334"))
print("PASS production direct repository routing and strict URL boundaries")
'''
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'main.swift'; path.write_text(source)
            subprocess.run(['swiftc',str(path),'-o',folder+'/test'],check=True)
            subprocess.run([folder+'/test'],check=True)

if __name__ == '__main__': unittest.main()
