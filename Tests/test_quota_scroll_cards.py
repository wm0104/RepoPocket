"""QuotaWatch host/card contract. Source tests are not native animation evidence."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
def source(name): return (ROOT / 'RepoPocket' / name).read_text()
class QuotaScrollCardTests(unittest.TestCase):
    def test_three_hosts_use_scroll_stack_and_directory_keeps_list(self):
        app = source('RepoPocketApp.swift')
        home = app.split('struct RepositoriesView:', 1)[1].split('struct BrowserView:', 1)[0]
        settings = app.split('struct SettingsView:', 1)[1].split('private struct SettingsAppearanceRow:', 1)[0]
        browser = app.split('struct BrowserView:', 1)[1].split('struct FileView:', 1)[0]
        self.assertIn('QuotaScrollStack {', home)
        self.assertIn('QuotaScrollStack {', settings)
        self.assertNotIn('Form {', settings)
        self.assertIn('if path.isEmpty && !showFiles {\n                QuotaScrollStack {', browser)
        self.assertIn('List {', browser)
        self.assertIn('directoryRows', browser)
    def test_reference_layout_has_no_custom_animation(self):
        shared = source('WorkspaceSelectionUI.swift').split('struct QuotaScrollStack', 1)[1]
        for token in ['ScrollView {', 'VStack(spacing: 10)', 'VStack(spacing: 0)', 'cornerRadius: 14', '.secondarySystemGroupedBackground']:
            self.assertIn(token, shared)
        for token in ['withAnimation', '.animation(', 'GeometryReader', '.frame(height:']:
            self.assertNotIn(token, shared)
    def test_disclosures_are_whole_cards_not_soft_list_rows(self):
        for name, start, end in [('RepoPocketApp.swift','private struct SettingsAppearanceRow:', None), ('PersonalIssuesView.swift','struct PersonalIssuesSection:', 'struct PersonalIssueRow:'), ('CollaborationViews.swift','struct RepositoryCommunitySection:', 'struct CollaborationListView:')]:
            part = source(name).split(start,1)[1]
            if end: part = part.split(end,1)[0]
            self.assertIn('QuotaCard', part)
            self.assertIn('DisclosureGroup(', part)
            self.assertIn('.padding(12)', part)
            self.assertNotIn('SoftGroupRow(', part)
            self.assertNotIn('withAnimation', part)
    def test_opt_in_groups_are_one_container_and_navigation_resets_style(self):
        shared = source('WorkspaceSelectionUI.swift')
        self.assertIn('static let defaultValue = SoftGroupPresentation.list', shared)
        self.assertIn('if presentation == .cards', shared)
        self.assertIn('QuotaCard {', shared)
        self.assertIn('.environment(\\.softGroupPresentation, .list)', shared)
    def test_ios15_refresh_reuses_environment_action_and_cancels_on_detach(self):
        shared = source('WorkspaceSelectionUI.swift')
        for token in ['@Environment(\\.refresh)', 'if #available(iOS 16.0, *)', 'QuotaLegacyRefresh(action: refresh)',
                      'UIRefreshControl()', 'await action()', 'task?.cancel()', 'dismantleUIView',
                      'target.alwaysBounceVertical = true', 'target.refreshControl = control']:
            self.assertIn(token, shared)
        app = source('RepoPocketApp.swift')
        self.assertIn('.refreshable { refreshing = true; await refresh(); loadPersonalIssues(reset: true); refreshing = false }', app)
        self.assertIn('.refreshable { await refreshProfile() }', app)

    def test_scroll_navigation_restores_neutral_text_without_tinting_actions(self):
        shared = source('WorkspaceSelectionUI.swift')
        label = shared.split('struct QuotaNavigationLabel', 1)[1].split('struct QuotaCard', 1)[0]
        self.assertIn('.foregroundStyle(Color.primary, Color.secondary, Color(uiColor: .tertiaryLabel))', label)
        self.assertIn('.foregroundStyle(Color(uiColor: .tertiaryLabel))', label)
        self.assertNotIn('.tint(', label)
        more = source('CollaborationViews.swift').split('struct RepositoryCommunitySection:', 1)[1].split('struct CollaborationListView:', 1)[0]
        # Reuse the same neutral labels for disclosure actions as ordinary navigation.
        self.assertIn('Text("贡献者、统计与工具")', more)
        self.assertIn('Text("仓库作者")', more)
        self.assertEqual(more.split('DisclosureGroup(isExpanded: $expanded)', 1)[1].count('QuotaNavigationLabel {'), 2)
        self.assertIn('}.buttonStyle(.plain).tint(.accentColor)', more)
        self.assertIn('Image(systemName: "chart.bar").foregroundStyle(Color.accentColor)', more)
        self.assertIn('.buttonStyle(.borderless)', more)
        self.assertIn('}.tint(.secondary).padding(12)', more)
        highlights = source('RepositoryHomeHighlights.swift')
        self.assertNotIn('查看说明与下载附件', highlights)
        self.assertIn('Button("重试读取发行版")', highlights)
        for name, symbol in [('RepositorySections.swift', 'section.systemImage'),
                             ('UserConnectionsView.swift', 'kind.symbol')]:
            self.assertIn('Image(systemName: ' + symbol + ').foregroundStyle(Color.accentColor)', source(name))
        app = source('RepoPocketApp.swift')
        for symbol in ['safari', 'link']:
            self.assertIn('Image(systemName: "' + symbol + '").foregroundStyle(Color.accentColor)', app)
        self.assertIn('Image(systemName: "arrow.down.circle").foregroundStyle(Color.accentColor)', source('RepositorySections.swift'))
        self.assertIn('Image(systemName: "bookmark").foregroundStyle(Color.accentColor)', source('RepositoryCollectionViews.swift'))
        ui = (ROOT / 'StyleUITests/StyleBoundaryTests.swift').read_text()
        self.assertIn('assertNeutralNavigationText(app, title: title)', ui)
        helper = (ROOT / 'StyleUITests/DisclosureCardAssertions.swift').read_text()
        self.assertIn('Navigation title must use neutral text, not inherit link tint', helper)

    def test_navigation_color_check_excludes_feature_icons_and_requires_visible_ink(self):
        helper = (ROOT / 'StyleUITests/DisclosureCardAssertions.swift').read_text()
        check = helper.split('func assertNeutralNavigationText(', 1)[1].split('func assertVisibleThemeCheckmark(', 1)[0]
        self.assertIn('leadingIconWidth: CGFloat = 42', check)
        self.assertIn('frame.minX + leadingIconWidth', check)
        self.assertIn('frame.width - leadingIconWidth - 24', check)
        self.assertIn('XCTAssertGreaterThanOrEqual(ink, 8', check)
        self.assertIn('XCTAssertEqual(colored, 0', check)
        for evidence in ['navigation-color-crop-', 'navigation-color-frame-', 'navigation-color-screen-']:
            self.assertIn(evidence, check)

    def test_disclosure_wait_reuses_seed_and_keeps_three_exact_samples(self):
        helper = (ROOT / 'StyleUITests/DisclosureCardAssertions.swift').read_text()
        wait = helper.split('func assertDisclosureCard(', 1)[1].split('var last = headerFrame', 1)[0]
        for token in ['var seed: CGRect?', 'seed = frame', 'seed = nil',
                      'var previous = seed ?? .zero',
                      'var samples = previous.isEmpty ? 0 : 1',
                      'samples = frame.isEmpty ? 0 : (frame == previous ? samples + 1 : 1)',
                      'while samples < 3 && ProcessInfo.processInfo.systemUptime < deadline',
                      'let deadline = ProcessInfo.processInfo.systemUptime + 10',
                      'guard samples >= 3, ProcessInfo.processInfo.systemUptime <= deadline',
                      'cardFrame = previous']:
            self.assertIn(token, wait)
        self.assertNotIn('XCTNSPredicateExpectation', wait)
        for token in ['context=', 'header=', 'phase=', 'frame=', 'stableCount=', 'elapsed=', 'queryDuration=',
                      'disclosure-stability-timing-and-ax', 'disclosure-settle-timeout-', 'app.debugDescription']:
            self.assertIn(token, wait)
        self.assertIn('phase: String = "disclosure"', wait)
        # No re-query can silently replace the geometry actually proven stable.
        self.assertNotIn('cardFrame = card.frame', wait)

    def test_settings_wait_context_preserves_theme_and_fold_semantics(self):
        ui = (ROOT / 'StyleUITests/SettingsTests.swift').read_text()
        root = ui.split('func testProductionRootThemeCheckmarksAndSchemePersistWithoutPreviewProbe()', 1)[1].split('func testProfileAndAbout', 1)[0]
        for token in ['production-theme-', 'production-cycle-\\(cycle)-collapsed',
                      'production-cycle-\\(cycle)-expanded', 'for cycle in 0..<3',
                      'assertSelectedTheme(title, app: app)', 'assertVisibleThemeCheckmark(',
                      'app.terminate(); app.launch()', 'lightBrightness - brightness, 60']:
            self.assertIn(token, root)
        layout = ui.split('private func assertAppearanceAndAboutLayout', 1)[1].split('private func assertSelectedTheme', 1)[0]
        self.assertIn('phase: phase', layout)
        self.assertIn('expected: 10', layout)

    def test_disclosure_wait_simulated_slow_ax_empty_movement_and_deadline(self):
        # Executable model of the source-contracted transition above, not a Swift/XCTest run.
        def settle(seed, frames):
            previous, samples, elapsed = seed, int(seed is not None), 0
            for duration, frame in frames:
                if elapsed >= 10: break
                elapsed += duration
                samples = 0 if frame is None else (samples + 1 if frame == previous else 1)
                previous = frame
                if samples >= 3: return elapsed <= 10, previous, samples
                elapsed += 0.1  # Same inter-sample run-loop delay as the Swift helper.
            return False, previous, samples
        a, b = (16, 258, 361, 184), (16, 259, 361, 184)
        self.assertEqual(settle(a, [(1, a), (6, a)]), (True, a, 3))
        self.assertFalse(settle(None, [(1, a), (6, a)])[0])
        self.assertFalse(settle(a, [(1, a)])[0])  # never reduce to two samples
        self.assertFalse(settle(a, [(1, None), (1, a), (1, a)])[0])
        self.assertTrue(settle(a, [(1, None), (1, a), (1, a), (1, a)])[0])
        self.assertFalse(settle(a, [(1, a), (1, b), (1, b)])[0])
        self.assertTrue(settle(a, [(1, b), (1, b), (1, b)])[0])
        self.assertFalse(settle(a, [(4, a), (7, a)])[0])  # late AX return cannot pass
        self.assertFalse(settle(a, [(5, a), (4.95, a)])[0])  # delay counts against 10s
        self.assertFalse(settle(None, [(1, None)] * 12)[0])

    def test_business_hooks_remain(self):
        issues = source('PersonalIssuesView.swift')
        for token in ['.issueDeletionPresenter(', '.issueDeletionMenu(', 'loadPermissions()', 'api.issueDeletions', 'PersonalIssuesView(api: api, login: api.login)']:
            self.assertIn(token, issues)
        more = source('CollaborationViews.swift')
        for token in ['Button(action: openTools)', 'Button(action: openOwner)', 'branch: branch']:
            self.assertIn(token, more)
if __name__ == '__main__': unittest.main()
