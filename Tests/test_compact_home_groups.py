"""Home helpers stay mounted while related navigation rows form one continuous group."""
from pathlib import Path
import itertools
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')


def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class CompactHomeGroupsTests(unittest.TestCase):
    def test_signed_in_navigation_is_one_section_with_the_original_child_views(self):
        home = between(source('RepoPocketApp.swift'), 'struct RepositoriesView: View {', 'struct BrowserView:')
        body = between(home, 'var body: some View {', '.listStyle(.insetGrouped)')
        self.assertIn('Section {\n                    if !CredentialStore.read().isEmpty {', body)
        self.assertIn('RepositoryHomeLinksSection(api: api, owned: repos, starred: starred, loaded: loaded, connected: true)', body)
        self.assertIn('UpstreamUpdatesSection(api: api, store: upstreamUpdates, connected: true)', body)
        self.assertIn('UserConnectionsSection(api: api, connected: true)', body)
        self.assertIn('PersonalIssuesSection(api: api, store: personalIssues, connected: true)', body)
        self.assertIn('.id(api.accountID + ":" + AccountStore.generation.uuidString)', body)
        self.assertIn('SoftGroupRows(spacingBefore: CredentialStore.read().isEmpty ? 0 : 10)', body)
        self.assertIn('SoftGroupRow("discovery")', body)
        self.assertIn('SoftGroupRow("permission-help")', body)
        self.assertNotIn('.softGroupedRow(', body)
        self.assertIn('ExternalInboxSection(api: api)', body)
        self.assertIn('Text("连接 GitHub 账号")', body)
        self.assertIn('@StateObject private var personalIssues = CommunityPageStore<CollaborationItem>()', home)
        self.assertIn('@StateObject private var upstreamUpdates = UpstreamUpdatesStore()', home)
        self.assertIn('.sheet(isPresented: $showUpstreamWatch)', home)

    def test_helpers_default_to_standalone_and_preserve_semantic_titles(self):
        for filename, name, end, title, boundary in [
            ('RepositorySections.swift', 'RepositoryHomeLinksSection', 'RepositoryCollectionView', '我的仓库', 'SoftGroupRows {'),
            ('UpstreamUpdates.swift', 'UpstreamUpdatesSection', 'UpstreamWatchAddView', '上游动态', 'SoftGroupRows(spacingBefore: connected ? 10 : 0)'),
            ('UserConnectionsView.swift', 'UserConnectionsSection', 'UserConnectionsView', '我的关注', 'SoftGroupRows(spacingBefore: connected ? 10 : 0)'),
            ('PersonalIssuesView.swift', 'PersonalIssuesSection', 'PersonalIssueRow', '议题', 'SoftGroupRows(spacingBefore: connected ? 10 : 0)'),
        ]:
            with self.subTest(view=name):
                text = between(source(filename), 'struct ' + name + ': View {', 'struct ' + end + ':')
                self.assertIn('var connected = false', text)
                self.assertIn('if connected { content }', text)
                self.assertIn('else { Section("' + title + '") { content } }', text)
                self.assertIn(boundary, text)
                self.assertIn('if connected { SoftGroupRow("heading") { Text("' + title + '")', text)
        personal = between(source('PersonalIssuesView.swift'), 'struct PersonalIssuesSection:', 'struct PersonalIssueRow:')
        self.assertIn('connected: Bool = false', personal)

    def test_grouping_does_not_move_auth_tasks_permission_presenters_or_entity_routes(self):
        upstream = between(source('UpstreamUpdates.swift'), 'struct UpstreamUpdatesSection:', 'struct UpstreamWatchAddView:')
        for token in ['.task { await store.refresh(api: api) }',
                      'notification.object as? String == api.accountID',
                      'store.remove(watch, api: api)', 'UpstreamUpdatesDetail(api: api, store: store, watch: watch)',
                      'Button("添加跟踪仓库", action: add)']:
            self.assertIn(token, upstream)
        issues = between(source('PersonalIssuesView.swift'), 'struct PersonalIssuesSection:', 'struct PersonalIssueRow:')
        for token in ['@State private var deletionTarget:', '.issueDeletionPresenter(api: api, state: deletions, target: $deletionTarget)',
                      r'.onChange(of: store.items.map(\.id))', '.task { loadPermissions() }',
                      '.issueDeletionMenu(api: api', 'for item in visible.prefix(3)',
                      'CollaborationDetailView(api: api, repo: repo, kind: .issues, number: item.number)']:
            self.assertIn(token, issues)
        external = source('ExternalFileActions.swift').split('struct ExternalInboxSection:', 1)[1]
        self.assertIn('if !files.isEmpty {', external)
        self.assertIn('Section("外部文件")', external)

    def test_upstream_detail_commits_and_branches_have_one_group_and_namespaced_ids(self):
        detail = between(source('UpstreamUpdates.swift'), 'private struct UpstreamUpdatesDetail:', 'private struct UpstreamWatchTargetView:')
        self.assertEqual(detail.count('Section {'), 1)
        self.assertEqual(detail.count('SoftGroupRows {'), 1)
        for token in ['SoftGroupRow("commits-heading")', 'SoftGroupRow("branches-heading")',
                      'SoftGroupRow("commit:" + commit.sha)', 'SoftGroupRow("branch:" + branch)',
                      'SoftGroupRow("no-commits")', 'SoftGroupRow("no-branches")',
                      '.suffix(30).reversed()', 'store.acknowledge(watch, api: api)',
                      'CommitDetailView(api: api, repo: watch.repository, sha: commit.sha)',
                      'UpstreamNewBranchView(api: api, store: store, repository: watch.repository, branch: branch)']:
            self.assertIn(token, detail)

    def test_first_and_last_edges_follow_visible_rows_for_authenticated_and_logged_out_home(self):
        def edges(count, top=True, bottom=True):
            return [(top and i == 0, bottom and i == count - 1) for i in range(count)]
        for signed_in, watches, issues, loading, loaded, error in itertools.product(
                (False, True), range(4), range(4), *((False, True),) * 3):
            groups = []
            if signed_in:
                groups += [edges(3)]  # repositories
                groups += [edges(1 + watches + int(loading) + int(watches == 0) + 1)]
                groups += [edges(3)]  # followers/following
                groups += [edges(1 + issues + int(loading and issues == 0) + int(loaded and issues == 0) + 2 * error + 1)]
            groups += [edges(2)]  # discovery + permission note
            for group in groups:
                self.assertTrue(group[0][0] and group[-1][1])
                self.assertTrue(all(row == (False, False) for row in group[1:-1]))
            rows = [row for group in groups for row in group]
            self.assertEqual(sum(top for top, _ in rows), 5 if signed_in else 1)
            self.assertEqual(sum(bottom for _, bottom in rows), 5 if signed_in else 1)
            self.assertTrue(rows[0][0] and rows[-1][1])


if __name__ == '__main__':
    unittest.main()
