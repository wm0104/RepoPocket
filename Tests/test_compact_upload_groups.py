"""Continuous upload/target groups without changing their shipping actions."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')


class CompactUploadGroupsTests(unittest.TestCase):
    def test_upload_form_has_one_section_and_keeps_live_child_views(self):
        upload = source('UploadView.swift')
        form = upload.split('Form {', 1)[1].split('.appGroupedFormStyle()', 1)[0]
        self.assertIn('Section {\n                    fileSection\n                    commitSection', form)
        self.assertEqual(form.count('Section {'), 1)
        self.assertNotIn('if busy { Section', form)
        files = upload.split('private var fileSection:', 1)[1].split('private func removePending', 1)[0]
        commit = upload.split('private var commitSection:', 1)[1].split('private func pendingActions', 1)[0]
        self.assertNotIn('Section(', files + commit)
        self.assertNotIn('Section {', files + commit)
        self.assertIn('Text("本地文件")', files)
        self.assertIn('Text("提交到仓库")', commit)
        self.assertIn('Text("待提交 · \\(queue.count) 个项目")', commit)
        self.assertEqual(commit.count('SoftGroupRows('), 1)
        self.assertIn('SoftGroupRows(top: false, bottom: !busy)', commit)

    def test_commit_review_and_confirmation_are_continuous_sibling_rows(self):
        review = source('UploadView.swift').split('.sheet(isPresented: $confirmCommit)', 1)[1].split('.sheet(item: $targetPicker', 1)[0]
        self.assertEqual(review.count('Section {'), 1)
        self.assertNotIn('Section("', review)
        self.assertIn('SoftGroupRows {', review)
        self.assertIn('SoftGroupRow("review-title") { Text("最终提交预览")', review)
        for value in ['for item in queue', 'if let sha = item.sha', 'if let head = item.head',
                      'if busy', 'if !reviewError.isEmpty', 'Button("检查并重试")',
                      'Button("确认提交以上全部项目")', 'Task { await preflightCommit() }',
                      '.disabled(busy || reviewFingerprint == nil || !api.isCurrentSession)',
                      '.task { await preflightCommit() }', '.interactiveDismissDisabled(busy)']:
            self.assertIn(value, review)

    def test_target_picker_has_one_dynamic_group_for_path_actions_and_entries(self):
        picker = source('TargetPickerView.swift')
        body = picker.split('var body: some View {', 1)[1].split('private func load()', 1)[0]
        self.assertEqual(body.count('Section {'), 1)
        self.assertEqual(body.count('SoftGroupRows {'), 1)
        self.assertNotIn('Section("', body)
        self.assertNotIn('.softGroupedRow(', body)
        for value in ['SoftGroupRow("folders-title")', 'Text("文件夹")',
                      'SoftGroupRow("files-title")', 'filesOnly ? "选择删除文件" : "替换已有文件"',
                      'for e in entries.filter({ $0.type == "dir" })',
                      'for e in entries.filter({ $0.type == "file" })',
                      'if !filesOnly', 'if !foldersOnly', 'if !path.isEmpty',
                      'selected(path, nil)', 'selected((e.path as NSString).deletingLastPathComponent, e)',
                      'filesOnly: filesOnly, foldersOnly: foldersOnly, selected: selected']:
            self.assertIn(value, body)
        self.assertIn('@State private var entries:', picker)
        self.assertIn('.task { await load() }', body)
        self.assertIn('entries = try await api.contents(repo, path: path, branch: branch)', picker)

    def test_upload_permissions_lifecycle_and_touch_targets_are_retained(self):
        upload = source('UploadView.swift')
        for value in ['.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())',
                      '.frame(width: 44, height: 44)', '.disabled(repo.isEmpty || !canWrite)',
                      '.disabled(busy).transaction { $0.animation = nil; $0.disablesAnimations = true }',
                      '.task(id: repo) { await loadWriteAccess() }',
                      '.onChange(of: branch) { _ in invalidateTarget() }',
                      'generation == targetGeneration, api.isCurrentSession',
                      'try adoptGeneratedDeb(generated, replacing: item.id)',
                      'if pendingDeletion != nil { confirmQueueDelete = true }',
                      'if pendingReplacement != nil { confirmReplacement = true }']:
            self.assertIn(value, upload)


if __name__ == '__main__':
    unittest.main()
