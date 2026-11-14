"""Related search and import rows must not become detached/empty cards."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1] / 'RepoPocket'
def page(filename, name):
    return (ROOT / filename).read_text(encoding='utf-8').split('struct ' + name, 1)[1].split('\nstruct ', 1)[0]

class CompactSearchInboxTests(unittest.TestCase):
    def test_repository_search_filters_history_results_and_errors_are_connected(self):
        text = page('RepositorySearchView.swift', 'RepositorySearchView:')
        body = text.split('var body: some View', 1)[1].split('// Do not animate structural', 1)[0]
        self.assertEqual(body.count('Section {'), 1)
        self.assertEqual(body.count('SoftGroupRows {'), 1)
        self.assertNotIn('Section(', body)
        for value in ['SoftGroupRow("kind")', 'SoftGroupRow("history-heading")', 'SoftGroupRow("results-heading")',
                      'SoftGroupRow("busy")', 'SoftGroupRow("error")', 'store.remove(item)',
                      'begin(.repositories)', 'begin(.users)', '.disabled(busy)']:
            self.assertIn(value, body)

    def test_repository_collection_search_and_results_share_boundaries(self):
        text = page('RepositorySections.swift', 'RepositoryCollectionView:')
        body = text.split('var body: some View', 1)[1].split('.listStyle', 1)[0]
        self.assertEqual(body.count('Section {'), 1)
        self.assertEqual(body.count('SoftGroupRows {'), 1)
        self.assertIn('SoftGroupRow("search")', body)
        self.assertIn('SoftGroupRow("repository-\\(repository.id)")', body)
        self.assertIn('.swipeActions(edge: .trailing, allowsFullSwipe: false)', body)
        self.assertIn('RepositoryGroupRules.isOwned', body)

    def test_file_search_scope_status_and_results_are_one_group(self):
        text = page('RepositoryFileSearch.swift', 'RepositoryFileSearchView')
        body = text.split('var body: some View', 1)[1].split('private func label', 1)[0]
        self.assertEqual(body.count('Section {'), 1)
        self.assertEqual(body.count('SoftGroupRows {'), 1)
        for value in ['SoftGroupRow("scope")', 'SoftGroupRow("entry-" + entry.id)', 'results.prefix(200)',
                      'DirectoryBrowserDestination(api: api', 'canWrite: canWrite', '.refreshable']:
            self.assertIn(value, text)

    def test_inbox_notice_files_and_states_are_one_group(self):
        text = page('ShareInboxView.swift', 'ShareInboxView:')
        body = text.split('var body: some View', 1)[1].split('@MainActor private func load', 1)[0]
        self.assertEqual(body.count('Section {'), 1)
        self.assertEqual(body.count('SoftGroupRows {'), 1)
        for value in ['SoftGroupRow("notice")', 'SoftGroupRow("file-" + item.id.uuidString)',
                      'SoftGroupRow("empty")', 'SoftGroupRow("loading")', 'SoftGroupRow("error")',
                      '.disabled(selection.isEmpty || busy)', '.interactiveDismissDisabled(busy)', 'selection.formIntersection']:
            self.assertIn(value, text)

if __name__ == '__main__':
    unittest.main()
