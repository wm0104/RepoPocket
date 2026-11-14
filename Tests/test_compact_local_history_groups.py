"""Related local-project and history rows share one native group."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')


class CompactLocalHistoryGroupsTests(unittest.TestCase):
    def test_project_list_error_and_guidance_share_one_group(self):
        page = source('LocalProjectsView.swift')
        body = page.split('List {', 1)[1].split('.listStyle', 1)[0]
        self.assertEqual(body.count('Section {'), 1)
        self.assertEqual(body.count('SoftGroupRows {'), 1)
        self.assertNotIn('Section("', body)
        self.assertNotIn('.softGroupedRow(', body)
        for value in ['Text("本地项目")', 'if store.projects.isEmpty', 'for project in store.projects',
                      'if !store.error.isEmpty', '打开项目后下拉可检查变化。',
                      'LocalProjectView(api: api, store: store, project: project)',
                      '.contextMenu { Button("移除项目关联", role: .destructive) { removing = project } }']:
            self.assertIn(value, body)
        self.assertIn('.sheet(isPresented: $importing) { LocalProjectImportView', page)
        self.assertIn('do { try store.remove(project) } catch { message = error.localizedDescription }', page)

    def test_local_commit_confirmation_keeps_author_selection_and_submit_together(self):
        form = source('LocalProjectView.swift').split('private var commitForm:', 1)[1].split('private func summarySection', 1)[0]
        self.assertEqual(form.count('Section {'), 1)
        self.assertEqual(form.count('SoftGroupRows {'), 1)
        self.assertNotIn('Section("', form)
        self.assertNotIn('.softGroupedRow(', form)
        for value in ['Text("提交到本地分支：" + (state.snapshot?.status.branch ?? ""))',
                      'Text("本次选中文件")', 'for row in selected', 'row.path + " · " + row.label',
                      'TextField("提交说明", text: $commitMessage)', 'if authorExpanded || authorIncomplete',
                      'TextField("作者姓名", text: $authorName)', 'text: $authorEmail',
                      'UIRules.withoutAnimation { authorExpanded.toggle() }',
                      'Button("确认创建本地提交") { pendingCommit = true; sheet = nil }',
                      '.disabled(commitMessage.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || authorIncomplete)',
                      '.onAppear { authorExpanded = authorIncomplete }']:
            self.assertIn(value, form)

    def test_local_search_status_connects_to_results_without_extracting_child_state(self):
        search = source('LocalProjectEditor.swift').split('struct LocalProjectSearchView:', 1)[1]
        body = search.split('var body: some View {', 1)[1].split('private func searchStatus', 1)[0]
        self.assertEqual(body.count('Section {'), 1)
        self.assertIn('searchStatus(count: results.count)\n                searchRows(results)', body)
        status = search.split('private func searchStatus', 1)[1].split('private func searchRows', 1)[0]
        rows = search.split('private func searchRows', 1)[1].split('private func label', 1)[0]
        self.assertIn('return SoftGroupRows(bottom: count == 0)', status)
        self.assertIn('SoftGroupRows(top: false)', rows)
        for value in ['for entry in results.prefix(200)', '.disabled(filePresentation.locked || !valid)',
                      'guard valid else { return }; filePresentation.open(path: entry.path)',
                      'LocalProjectFilesView(api: api, project: project, internalRoot: internalRoot']:
            self.assertIn(value, rows)
        for value in ['@State private var filePresentation = LocalFilePresentation()',
                      '.onDisappear { job?.cancel(); refreshTask?.cancel() }',
                      'filePresentation.didDismiss(); loaded = false; refresh()']:
            self.assertIn(value, search)

    def test_remote_history_context_and_pagination_share_commit_rows(self):
        history = source('DesktopViews.swift').split('struct HistoryView:', 1)[1].split('struct CommitDetailView:', 1)[0]
        body = history.split('var body: some View {', 1)[1].split('private func load', 1)[0]
        self.assertEqual(body.count('Section {'), 1)
        self.assertEqual(body.count('SoftGroupRows {'), 1)
        self.assertNotIn('.softGroupedRow(', body)
        for value in ['Text(repo).font(.caption)', 'Text("分支：" + branch).font(.caption)',
                      'for c in commits', 'CommitDetailView(api: api, repo: repo, sha: c.sha)',
                      '.font(.system(size: messageSize, weight: .medium))', '.padding(.vertical, 7)',
                      'if busy && commits.isEmpty', 'if commits.isEmpty && !busy',
                      'Button("加载更多提交") { Task { await load() } }.disabled(busy)',
                      'if commits.isEmpty { await load() }', '.refreshable { await load(refresh: true) }']:
            self.assertIn(value, body)

    def test_remote_commit_message_files_and_load_state_are_one_group(self):
        detail = source('DesktopViews.swift').split('struct CommitDetailView:', 1)[1].split('struct BranchPickerView:', 1)[0]
        body = detail.split('var body: some View {', 1)[1].split('private func load', 1)[0]
        self.assertEqual(body.count('Section {'), 1)
        self.assertEqual(body.count('SoftGroupRows {'), 1)
        self.assertNotIn('Section("', body)
        self.assertNotIn('.softGroupedRow(', body)
        for value in ['Text("提交")', 'Text("变更文件")', 'for f in files',
                      'CommitPatchDestination(file: f)', 'if let old = f.previous_filename',
                      '.lineLimit(messageExpanded ? nil : 4)', '.padding(.vertical, 6)',
                      'messageExpanded.toggle()', 'if busy', 'if more',
                      'Button(detail == nil ? "加载详情" : "加载更多文件")', '.disabled(busy)',
                      '.task { if detail == nil { await load() } }']:
            self.assertIn(value, body)

    def test_local_commit_detail_preserves_mounted_message_state_and_history_guards(self):
        page = source('LocalProjectHistoryView.swift').split('struct LocalProjectCommitView:', 1)[1]
        body = page.split('var body: some View {', 1)[1].split('private func commitMessage', 1)[0]
        self.assertEqual(body.count('Section {'), 1)
        self.assertEqual(body.count('SoftGroupRows {'), 1)
        self.assertNotIn('Section("', body)
        self.assertNotIn('.softGroupedRow(', body)
        for value in ['Text("本地提交")', 'Text("变更文件 · \\(detail.files.count)")',
                      'commitMessage(detail.message)', 'if messageNeedsExpansion',
                      'if let workspace', 'LocalGitHistoryActions(project:',
                      '.disabled(!workspace.isValid() || workspace.generation != AccountStore.generation)',
                      'for file in detail.files', 'CommitPatchDestination(file: file)',
                      'if detail.files.isEmpty && !detail.truncated', 'if detail.truncated',
                      'if busy', 'if !failure.isEmpty', 'Task { await load(refresh: true) }',
                      '.task { await load() }']:
            self.assertIn(value, body)
        for value in ['@StateObject private var request', '@State private var messageExpanded',
                      '@State private var messageNeedsExpansion', 'isValid: { generation == AccountStore.generation }']:
            self.assertIn(value, page)


if __name__ == '__main__':
    unittest.main()
