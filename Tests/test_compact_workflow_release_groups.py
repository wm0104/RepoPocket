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
    def test_home_release_card_is_compact_and_keeps_navigation_and_error_retry(self):
        text = source('RepositoryHomeHighlights.swift')
        self.assertIn('SoftGroupRow("release-heading", cardVerticalPadding: 0)', text)
        self.assertIn('SoftGroupRow("latest", cardVerticalPadding: 8)', text)
        self.assertNotIn('NativeActionMenu', text)
        self.assertIn('VStack(alignment: .leading, spacing: 4)', text)
        self.assertIn('Text(release.title).font(.headline)', text)
        self.assertIn('Text("最新 · " + release.tag_name + " · " + ChinaDate.day(release.date))', text)
        self.assertNotIn('查看说明与下载附件', text)
        self.assertNotIn('Label("最新正式发行版"', text)
        self.assertIn('ReleaseManagementDestination(api: api, repo: repo, id: release.id)', text)
        self.assertIn('ReleaseManagementDestination(api: api, repo: repo)', text)
        for token in ['Text("全部发行版")',
                      'SoftGroupRow("loading")', 'SoftGroupRow("empty")', 'SoftGroupRow("error")',
                      'Button("重试读取发行版")', 'api.isCurrentSession && AccountStore.generation == generation']:
            self.assertIn(token, text)

    def test_compact_padding_is_opt_in_only_for_scroll_cards(self):
        shared = source('WorkspaceSelectionUI.swift')
        row = shared.split('struct SoftGroupRow:', 1)[1].split('@resultBuilder', 1)[0]
        self.assertIn('cardVerticalPadding: CGFloat = 12', row)
        cards, native_rows = shared.split('if presentation == .cards {', 1)[1].split('} else {', 1)
        self.assertIn('.padding(.horizontal, 12)', cards)
        self.assertIn('.padding(.vertical, row.cardVerticalPadding)', cards)
        self.assertIn('.frame(minHeight: 44)', cards)
        self.assertNotIn('row.cardVerticalPadding', native_rows)

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
        self.assertIn('WorkflowLogReader(rawText: output.text, failed: step.conclusion == "failure")', job)
        self.assertIn('.id(logIdentity +', job)
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
        self.assertEqual(sections(view(text, 'ReleaseListView')), 1)
        detail = view(text, 'ReleaseDetailView')
        self.assertEqual(sections(detail), 0)
        self.assertIn('QuotaScrollStack {', detail)
        self.assertIn('QuotaCard(accessibilityID: "release-detail-card") {', detail)
        self.assertIn('VStack(spacing: 0) {', detail)
        self.assertIn('.environment(\\.softGroupPresentation, .rows)', detail)
        self.assertNotIn('List {', detail)
        self.assertNotIn('.listStyle(', detail)
        self.assertNotIn('if expanded {', detail)
        self.assertIn('DisclosureGroup(isExpanded: $expanded)', detail)
        self.assertIn('Text("发布说明").foregroundStyle(Color.primary)', detail)
        for token in ['.animation(', 'withAnimation', '.transition(', 'disablesAnimations']:
            self.assertNotIn(token, detail)
        # Native disclosure, attachments and status share the same whole-card layout.
        card = detail.split('QuotaCard(accessibilityID: "release-detail-card") {', 1)[1].split('.navigationTitle(', 1)[0]
        for token in ['SoftGroupRow("title")', 'SoftGroupRow("body")',
                      'SoftGroupRow("assets-heading")', 'releaseStatus(state, top: state.release == nil)']:
            self.assertIn(token, card)
        self.assertIn('bottom: state.assetDownload != nil || !releaseHasStatus(state)', card)
        self.assertIn('SoftGroupRow("assets-heading")', detail)
        self.assertIn('私有附件需在浏览器登录。', detail)
        self.assertIn('state.assetDownload == nil', detail)
        self.assertIn('ReleaseAssetDownloadStatusView(download:', detail)
        self.assertIn('prepareDelete(r, asset: asset)', detail)
        self.assertIn('state.busy || !state.valid', detail)

    def test_release_fold_is_checked_before_existing_attachment_actions(self):
        ui = (ROOT.parent / 'StyleUITests/StyleBoundaryTests.swift').read_text()
        release = ui.split('func testReleaseAttachmentsUseNativeActionsAndInlineDownloadStates()', 1)[1].split('\n    func ', 1)[0]
        folding = release.split('file.tap()', 1)[0]
        for token in ['app.buttons["发布说明"]', 'app.staticTexts["Download preview"]',
                      'let collapsedAssetY = file.frame.minY', 'for _ in 0..<3',
                      'description.waitForExistence', 'file.frame.minY > collapsedAssetY + 10',
                      'abs(file.frame.minY - collapsedAssetY) <= 1',
                      'Closing the notes must restore the attachment position without a blank gap']:
            self.assertIn(token, folding)
        for token in ['app.buttons["删除附件"].tap()', 'app.buttons["取消"].tap()',
                      'app.buttons["复制下载链接"].tap()', 'retry.tap()',
                      'app.buttons["取消下载"].tap()', 'app.alerts["下载完成"]']:
            self.assertIn(token, release)

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
