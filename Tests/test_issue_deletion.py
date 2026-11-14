"""Issue deletion uses production models and isolated transport, never live writes."""
from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]

class IssueDeletionTests(unittest.TestCase):
    def test_both_entry_points_and_server_permission_gate(self):
        personal = (ROOT/'RepoPocket/PersonalIssuesView.swift').read_text()
        repository = (ROOT/'RepoPocket/CollaborationViews.swift').read_text().split('struct CollaborationDetailView:',1)[0]
        for source in [personal, repository]:
            self.assertIn('issueDeletionMenu(', source)
            self.assertIn('issueDeletionPresenter(', source)
            self.assertIn('deletions.visible(', source)
        ui = (ROOT/'RepoPocket/IssueDeletionUI.swift').read_text()
        self.assertIn('role: .destructive', ui)
        self.assertIn('永久删除', ui)
        self.assertNotIn('.task', ui, 'No permission requests from row appearance/scrolling')
        api = (ROOT/'RepoPocket/IssueDeletion.swift').read_text()
        self.assertIn('viewerCanDelete', api)
        self.assertIn('clientMutationId', api)
        self.assertNotIn('permissions?.push', api)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift production regression runs on macOS')
    def test_production_permission_identity_and_mutation_acknowledgement(self):
        # Harness added with the production API so the whole mutation path is exercised.
        harness = ROOT/'Tests/Fixtures/IssueDeletionHarness.swift'
        self.assertTrue(harness.exists())
        github = (ROOT/'RepoPocket/GitHub.swift').read_text()
        models = github[github.index('struct User: Decodable'):github.index('struct Release: Decodable')]
        source = harness.read_text().replace('// PRODUCTION_MODELS', models)
        transport = github.split('    func issueDeletionGraphQL(',1)[1].split('    @Published private(set) var starRevision',1)[0]
        source = source.replace('// PRODUCTION_TRANSPORT', 'func issueDeletionGraphQL(' + transport)
        source += '\n' + (ROOT/'RepoPocket/OfficialUpdateRedirectPolicy.swift').read_text()
        source = source.replace('// PRODUCTION_CODE', '\n'.join((ROOT/'RepoPocket'/name).read_text() for name in [
            'RepositoryInput.swift','CommunityModels.swift','HomeCommunityModels.swift','IssueDeletion.swift']))
        with tempfile.TemporaryDirectory() as folder:
            file=Path(folder)/'main.swift'; file.write_text(source)
            exe=str(Path(folder)/'test')
            subprocess.run(['swiftc','-parse-as-library',str(file),'-o',exe],check=True)
            subprocess.run([exe],check=True,timeout=30)

if __name__ == '__main__': unittest.main()
