"""Local Git page grouping contracts; native Git behavior remains separately tested."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')


def page(text, name):
    return text.split('struct ' + name + ': View {', 1)[1].split('\nstruct ', 1)[0]


def sections(text):
    return len(re.findall(r'\bSection\s*[({]', text))


class CompactGitGroupsTests(unittest.TestCase):
    def test_stage_status_file_directions_and_commit_form_are_connected(self):
        text = source('LocalGitStageView.swift')
        self.assertEqual(sections(text), 1)
        self.assertIn('SoftGroupRows(bottom: snapshot == nil)', text)
        self.assertIn('SoftGroupRows(top: false, bottom: false)', text)
        self.assertIn('SoftGroupRows(top: false)', text)
        self.assertIn('SoftGroupRow("commit-heading")', text)
        self.assertIn('SoftGroupRow("heading")', text)
        self.assertIn('SoftGroupRow("file:" + file.path)', text)
        self.assertNotIn('SoftGroupRow(file.path)', text)
        for unchanged in ['fileSection(snapshot.staged, staged: true, snapshot: snapshot)',
                          'fileSection(snapshot.unstaged, staged: false, snapshot: snapshot)',
                          'LocalGitStageDiffView(', '.disabled(!ready)',
                          'Button("确认本地提交") { if ready { mutate("commitStaged") } }',
                          '.onDisappear { visible = false; task?.cancel(); confirming = false }']:
            self.assertIn(unchanged, text)

    def test_branch_management_keeps_each_branch_record_in_one_page_group(self):
        text = source('LocalGitBranchManagement.swift')
        self.assertEqual(sections(text), 1)
        for title in ['local-heading', 'remote-heading']:
            self.assertIn('SoftGroupRow("' + title + '")', text)
        self.assertEqual(text.count('SoftGroupRow(branch.id) { branchButton(branch) }'), 2)
        for unchanged in ['.onDisappear { operation?.cancel() }', '.sheet(item: $merging)',
                          '.alert("切换分支？"', '.confirmationDialog("删除本地分支？"',
                          '.contextMenu {', '.disabled(busy || branch.current || !valid)']:
            self.assertIn(unchanged, text)

    def test_conflict_status_files_and_continue_form_share_one_group(self):
        text = source('LocalGitConflictView.swift')
        self.assertEqual(sections(text), 1)
        self.assertIn('SoftGroupRow("file:" + file.path)', text)
        self.assertNotIn('SoftGroupRow(file.path)', text)
        for title in ['direction-heading', 'files-heading', 'continue-heading', 'empty-session']:
            self.assertIn('SoftGroupRow("' + title + '")', text)
        for unchanged in ['LocalGitConflictEditor(', '.disabled(busy || !valid || session.phase != "resolving")',
                          '.disabled(!ready)', 'confirmation = "conflictContinue"; confirming = true',
                          'confirmation = "conflictAbort"; confirming = true', '.onDisappear { task?.cancel() }']:
            self.assertIn(unchanged, text)

    def test_merge_preview_groups_connect_without_enabling_writes_or_changing_confirmation(self):
        text = source('LocalGitMerge.swift')
        self.assertEqual(sections(text), 1)
        self.assertIn('SoftGroupRows(bottom: !mergePending && state.preview == nil)', text)
        self.assertIn('SoftGroupRows(top: false, bottom: state.preview == nil)', text)
        self.assertIn('SoftGroupRows(top: false, bottom: false)', text)
        self.assertIn('SoftGroupRows(top: false)', text)
        for title in ['direction-heading', 'conflicts-heading', 'author-heading', 'commits-heading', 'files-heading']:
            self.assertIn('SoftGroupRow("' + title + '")', text)
        for unchanged in ['.disabled(state.busy || !valid)', 'UIRules.withoutAnimation { mergeCommitsExpanded.toggle() }',
                          'UIRules.withoutAnimation { mergeFilesExpanded.toggle() }',
                          'guard canConfirm else { return }', 'confirmation = preview; confirming = true',
                          '.alert("确认合并到当前分支？"',
                          '.onDisappear { operation?.cancel(); confirming = false; confirmation = nil }']:
            self.assertIn(unchanged, text)

    def test_merge_source_description_and_existing_branch_choices_share_a_group(self):
        text = source('LocalGitMergeSourcePicker.swift')
        self.assertEqual(sections(text), 1)
        self.assertIn('SoftGroupRow("branches-heading")', text)
        for unchanged in ['for branch in branches.local.filter({ !$0.current && !$0.remote })',
                          'LocalGitMergeView(', '.disabled(!valid || busy)',
                          '.task { await load() }', '.refreshable { await load() }']:
            self.assertIn(unchanged, text)

    def test_remote_and_repository_picker_feedback_are_not_detached_cards(self):
        text = source('LocalGitPickers.swift')
        remote = page(text, 'LocalProjectRemoteView')
        repositories = page(text, 'LocalGitRepositoryPicker')
        branches = page(text, 'LocalGitBranchPicker')
        for view in [remote, repositories, branches]:
            self.assertEqual(sections(view), 1)
            self.assertNotIn('.softGroupedRow(', view)
        for title in ['busy', 'failure']:
            self.assertIn('SoftGroupRow("' + title + '")', remote)
        for title in ['loading', 'failure', 'retry']:
            self.assertIn('SoftGroupRow("' + title + '")', repositories)
        self.assertIn('.confirmationDialog("关联此 GitHub 仓库？"', remote)
        for unchanged in ['Button { select(repository); dismiss() }', '.searchable(text: $query',
                          '.refreshable { await load() }', 'api.cachedCollection(.owned)']:
            self.assertIn(unchanged, repositories)
        self.assertIn('if more { SoftGroupRow("more")', branches)

    def test_import_form_keeps_control_disabled_scopes_and_final_feedback_connected(self):
        text = source('LocalProjectImportView.swift')
        self.assertEqual(sections(text), 1)
        self.assertIn('SoftGroupRows(bottom: false)', text)
        self.assertIn('SoftGroupRows(top: false, bottom: false)', text)
        self.assertIn('SoftGroupRows(top: false)', text)
        for title in ['repository-heading', 'association-heading', 'start']:
            self.assertIn('SoftGroupRow("' + title + '")', text)
        self.assertNotIn('.softGroupedRow(', text)
        for unchanged in ['.disabled(busy || preview != nil)', '.disabled(!preview.canCommit)',
                          '.disabled(busy)', '.sheet(item: $picker)', '.id(request.id)',
                          '.onDisappear { job?.cancel() }', '.appTextInputAlert("关联项目文件夹"',
                          'try store.attach(folder); dismiss()',
                          'UIRules.withoutAnimation { importDetailsExpanded.toggle() }']:
            self.assertIn(unchanged, text)


if __name__ == '__main__':
    unittest.main()
