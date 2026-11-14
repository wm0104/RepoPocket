"""Workflow/release functional groups retain native sibling rows and lifecycle guards."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1] / 'RepoPocket'


def source(name):
    return (ROOT / name).read_text(encoding='utf-8')


def view(text, name):
    selected = text.split('struct ' + name + ': View {', 1)[1]
    return re.split(r'\n(?:private )?struct \w+', selected, maxsplit=1)[0]


def sections(text):
    return len(re.findall(r'\bSection\s*(?:\(|\{)', text))


class CompactWorkflowReleaseGroupsTests(unittest.TestCase):
    def test_each_workflow_page_has_one_native_functional_section(self):
        text = source('WorkflowViews.swift')
        for name in ['WorkflowRunsView', 'WorkflowDispatchView', 'WorkflowRunView',
                     'WorkflowArtifactsView', 'WorkflowJobView']:
            with self.subTest(page=name):
                self.assertEqual(sections(view(text, name)), 1)
        run = view(text, 'WorkflowRunView')
        self.assertIn('SoftGroupRow("jobs-heading")', run)
        self.assertIn('SoftGroupRow("management-heading")', run)
        self.assertIn('总耗时按最后更新时间估算', run)
        job = view(text, 'WorkflowJobView')
        self.assertIn('SoftGroupRow("steps-heading")', job)
        self.assertIn('WorkflowLogReader(rawText: output.text)', job)
        self.assertIn('workflow-job-log', job)

    def test_dispatch_hint_and_permissions_remain_in_native_rows(self):
        dispatch = view(source('WorkflowViews.swift'), 'WorkflowDispatchView')
        self.assertIn('SoftGroupRow("schema-help")', dispatch)
        self.assertIn('工作流参数', dispatch)
        self.assertIn('仅发送此文件声明的参数。', dispatch)
        self.assertIn('.disabled(state.attempted || !api.isCurrentSession)', dispatch)
        self.assertIn('state.target(repo, api: api)', dispatch)
        self.assertIn('.interactiveDismissDisabled(state.busy)', dispatch)
        self.assertIn('state.inputValues[input.id] = $0', dispatch)
        self.assertNotIn('footer: { Text("仅发送', dispatch)

    def test_release_list_and_detail_keep_results_and_status_together(self):
        text = source('ReleaseManagementUI.swift')
        for name in ['ReleaseListView', 'ReleaseDetailView']:
            with self.subTest(page=name):
                self.assertEqual(sections(view(text, name)), 1)
        detail = view(text, 'ReleaseDetailView')
        self.assertIn('SoftGroupRow("assets-heading")', detail)
        self.assertIn('私有附件需在浏览器登录。', detail)
        self.assertIn('state.assetDownload == nil', detail)
        self.assertIn('ReleaseAssetDownloadStatusView(download:', detail)
        self.assertIn('prepareDelete(r, asset: asset)', detail)
        self.assertIn('state.busy || !state.valid', detail)

    def test_editor_helpers_are_rows_and_stateful_picker_stays_a_child_view(self):
        editor = view(source('ReleaseManagementUI.swift'), 'ReleaseEditorView')
        form = editor.split('Form {', 1)[1].split('.disabled(!state.valid)', 1)[0]
        self.assertEqual(sections(form), 1)
        self.assertIn('ReleaseBranchPicker(api:', form)
        self.assertNotIn('ReleaseBranchPicker(api:', form.split('SoftGroupRow("body")', 1)[-1])
        picker = view(source('ReleaseBranchPicker.swift'), 'ReleaseBranchPicker')
        self.assertEqual(sections(picker), 0)
        self.assertIn('Group {', picker)
        self.assertIn('@State private var expanded = false', picker)
        self.assertIn('ForEach(visible, id: \\.self)', picker)
        self.assertIn('DisclosureGroup("高级：提交 SHA"', picker)
        self.assertNotIn('VStack(alignment: .leading, spacing: 0)', picker)
        self.assertNotIn('.onDisappear', picker)
        self.assertNotIn('.rows', picker)
        self.assertIn('private var repositorySection: [SoftGroupRow]', editor)
        self.assertIn('private var attachmentSection: [SoftGroupRow]', editor)
        self.assertIn('SoftGroupRows(top: false,', form)
        self.assertIn('state: targetState, selected: $form.branch', editor)
        self.assertIn('guard targetReady, !attachments.isEmpty', editor)

    def test_release_confirmation_pages_join_preview_status_and_buttons(self):
        editor = view(source('ReleaseManagementUI.swift'), 'ReleaseEditorView')
        confirmation = editor.split('private var confirmationPage:', 1)[1].split('private func ', 1)[0]
        self.assertEqual(sections(confirmation), 1)
        self.assertIn('reviewFingerprint == nil || !state.valid', confirmation)
        self.assertIn('performConfirmedRelease()', confirmation)
        attachment = view(source('ReleaseAttachmentReview.swift'), 'ReleaseAttachmentReview')
        self.assertEqual(sections(attachment), 1)
        self.assertIn('authorizedHash == nil', attachment)
        self.assertIn('guard try await verify(attachment) == authorizedHash', attachment)
        self.assertIn('已公开发行版会立即受到影响', attachment)
        self.assertIn('.interactiveDismissDisabled(busy)', attachment)


if __name__ == '__main__':
    unittest.main()
