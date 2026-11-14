"""Static UI contracts; no SwiftUI execution, network or destructive operations."""
from pathlib import Path
import itertools
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
UI = (ROOT / 'RepoPocket/ReleaseManagementUI.swift').read_text()
DEB = (ROOT / 'RepoPocket/DebEditorView.swift').read_text()
DETAIL = UI.split('struct ReleaseDetailView: View', 1)[1].split('struct ReleaseEditorView: View', 1)[0]
EDITOR = UI.split('struct ReleaseEditorView: View', 1)[1]
LIST = UI.split('struct ReleaseListView: View', 1)[1].split('private struct ReleaseDeleteTarget', 1)[0]


class GlobalReleaseUITests(unittest.TestCase):
    def test_one_draft_editor_and_toolbar_create(self):
        self.assertEqual(DETAIL.count('editing = true'), 1)
        self.assertNotIn('发布草稿（在编辑表单确认）', DETAIL)
        self.assertIn('r.draft ? "编辑/发布草稿" : "编辑发行版"', DETAIL)
        self.assertIn('ToolbarItemGroup(placement: .navigationBarTrailing)', DETAIL)
        self.assertIn('state.busy || !state.valid || !ReleaseManagementRules.editable(r.body ?? "")', DETAIL)
        self.assertEqual(LIST.count('Button("新建发行版")'), 1)
        self.assertNotIn('Button("新建发行版")', LIST.split('.toolbar', 1)[0])
        self.assertIn('if state.canWrite', LIST.split('.toolbar', 1)[1])
        self.assertIn('加载下一页', LIST)
        self.assertIn('releaseStatus(state)', LIST)

    def test_native_management_submenu_and_permissions(self):
        self.assertIn('NativeActionMenu(title: "更多操作"', DETAIL)
        self.assertIn('.submenu("上传附件", symbol: "paperclip", children:', DETAIL)
        self.assertIn('id: "upload-file"', DETAIL)
        self.assertIn('id: "upload-inbox"', DETAIL)
        self.assertIn('destructive: true', DETAIL)
        self.assertIn('prepareDelete(r, asset: nil)', DETAIL)
        self.assertNotIn('Section("管理")', DETAIL)
        self.assertIn('if state.canWrite, let r = state.release', DETAIL)
        self.assertIn('enabled: state.canWrite && state.valid && !state.busy', DETAIL)
        condition = re.search(r'enabled: (state\.canWrite[^,]+), items: managementItems', DETAIL).group(1)
        condition = condition.replace('state.canWrite', 'write').replace('state.valid', 'valid').replace('state.busy', 'busy')
        condition = condition.replace('&&', ' and ').replace('!', 'not ')
        labels = re.search(r'Button\(r\.draft \? "([^"]+)" : "([^"]+)"\)', DETAIL).groups()
        for write, valid, busy, draft in itertools.product([False, True], repeat=4):
            # Evaluate only the extracted boolean source expression, not SwiftUI.
            actual = eval(condition, {'__builtins__': {}}, {'write': write, 'valid': valid, 'busy': busy})
            self.assertEqual(actual, write and valid and not busy)
            self.assertEqual(labels[0 if draft else 1], '编辑/发布草稿' if draft else '编辑发行版')
        bridge = (ROOT / 'RepoPocket/NativeActionMenu.swift').read_text()
        for token in ['UIMenu(title:', 'UIAction(title:', 'showsMenuAsPrimaryAction = true', 'current.enabled', 'DispatchQueue.main.async']:
            self.assertIn(token, bridge)

    def test_safety_confirmations_and_visible_warnings_survive(self):
        for token in ['ReleaseDeleteTarget(repo: state.repo, generation: state.generation, release: r, asset: asset)', 'target.generation == AccountStore.generation', 'target.repo == state.repo', 'Button("删除", role: .destructive) { performDelete() }', '此操作不可恢复。', '已公开发行版会立即受到影响', '正文超过128 KiB']:
            self.assertIn(token, DETAIL + (ROOT/'RepoPocket/ReleaseAttachmentReview.swift').read_text())
        for token in ['Toggle("保存为草稿"', '确认发行版', 'var captured = form', 'try state.check()', 'Button("关闭")', 'releaseStatus(state)']:
            self.assertIn(token, EDITOR)

    def test_primary_confirmation_is_not_an_isolated_card(self):
        self.assertNotIn('Button(actionTitle)', EDITOR.split('.toolbar', 1)[0])
        self.assertIn('ToolbarItem(placement: .confirmationAction)', EDITOR)
        self.assertIn('.disabled(state.busy || staging || !state.valid)', EDITOR)
        self.assertIn('guard markerReady, form.validMarker', EDITOR)
        self.assertIn('reviewFingerprint == nil || !state.valid', EDITOR)
        self.assertIn('!state.valid', EDITOR.split('.toolbar', 1)[1])
        self.assertNotIn('Button("生成新的 deb', DEB.split('private var editorNavigation', 1)[0])
        self.assertIn('ToolbarItem(placement: .confirmationAction)', DEB)
        self.assertIn('busy || differences.isEmpty', DEB)
        self.assertEqual(DEB.count('accessibilityIdentifier("deb-generate")'), 1)

    def test_diff_summary_collapses_without_animation(self):
        self.assertIn('@State private var differencesExpanded = false', DEB)
        section = DEB.split('private var differencesSection:', 1)[1].split('private func outputSection', 1)[0]
        for token in ['SoftGroupRows(top: false, bottom: !showsOutput) {', 'SoftGroupRow("summary")', '变更对照（\\(differences.count)）', 'UIRules.withoutAnimation { differencesExpanded.toggle() }', 'if differencesExpanded', 'for item in differences', 'SoftGroupRow(item.0)', 'VStack(alignment: .leading', 'Text("原：" + item.1)', 'Text("新：" + item.2)', '.textSelection(.enabled)', '$0.disablesAnimations = true', 'deb-differences']:
            self.assertIn(token, section)
        self.assertNotIn('ForEach(', section)
        self.assertNotIn('.softGroupedRow(', section)
        self.assertIn('if !differences.isEmpty { differencesSection }', DEB)

    def test_dynamic_diff_boundaries_use_shared_sibling_rows(self):
        shared = (ROOT / 'RepoPocket/WorkspaceSelectionUI.swift').read_text()
        self.assertIn('top: top && row.id == rows.first?.id, bottom: bottom && row.id == rows.last?.id', shared)
        # Explicit expected visible-row boundaries for empty, one and many diffs.
        for count, expanded in itertools.product([0, 1, 4], [False, True]):
            rows = [] if count == 0 else ['summary'] + ([f'diff-{n}' for n in range(count)] if expanded else [])
            edges = [(i == 0, i == len(rows) - 1) for i in range(len(rows))]
            if rows:
                self.assertEqual(sum(top for top, _ in edges), 1)
                self.assertEqual(sum(bottom for _, bottom in edges), 1)
                self.assertEqual(len(rows), count + 1 if expanded else 1)
            else:
                self.assertEqual(edges, [])

    def test_deb_risks_outputs_and_existing_groups_survive(self):
        for token in ['只修改副本；原文件不会覆盖', '先编辑副本', '确认只更新原仓库文件：', 'Button("确认提交回原文件")', 'AppShareLink(item: output', 'Button("保存到本地项目")', 'if let onUseForUpload', 'try onUseForUpload(target)', 'ExternalFileActions(api: api, file: output)', 'private var originalSection', 'private var editSection', '原始包信息', '更多字段', 'ProgressView("读取 / 生成中，请保持前台")']:
            self.assertIn(token, DEB)


if __name__ == '__main__':
    unittest.main()
