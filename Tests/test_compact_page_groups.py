"""Layout contracts for continuous related rows; no simulator appearance claim."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')


def view(text, name):
    return text.split('struct ' + name, 1)[1].split('\nstruct ', 1)[0]


class CompactPageGroupsTests(unittest.TestCase):
    def test_repository_overview_joins_sections_without_losing_child_state(self):
        browser = view(source('RepoPocketApp.swift'), 'BrowserView:')
        body = browser.split('var body: some View', 1)[1].split('.listStyle', 1)[0]
        self.assertIn('Section {\n                    repositoryHeader\n                    repositoryOverview\n                }', body)
        overview = browser.split('@ViewBuilder private var repositoryOverview:', 1)[1].split('@SoftGroupRowsBuilder private var directoryRows:', 1)[0]
        self.assertIn('SoftGroupRows(spacingBefore: 10)', overview)
        self.assertEqual(overview.count('connected: true'), 3)
        header = browser.split('@ViewBuilder private var repositoryHeader:', 1)[1].split('@ViewBuilder private var repositoryOverview:', 1)[0]
        self.assertNotIn('Section {', header)
        self.assertIn('softGroupedRow(bottom: true)', header)
        for filename, name in [('CollaborationViews.swift', 'RepositoryCommunitySection'),
                               ('RepositoryHomeHighlights.swift', 'RepositoryHomeHighlights'),
                               ('RepositoryReadmeSection.swift', 'RepositoryReadmeSection')]:
            with self.subTest(view=name):
                page = view(source(filename), name)
                self.assertIn('var connected = false', page)
                self.assertIn('if connected {', page)
                self.assertIn('spacingBefore: connected ? 10 : 0', page)
        community = view(source('CollaborationViews.swift'), 'RepositoryCommunitySection')
        self.assertIn('@State private var expanded = false', community)
        self.assertIn('expanded.toggle()', community)
        highlights = source('RepositoryHomeHighlights.swift')
        for text in ['Text("发行版")', 'Text("最近一次 Actions · 所有分支")',
                     '.task(id: requestKey + (revalidationID?.uuidString ?? "")) { await loadRelease() }', '.task(id: requestKey + (revalidationID?.uuidString ?? "")) { await loadRuns() }']:
            self.assertIn(text, highlights)
        readme = source('RepositoryReadmeSection.swift')
        self.assertIn('SoftGroupRows(spacingBefore: connected ? 10 : 0)', readme)
        self.assertNotIn('SoftGroupRow("expand")', readme)
        self.assertIn('.task(id: requestKey + (revalidationID?.uuidString ?? "")) { await load() }', readme)
        shared = source('WorkspaceSelectionUI.swift')
        self.assertIn('top: top && row.id == rows.first?.id', shared)
        self.assertIn('bottom: bottom && row.id == rows.last?.id', shared)

    def test_footer_only_builds_a_section_when_it_has_rows(self):
        footer = view(source('CollaborationViews.swift'), 'CommunityPageFooter')
        self.assertIn('@SoftGroupRowsBuilder var rows: [SoftGroupRow]', footer)
        body = footer.split('var body: some View', 1)[1]
        self.assertLess(body.index('if !rows.isEmpty'), body.index('Section {'))
        for condition in ['if store.busy', 'if !store.error.isEmpty', 'if store.more', 'if store.limited']:
            self.assertIn(condition, footer)
        self.assertEqual(footer.count('SoftGroupRow("page:'), 4)
        self.assertIn('.disabled(store.busy)', footer)
        self.assertIn('buildExpression(_ rows: [SoftGroupRow]) -> [SoftGroupRow] { rows }', source('WorkspaceSelectionUI.swift'))

    def test_related_pagination_rows_share_the_content_group(self):
        for filename, names in [('WorkflowViews.swift', ['WorkflowRunView', 'WorkflowArtifactsView']),
                                ('CollaborationViews.swift', ['CollaborationListView', 'PullFilesView']),
                                ('DiscoveryViews.swift', ['CommunityEventsView', 'CommunityDiscoveryView', 'RepositoryContributorsView']),
                                ('NativeFileHistoryView.swift', ['NativeFileHistoryView']),
                                ('NativeStatisticsView.swift', ['NativeDevelopersView']),
                                ('PersonalIssuesView.swift', ['PersonalIssuesView']),
                                ('UserConnectionsView.swift', ['UserConnectionsView'])]:
            for name in names:
                with self.subTest(view=name):
                    page = view(source(filename), name)
                    self.assertIn('CommunityPageFooter(store: store, next: { load() }).rows', page)
        files = view(source('CollaborationViews.swift'), 'PullFilesView')
        self.assertIn('SoftGroupRow("file-" + file.id)', files)
        self.assertIn('SoftGroupRow("patch-scope") { Text("二进制或部分大文件没有文本 patch；不代表没有变化。")', files)
        self.assertEqual(files.count('Section {'), 1)
        self.assertLess(files.index('CommunityPageFooter(store:'), files.index('SoftGroupRow("patch-scope")'))
        discussion = view(source('CollaborationViews.swift'), 'DiscussionView')
        self.assertIn('let pageRows = CommunityPageFooter(store: store, next: { load() }).rows', discussion)
        self.assertIn('if comment.id == store.items.last?.id { pageRows }', discussion)
        self.assertIn('if store.items.isEmpty && (store.loaded || !pageRows.isEmpty)', discussion)

    def test_step_actions_are_real_sibling_rows_in_the_fixture_and_shipping_view(self):
        for filename in ['WorkflowViews.swift', 'SourceStylePreview.swift']:
            text = source(filename)
            self.assertIn('SoftGroupRow("full-log-', text)
            self.assertIn('accessibilityIdentifier("workflow-job-log")', text)
        inline = view(source('WorkflowViews.swift'), 'WorkflowInlineLog')
        self.assertNotIn('NavigationLink("全屏查看此步骤日志")', inline)
        test = (ROOT / 'StyleUITests/StyleBoundaryTests.swift').read_text(encoding='utf-8')
        self.assertIn('taskRow.frame.minY - fullRow.frame.maxY', test)
        self.assertIn('No detached card gap between related log actions', test)

    def test_code_summary_and_directory_are_one_continuous_group(self):
        browser = view(source('RepoPocketApp.swift'), 'BrowserView:')
        self.assertIn('@SoftGroupRowsBuilder private var directoryRows: [SoftGroupRow]', browser)
        self.assertIn('SoftGroupRow("repository-summary")', browser)
        self.assertIn('accessibilityIdentifier("repository-code-summary")', browser)
        self.assertIn('accessibilityIdentifier("repository-entry-" + e.path)', browser)
        body = browser.split('var body: some View', 1)[1].split('.listStyle', 1)[0]
        self.assertIn('SoftGroupRow("repository-summary")', body)
        self.assertIn('directoryRows', body)
        self.assertIn('if path.isEmpty && !showFiles', body)
        for route in ['DirectoryBrowserDestination(api: api, repo: repo, path: e.path, branch: activeBranch)',
                      'FileView(api: api, repo: repo, entry: e, branch: activeBranch, canWrite: canWrite)']:
            self.assertIn(route, browser)
        test = (ROOT / 'StyleUITests/StyleBoundaryTests.swift').read_text(encoding='utf-8')
        self.assertIn('firstFile.frame.minY - summary.frame.maxY', test)
        self.assertIn('Repository summary and code rows must form one continuous group', test)


if __name__ == '__main__':
    unittest.main()
