from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PathCommitMetadataTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Production path query and async state require native Swift')
    def test_production_query_batches_account_and_branch_changes(self):
        core = (ROOT / 'RepoPocket/PathCommitMetadata.swift').read_text(encoding='utf-8').split('struct PathCommitMetadataLink:', 1)[0]
        core = core.replace('import SwiftUI', 'import Foundation\nimport Combine')
        github = (ROOT / 'RepoPocket/GitHub.swift').read_text(encoding='utf-8')
        helpers = github.split('    static func component(', 1)[1].split('    private func url(', 1)[0]
        fixture = (ROOT / 'Tests/Fixtures/PathCommitMetadataHarness.swift').read_text(encoding='utf-8')
        fixture = fixture.replace('// PRODUCTION_PATH_HELPERS', '    static func component(' + helpers)
        with tempfile.TemporaryDirectory(prefix='repopocket-path-metadata-') as directory:
            folder = Path(directory); swift = folder / 'Fixture.swift'; binary = folder / 'fixture'
            swift.write_text(core + (ROOT / 'RepoPocket/RepositoryInput.swift').read_text(encoding='utf-8') + fixture, encoding='utf-8')
            subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=30)
    def test_queries_are_batched_and_bound_to_a_commit_not_a_moving_branch(self):
        path = ROOT / 'RepoPocket/PathCommitMetadata.swift'
        text = path.read_text(encoding='utf-8') if path.exists() else ''
        for token in ['batchSize = 20', 'history(first: 1, path:', 'object(expression: $head)',
                      'workspaceHead', 'AccountStore.generation', 'requestID == token', 'ContentSnapshotCache']:
            self.assertTrue(token in text, token)

    def test_metadata_is_a_sibling_of_file_navigation_on_the_same_row(self):
        text = (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text(encoding='utf-8')
        for token in ['PathCommitMetadataLink(', 'metadata.commits[e.path]', 'metadata.cancel()',
                      'metadata.load(api: api, repo: repo, branch: resolved, entries: result)']:
            self.assertTrue(token in text, token)

    def test_cached_metadata_restores_before_directory_network_request(self):
        text = (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text(encoding='utf-8')
        load = text.split('    private func load() async {', 1)[1].split('    private func deleteRemote(', 1)[0]
        seed = 'self.metadata.load(api: api, repo: repo, branch: requestedBranch, entries: entries)'
        self.assertIn(seed, load)
        self.assertLess(load.index(seed), load.index('try await api.contents('))

    def test_star_time_does_not_change_the_original_sort(self):
        text = (ROOT / 'RepoPocket/RepositorySections.swift').read_text(encoding='utf-8')
        self.assertIn('section == .starred, let date = ChinaDate.parse(repository.updated_at)', text)
        api = (ROOT / 'RepoPocket/GitHub.swift').read_text(encoding='utf-8').split('func starredRepositories()', 1)[1].split('func searchRepositories', 1)[0]
        self.assertIn('value: "created"', api)
        self.assertIn('value: "desc"', api)


if __name__ == '__main__':
    unittest.main()
