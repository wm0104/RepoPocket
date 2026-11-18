"""Source regressions for device feedback; these are not iPhone UI tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')


class DeviceUIFeedbackTests(unittest.TestCase):
    def test_global_actions_keep_default_accent_without_neutral_tint_overrides(self):
        root = source('RepoPocketApp.swift').split('struct AccountRootView:', 1)[0]
        self.assertNotIn('.tint(Color.primary)', root)
        self.assertNotIn('.accentColor(.primary)', root)
        window = source('WindowStyleApplier.swift')
        self.assertNotIn('tintColor', window)
        self.assertIn('overrideUserInterfaceStyle = style', window)
        self.assertNotIn('preferredControlTintColor = .label', source('NativeLinkDestination.swift'))
        share = (ROOT / 'ShareExtension/ShareViewController.swift').read_text(encoding='utf-8')
        self.assertNotIn('view.tintColor = .label', share)
        self.assertIn('a { color: #0969da; text-decoration: underline; }', source('ReadmeDocument.swift'))
        self.assertIn('a { color: #58a6ff; }', source('ReadmeDocument.swift'))

    def test_function_icons_keep_accent_or_status_colors_but_navigation_text_stays_neutral(self):
        community = source('CollaborationViews.swift')
        for title, color in [('议题', 'green'), ('拉取请求', 'blue'), ('操作 · Actions', 'orange'), ('更多', 'gray')]:
            self.assertRegex(community, rf'RepositoryFeatureLabel\(title: "{title}"[^\n]*color: \.{color}\)')
        label = source('WorkspaceSelectionUI.swift').split('struct QuotaNavigationLabel', 1)[1].split('struct QuotaCard', 1)[0]
        self.assertIn('.foregroundStyle(Color.primary, Color.secondary, Color(uiColor: .tertiaryLabel))', label)
        self.assertIn('.foregroundStyle(Color(uiColor: .tertiaryLabel))', label)
        self.assertIn('foregroundStyle(Color.accentColor)', source('RepoPocketApp.swift'))
        self.assertIn('selectedState: { appearance == mode }', source('RepoPocketApp.swift'))
        self.assertIn('Color.green', source('ReleaseAssetDownloadStatusView.swift'))
        self.assertIn('0x9a / 255.0', source('WorkflowViews.swift'))
        preview = source('StylePreviewGallery.swift')
        self.assertIn('Text("更改分支").foregroundStyle(.blue)', preview)

    def test_theme_pixel_check_requires_the_native_leading_neutral_checkmark(self):
        helper = (ROOT / 'StyleUITests/DisclosureCardAssertions.swift').read_text(encoding='utf-8')
        check = helper.split('func assertVisibleThemeCheckmark(', 1)[1]
        self.assertIn('frame.minX + 4', check)
        self.assertIn('rgb.max()! - rgb.min()! < 50', check)
        self.assertIn('XCTAssertGreaterThan(ink, 8', check)
        self.assertIn('XCTAssertEqual(ink, 0', check)
        self.assertNotIn('frame.maxX - 26', check)

    def test_theme_host_observes_storage_and_native_menu_resolves_the_latest_selection(self):
        appearance = source('RepoPocketApp.swift').split('struct SettingsOptionsMenu:', 1)[1]
        self.assertIn('@AppStorage("appearance.mode")', appearance)
        body = appearance.split('var body: some View {', 1)[1]
        self.assertIn('NativeActionMenu(', body)
        self.assertIn('selected: appearance == mode, selectedState: { appearance == mode }', body)
        self.assertIn('{ appearance = mode }', body)
        self.assertNotIn('AnyView', appearance)
        self.assertNotIn('.id(', appearance)

    def test_home_release_removes_single_action_menu_but_keeps_retry(self):
        page = source('RepositoryHomeHighlights.swift')
        self.assertNotIn('NativeActionMenu', page)
        self.assertNotIn('刷新发行版', page)
        for token in ['Text("发行版")', 'Text("全部发行版")',
                      'ReleaseManagementDestination(api: api, repo: repo, id: release.id)',
                      'Button("重试读取发行版")', '.task(id: requestKey',
                      'api.isCurrentSession && AccountStore.generation == generation']:
            self.assertIn(token, page)

    def test_input_alert_erases_unselected_os_branch_at_modifier_boundary(self):
        alert = source('AppTextInputAlert.swift')
        self.assertIn('func body(content: Content) -> AnyView', alert)
        self.assertEqual(alert.count('return AnyView('), 2)
        for token in ['if #available(iOS 16.0, *)', 'content.alert(', 'content.sheet(',
                      'inputField', 'Button("取消", role: .cancel)',
                      'guard enabled else { return }', 'confirmAction()']:
            self.assertIn(token, alert)
        self.assertIn('.appTextInputAlert("重命名 GitHub 远端分支"', source('DesktopViews.swift'))

    def test_workflow_labeled_content_erases_versioned_body_metadata(self):
        labeled = source('AppCompatibility.swift').split('struct AppLabeledContent', 1)[1].split('struct AppAdaptiveLayout', 1)[0]
        self.assertIn('var body: AnyView', labeled)
        self.assertEqual(labeled.count('return AnyView('), 2)
        for token in ['if #available(iOS 16.0, *)', 'LabeledContent { content() }',
                      'HStack(alignment: .firstTextBaseline)', 'Spacer(minLength: 12)',
                      'content().foregroundStyle(.secondary).multilineTextAlignment(.trailing)']:
            self.assertIn(token, labeled)
        self.assertIn('AppLabeledContent("仓库", value: repo)', source('WorkflowViews.swift'))

    def test_update_header_removes_extra_padding_not_menu_hit_area(self):
        update = source('UpdateFeature.swift').split('struct AppUpdateSection:', 1)[1]
        self.assertIn('.softGroupedRow(top: !connected, cardVerticalPadding: 0)', update)
        self.assertIn('Image(systemName: "ellipsis").frame(width: 44, height: 44)', update)
        shared = source('WorkspaceSelectionUI.swift')
        modifier = shared.split('private struct SoftGroupRowPresentation:', 1)[1].split('struct QuotaScrollStack', 1)[0]
        self.assertIn('let cardVerticalPadding: CGFloat', modifier)
        self.assertIn('.padding(.vertical, cardVerticalPadding).frame(minHeight: 44)', modifier)

    def test_release_labels_use_existing_neutral_colors_and_native_disclosure(self):
        detail = source('ReleaseManagementUI.swift').split('struct ReleaseDetailView:', 1)[1].split('private func assetActions', 1)[0]
        self.assertIn('Text("发布说明").foregroundStyle(Color.primary)', detail)
        self.assertIn('}.tint(.secondary)', detail)
        self.assertIn('Text(asset.name).foregroundStyle(Color.primary)', detail)
        self.assertIn('.font(.caption).foregroundStyle(Color.secondary).monospacedDigit()', detail)
        self.assertNotIn('Color.black', detail)
        self.assertNotIn('Image(systemName: "chevron.right")', detail)
        self.assertIn('assetActions(asset)', detail)

    def test_repository_more_reuses_existing_navigation_label(self):
        more = source('CollaborationViews.swift').split('DisclosureGroup(isExpanded: $expanded)', 1)[1].split('struct CollaborationListView:', 1)[0]
        self.assertEqual(more.count('QuotaNavigationLabel {'), 2)
        self.assertNotIn('Image(systemName: "chevron.right")', more)
        self.assertIn('Button(action: openTools)', more)
        self.assertIn('Button(action: openOwner)', more)
        self.assertIn('RepositoryFeatureLabel(title: "更多"', more)


if __name__ == '__main__':
    unittest.main()
