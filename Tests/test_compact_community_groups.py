"""Connected community pages preserve their mounted state and shipping actions."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')


class CompactCommunityGroupsTests(unittest.TestCase):
    def test_detail_content_actions_and_status_are_one_group(self):
        page = source('CollaborationViews.swift').split('struct CollaborationDetailView:', 1)[1].split('struct DiscussionView:', 1)[0]
        body = page.split('var body: some View {', 1)[1].split('private func load()', 1)[0]
        self.assertEqual(body.count('Section {'), 1)
        self.assertEqual(body.count('SoftGroupRows {'), 1)
        self.assertNotIn('Section("正文")', body)
        self.assertIn('SoftGroupRow("body-heading") { Text("正文")', body)
        self.assertIn('SoftGroupRow("body") { CommunityMarkdown(', body)
        for value in ['CommunityAuthorLink(api: api, user: item.user)',
                      'if kind == .pulls', 'if item.merged != true && (mayManage || item.user?.login.caseInsensitiveCompare(api.login) == .orderedSame)',
                      'mayManage, item.state == "open", item.draft != true, item.head?.sha != nil',
                      '.task(id: revision) { await load() }', '.sheet(isPresented: $composing)',
                      '.confirmationDialog(mutationTitle', 'Task { await perform(action) }']:
            self.assertIn(value, body)

    def test_pull_file_budget_hint_is_the_final_row_not_a_detached_section(self):
        page = source('CollaborationViews.swift').split('struct PullFilesView:', 1)[1]
        self.assertEqual(page.count('Section {'), 1)
        self.assertIn('SoftGroupRow("patch-scope")', page)
        self.assertIn('二进制或部分大文件没有文本 patch；不代表没有变化。', page)
        self.assertLess(page.index('CommunityPageFooter(store:'), page.index('SoftGroupRow("patch-scope")'))
        self.assertIn('CommitPatchDestination(file: file, pullRequest: true)', page)
        self.assertIn('.onDisappear { store.cancel() }', page)

    def test_profile_is_a_connected_mounted_view_not_external_state_rows(self):
        profile = source('DiscoveryViews.swift').split('struct CommunityProfileSection:', 1)[1].split('struct CommunityEventsView:', 1)[0]
        self.assertIn('var connected = false', profile)
        self.assertIn('if connected { content }', profile)
        self.assertIn('else { Section("用户资料") { content } }', profile)
        self.assertIn('SoftGroupRows(bottom: !connected)', profile)
        for value in ['@State private var profile:', '@StateObject private var contacts',
                      '.onDisappear { contacts.cancel(); linkRequest = nil; unsupportedLink = nil }',
                      '.task(id: revision)', 'contacts.load(reset: true, api: api)', 'private func openContact']:
            self.assertIn(value, profile)
        users = source('RepositorySearchView.swift').split('struct UserRepositoriesView:', 1)[1].split('private struct SearchDismissButton:', 1)[0]
        self.assertEqual(users.count('Section {'), 1)
        self.assertIn('avatar: user.avatar_url, connected: true) { readingLink = ReadingLink(url: $0) }', users)
        self.assertNotIn('CommunityProfileSection(', users.split('var body:', 1)[0])
        self.assertIn('SoftGroupRows(top: false)', users)
        self.assertIn('for repository in repositories', users)
        self.assertIn('.sheet(item: $readingLink)', users)

    def test_discovery_filters_results_and_navigation_share_one_group(self):
        page = source('DiscoveryViews.swift').split('struct CommunityDiscoveryView:', 1)[1].split('struct RepositoryContributorsView:', 1)[0]
        body = page.split('var body:', 1)[1].split('private func load(', 1)[0]
        self.assertEqual(body.count('Section {'), 1)
        self.assertEqual(body.count('SoftGroupRows {'), 1)
        self.assertIn('Text("近期新建的热门仓库")', body)
        for value in ['Picker("时间范围", selection: $days)', 'Picker("语言", selection: $language)',
                      'CommunityPageFooter(store: store, next: { load() }).rows',
                      'NavigationLink("浏览公开开发者")', 'if !api.login.isEmpty',
                      '.onChange(of: language)', '.onChange(of: days)', '.onDisappear { store.cancel() }']:
            self.assertIn(value, body)

    def test_social_footer_is_stateless_namespaced_rows(self):
        page = source('RepositorySocial.swift')
        footer = page.split('private struct SocialPageFooter', 1)[1].split('struct RepositorySocialView:', 1)[0]
        self.assertIn(': View where', footer)
        self.assertNotIn('@State', footer)
        self.assertIn('@SoftGroupRowsBuilder var rows: [SoftGroupRow]', footer)
        for name in ['loading', 'error', 'retry', 'empty', 'more', 'limit']:
            self.assertIn('SoftGroupRow("social-page:' + name + '")', footer)
        self.assertIn('state.attempted && !state.busy', footer)
        self.assertIn('.disabled(state.busy)', footer)

    def test_social_repository_context_people_and_footer_share_one_group(self):
        page = source('RepositorySocial.swift').split('struct RepositorySocialView:', 1)[1].split('private struct SocialPersonRow:', 1)[0]
        body = page.split('var body:', 1)[1].split('private func forkUser', 1)[0]
        self.assertEqual(body.count('Section {'), 1)
        self.assertEqual(body.count('SoftGroupRows {'), 1)
        for value in ['Text(repository.full_name).font(.caption)', 'for person in stars.items',
                      'for fork in forks.items', 'if ForkPresentation.peopleOnly', 'selectedFork = fork',
                      'SocialPageFooter(state: stars', 'SocialPageFooter(state: forks',
                      '.appNavigationDestination(', '.task { guard !(isStars ? stars.attempted : forks.attempted)']:
            self.assertIn(value, body)
        self.assertEqual(body.count('retry: { Task { await retry() } }).rows'), 2)

    def test_fork_comparison_context_commit_rows_and_footer_are_continuous(self):
        page = source('RepositorySocial.swift').split('struct ForkChangesView:', 1)[1]
        body = page.split('var body:', 1)[1].split('@MainActor private func load(', 1)[0]
        self.assertEqual(body.count('Section {'), 1)
        self.assertEqual(body.count('SoftGroupRows {'), 1)
        for value in ['Text("比较双方默认分支；新增提交不一定由复刻者本人编写。")',
                      'for item in commits.items', 'CommitDetailView(api: api, repo: fork.full_name, sha: item.sha)',
                      'SocialPageFooter(state: commits', 'retry: { Task { await retry() } }).rows',
                      '.task { guard !commits.attempted else { return }; await load() }']:
            self.assertIn(value, body)


if __name__ == '__main__':
    unittest.main()
