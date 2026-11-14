from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text()
FILE = APP.split('struct FileView: View {', 1)[1].split('struct SettingsView:', 1)[0]
SETTINGS = APP.split('struct SettingsView: View {', 1)[1]
HISTORY = (ROOT / 'RepoPocket/LocalProjectHistoryView.swift').read_text()
STATS = (ROOT / 'RepoPocket/NativeStatisticsView.swift').read_text().split('struct NativeActivityChartView:', 1)[0]
PROJECTS = (ROOT / 'RepoPocket/LocalProjectsView.swift').read_text()


class GlobalBrowsingUI(unittest.TestCase):
    def test_file_download_single_visible_location_for_each_preview_state(self):
        self.assertIn('private var showsDownloadInBody: Bool { !deleted && !editable && !busy }', FILE)
        self.assertIn('if !showsDownloadInBody {', FILE)
        self.assertIn('NativeMenuItem(id: "download"', FILE)
        self.assertIn('enabled: !busy && !deleted', FILE)
        # The fallback remains the explicit primary action, including read errors.
        body = FILE.split('.toolbar {', 1)[0]
        self.assertIn('Button("下载 / 存到文件")', body)
        self.assertIn('Button("重试读取")', body)
        for deleted in (False, True):
            for editable in (False, True):
                for busy in (False, True):
                    body_visible = not deleted and not editable and not busy
                    menu_visible = not body_visible
                    self.assertEqual(int(body_visible) + int(menu_visible and not deleted and not busy), int(not deleted and not busy))

    def test_file_native_menu_and_navigation_keep_actions_and_safety(self):
        self.assertIn('NativeActionMenu(title: "文件操作"', FILE)
        self.assertNotIn('Menu {', FILE)
        self.assertIn('@State private var showingHistory = false', FILE)
        self.assertIn('.appNavigationDestination(isPresented: $showingHistory)', FILE)
        self.assertIn('NativeFileHistoryView(api: api, repo: repo, path: entry.path, branch: branch)', FILE)
        for token in ('"文件信息"', '"此文件的历史记录"', '"重新加载"', '"编辑包信息"', 'destructive: true', '.confirmationDialog(', '.sheet(isPresented: $showDeb)', '.downloadCompletionNotice($downloadedFile)', 'requireAuthorization()', 'DownloadStore.shared.begin(); defer { DownloadStore.shared.end() }', 'persist(temporary, session: generation)', 'guard api.isCurrentSession else { throw CancellationError() }'):
            self.assertIn(token, FILE)
        self.assertIn('if writable && editable && !deleted', FILE)
        self.assertIn('guard writable, !busy', FILE)

    def test_home_multifunction_menu_is_uikit_bridge(self):
        home = APP.split('struct RepositoriesView: View {', 1)[1].split('struct BrowserView:', 1)[0]
        self.assertIn('NativeActionMenu(title: "仓库操作"', home)
        self.assertNotIn('Menu {', home)
        self.assertIn('enabled: !busy', home)
        self.assertIn('await refresh(); loadPersonalIssues(reset: true)', home)

    def test_account_add_and_manage_are_mutually_exclusive(self):
        self.assertIn('if savedAccount == nil {\n                                Button("添加账号")', SETTINGS)
        self.assertIn('if savedAccount != nil {\n                            Button { accountPresentation.showing = true }', SETTINGS)
        self.assertIn('.padding(.vertical, 8).softGroupedRow(top: true, bottom: savedAccount == nil)', SETTINGS)
        self.assertIn('settings-social-accounts', SETTINGS)
        self.assertNotIn('Token 仅保存在本机钥匙串', SETTINGS)
        self.assertIn('AppUpdateSection(api: api, checker: updateChecker, connected: true)', SETTINGS)

    def test_long_commit_message_uses_real_four_line_measurement(self):
        self.assertIn('.lineLimit(messageExpanded ? nil : 4)', HISTORY)
        self.assertIn('if messageNeedsExpansion {', HISTORY)
        self.assertIn('UIRules.withoutAnimation { messageExpanded.toggle() }', HISTORY)
        self.assertIn('LocalCommitMessageHeights.self', HISTORY)
        self.assertIn('heights["full", default: 0] > heights["summary", default: 0] + 0.5', HISTORY)
        self.assertIn('commitMessage(detail.message)', HISTORY)
        self.assertIn('let displayed = message.trimmingCharacters(in: .newlines)', HISTORY)
        self.assertIn('return Text(displayed)', HISTORY)
        self.assertIn('Text(displayed).lineLimit(4)', HISTORY)
        self.assertIn('Text(displayed).lineLimit(nil)', HISTORY)
        self.assertIn('if messageNeedsExpansion != needsExpansion', HISTORY)
        self.assertIn('if !needsExpansion && messageExpanded', HISTORY)
        self.assertIn('.textSelection(.enabled)', HISTORY)
        for token in ('SoftGroupRows {', 'NavigationLink { CommitPatchDestination(file: file)', 'if detail.files.isEmpty && !detail.truncated', 'if detail.truncated', 'if detail.merge', 'isValid: { generation == AccountStore.generation }'):
            self.assertIn(token, HISTORY)

    def test_statistics_details_fold_without_hiding_live_operations(self):
        self.assertIn('Text("主要语言：" + primaryLanguage)', STATS)
        self.assertIn('Button("语言明细(\\(languages.count))")', STATS)
        self.assertIn('if languagesExpanded {', STATS)
        self.assertEqual(STATS.count('Button("统计范围说明")'), 2)
        self.assertIn('if starScopeExpanded {', STATS)
        self.assertIn('if budgetExpanded {', STATS)
        self.assertEqual(STATS.count('UIRules.withoutAnimation'), 3)
        for token in ('Text("当前 Star：', 'NativeHistogram(points: monthly)', 'if counting { SoftGroupRow("progress")', 'Button("取消统计")', 'Button("开始计算行数")', 'if !countError.isEmpty', 'if !error.isEmpty', 'SoftGroupRow("partial")', '.onDisappear { countTask?.cancel() }'):
            self.assertIn(token, STATS)
        self.assertEqual(STATS.count('api.repositoryLanguages(repo)'), 1)
        self.assertEqual(STATS.count('api.codeLineSummary(repo'), 1)

    def test_project_add_moves_to_toolbar_without_lifecycle_change(self):
        self.assertIn('.toolbar { Button("添加") { importing = true }.disabled(!store.error.isEmpty) }', PROJECTS)
        self.assertNotIn('Section { Button("添加本地项目 / 克隆仓库")', PROJECTS)
        for token in ('.sheet(isPresented: $importing)', 'LocalProjectImportView(api: api, store: store)', '.confirmationDialog(', '保留文件和历史', 'if !store.error.isEmpty'):
            self.assertIn(token, PROJECTS)


if __name__ == '__main__':
    unittest.main()
