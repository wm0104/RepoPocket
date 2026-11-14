"""Continuous local-project dashboard and remote-branch controls."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')


class CompactLocalMainGroupsTests(unittest.TestCase):
    def test_project_main_has_one_nonempty_section_for_related_functions(self):
        page = source('LocalProjectView.swift')
        main = page.split('private var projectList:', 1)[1].split('private var projectSheets:', 1)[0]
        self.assertEqual(main.count('Section {'), 1)
        self.assertNotIn('Section("', main)
        self.assertIn('state.snapshot != nil || importer.busy || !importer.message.isEmpty || showsProjectStatus', main)
        self.assertIn('if showsProjectStatus {', main)
        self.assertIn('SoftGroupRows {', main)
        self.assertIn('SoftGroupRows(spacingBefore: state.snapshot == nil && !importer.busy && importer.message.isEmpty ? 0 : 10)', main)
        for value in ['summarySection(snapshot)', 'pullResultSection(pullSummary)', 'changesSection(snapshot)',
                      'actionsSection(snapshot)', 'historySection(snapshot)',
                      'Text("未完成的本地合并 · 优先处理")',
                      '.disabled(busy || !valid).accessibilityIdentifier("localgit.conflict-session")',
                      '.task { visible = true; await check(); refreshExternalChanges() }',
                      '.onDisappear { visible = false; state.cancel(); importer.cancel(); resetHistoryPages() }']:
            self.assertIn(value, main)

    def test_project_subgroups_connect_corners_and_keep_titles_and_clean_state(self):
        page = source('LocalProjectView.swift')
        for start, end in [('summarySection', 'pullResultSection'), ('pullResultSection', 'pullFileLabel'),
                           ('changesSection', 'changeRow'), ('actionsSection', 'historySection'),
                           ('historySection', 'historyIdentity')]:
            body = page.split('private func ' + start + '(', 1)[1].split('private func ' + end + '(', 1)[0]
            with self.subTest(group=start):
                self.assertNotIn('Section {', body)
                self.assertNotIn('Section("', body)
        self.assertIn('SoftGroupRows(animateBackground: false, spacingBefore: importer.busy || !importer.message.isEmpty ? 10 : 0)', page)
        self.assertIn('SoftGroupRows(animateBackground: false, spacingBefore: 10)', page)
        history = page.split('private func historySection(', 1)[1].split('private func historyIdentity(', 1)[0]
        self.assertIn('SoftGroupRows(animateBackground: false, spacingBefore: 10)', history)
        for value in ['Text("本次拉取结果")', 'Text("工作区变化 · \\(snapshot.status.files.count)")',
                      'Text("工作区干净")', 'if snapshot.status.files.isEmpty && snapshot.status.canCommit',
                      '.onChange(of: key) { _ in resetHistoryPages() }',
                      '.onChange(of: historyExpanded) { expanded in if !expanded { resetHistoryPages() } }']:
            self.assertIn(value, page)

    def test_branch_picker_has_one_section_with_dynamic_final_edges(self):
        branch = source('DesktopViews.swift').split('struct BranchPickerView:', 1)[1]
        body = branch.split('var body: some View {', 1)[1].split('private var switcherSection:', 1)[0]
        self.assertEqual(body.count('Section {'), 1)
        self.assertIn('switcherSection\n                    createSection', body)
        self.assertNotIn('if busy { Section', body)
        switcher = branch.split('private var switcherSection:', 1)[1].split('@ViewBuilder private var createSection:', 1)[0]
        create = branch.split('@ViewBuilder private var createSection:', 1)[1].split('private func load()', 1)[0]
        self.assertNotIn('Section {', switcher + create)
        self.assertNotIn('Section("', switcher + create)
        self.assertIn('SoftGroupRows(bottom: !(canWrite && api.isCurrentSession) && deletionMessage.isEmpty && !busy)', switcher)
        self.assertIn('SoftGroupRows(top: false, bottom: deletionMessage.isEmpty && !busy)', create)
        for value in ['Text("切换远端浏览分支")', 'for b in branches',
                      '.accessibilityIdentifier("remote-branch-" + b.name)', '.disabled(!canDelete(b))']:
            self.assertIn(value, switcher)
        self.assertIn('Text("从当前分支创建")', create)
        self.assertIn('.disabled(busy || head.isEmpty || !DesktopRules.validBranch(name))', create)

    def test_existing_branch_dialogs_and_local_selection_guards_remain(self):
        page = source('LocalProjectView.swift')
        branch = source('DesktopViews.swift').split('struct BranchPickerView:', 1)[1]
        for value in ['state.toggleSelection(paths)', 'state.toggleSelection(row.selectable)',
                      '.disabled(commitBlockedReason != nil)',
                      '.disabled(busy || !state.fresh || !valid || snapshot.status.repoState != 0 || snapshot.status.mergePending == true)',
                      '.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())',
                      'LocalGitHistoryContext(api: api, status: snapshot.status, remote: snapshot.history.remote, generation: generation, isValid: { valid })']:
            self.assertIn(value, page)
        for value in ['.task { await load(); await captureHead(); await captureDefaultBranch() }',
                      '.onDisappear { deletion?.cancel() }', '.sheet(item: $merging)',
                      '.appTextInputAlert("重命名 GitHub 远端分支"',
                      '.confirmationDialog("删除 GitHub 远端分支？"',
                      'try await api.createBranch(repo, name: name, from: current, expectedHead: head)',
                      'guard canDelete(target), let expectedHead = target.commit?.sha else {']:
            self.assertIn(value, branch)


if __name__ == '__main__':
    unittest.main()
