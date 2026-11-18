"""Structural guardrails only; actual hit targets/frames/pixels live in StyleUITests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DisclosureCardTests(unittest.TestCase):
    def test_appearance_observes_storage_in_the_real_child_not_an_anyview_builder(self):
        text = (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text()
        settings, child = text.split('struct SettingsOptionsMenu:', 1)
        settings = settings.split('struct SettingsView:', 1)[1]
        self.assertIn('SettingsOptionsMenu()', settings)
        self.assertNotIn('@AppStorage("appearance.mode")', settings)
        for token in ['@AppStorage("appearance.mode")', 'appearance = mode', 'selected: appearance == mode',
                      'selectedState: { appearance == mode }', 'singleSelection: true']:
            self.assertIn(token, child)
        self.assertNotIn('AnyView', child)
        self.assertNotIn('.id(', child)

    def test_appearance_uses_reference_native_toolbar_menu_with_44pt_hit_area(self):
        child = (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text().split('struct SettingsOptionsMenu:', 1)[1]
        self.assertIn('NativeActionMenu(title: "设置选项", accessibilityIdentifier: "settings-options"', child)
        self.assertIn('.frame(width: 44, height: 44)', child)
        self.assertNotIn('DisclosureGroup', child)
        self.assertNotIn('.onTapGesture', child)

    def test_more_is_one_native_row_with_full_width_native_header(self):
        more = (ROOT / 'RepoPocket/CollaborationViews.swift').read_text().split('QuotaCard(accessibilityID: "repository-community-card") {', 1)[1].split('struct CollaborationListView:', 1)[0]
        self.assertIn('DisclosureGroup(isExpanded: $expanded)', more)
        label = more.split('} label: {\n                        RepositoryFeatureLabel', 1)[1]
        self.assertIn('.frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)', label)
        self.assertIn('.contentShape(Rectangle())', label)
        self.assertNotIn('.onTapGesture', more)

    def test_native_root_test_does_not_substitute_an_appstorage_probe(self):
        ui = (ROOT / 'StyleUITests/SettingsTests.swift').read_text()
        root = ui.split('func testProductionRootThemeCheckmarksAndSchemePersistWithoutPreviewProbe()', 1)[1].split('func testProfileAndAbout', 1)[0]
        for token in ['app.launchArguments = []', 'app.tabBars.buttons["设置"].tap()',
                      'assertSelectedTheme(title, app: app)', 'assertVisibleThemeCheckmark(',
                      'disclosureHeaderBrightness(', 'assertSettingsLayout(', 'app.terminate(); app.launch()']:
            self.assertIn(token, root)
        self.assertNotIn('waitForTheme(', root)
        self.assertNotIn('settings-theme-probe', root)

    def test_native_visual_guards_check_expanded_cell_geometry_and_pixels(self):
        helper = (ROOT / 'StyleUITests/DisclosureCardAssertions.swift').read_text()
        for token in ['header.coordinate(withNormalizedOffset:', 'header.frame.height + 24, 44',
                      'cardFrame.contains(child.frame)', 'card.descendants(matching: .button)',
                      'frame.minY + 1', 'frame.maxY - 2',
                      'through: lastChild.minY + 2', 'distance(pixel(x, y), fill)',
                      'if title == selectedTitle', 'The old row must erase its checkmark']:
            self.assertIn(token, helper)
        boundary = (ROOT / 'StyleUITests/StyleBoundaryTests.swift').read_text()
        more = boundary.split('func testRepositoryMoreReusesDisclosureAndRemovesConditionalTailRows()', 1)[1].split('func testWorkflowFilters', 1)[0]
        self.assertIn('childIDs: ["repository-more-tools", "repository-more-owner"]', more)
        self.assertIn('repository-more-expanded-', more)

    def test_transition_positions_the_whole_card_and_rejects_hidden_corners(self):
        ui = (ROOT / 'StyleUITests/NativeDisclosureTests.swift').read_text()
        self.assertIn('let card = disclosureCard(app, headerID: headerID)', ui)
        self.assertIn('let visibleTop = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : 0', ui)
        self.assertIn('card.frame.minY, visibleTop + 4', ui)
        self.assertIn('card.frame.maxY, app.frame.maxY', ui)
        transition = ui.split('func testThreeScrollHostDisclosureTransitionsAndRepeatedInput()', 1)[1].split('// XCUIScreen sampling', 1)[0]
        self.assertNotIn('swipeUp()', transition)
        self.assertNotIn('thenDragTo:', transition)
        self.assertNotIn('app.frame.height * 0.35', transition)
        self.assertNotIn('where header.frame.minY > app.frame.height * 0.4', ui)
        self.assertNotIn('where card.frame.minY > app.frame.height * 0.4', ui)
        helper = (ROOT / 'StyleUITests/DisclosureCardAssertions.swift').read_text()
        for token in ['guard samples >= 3', 'cardFrame.minY >= visibleTop',
                      'cardFrame.maxY <= app.frame.maxY', 'navigationBar.frame.maxY',
                      'screenshot.pngRepresentation', 'disclosure-card-failure-frame-',
                      'XCTAssertLessThanOrEqual(delta, 8', 'corner=(', 'delta=']:
            self.assertIn(token, helper)
        self.assertNotIn('wait(forDuration:', helper)
        # Actual attempt-2 AX: the top is hidden even though More is hittable.
        card_top, card_height, navigation_bottom = 51, 337 + 1 / 3, 97 + 2 / 3
        self.assertLess(card_top, navigation_bottom)
        self.assertLess(card_top + card_height, 852)
        # Checking a same-y material background could incorrectly accept that corner.
        corner, header_bg, local_bg = (246, 251, 249), (242, 242, 247), (247, 249, 249)
        distance = lambda a, b: max(abs(x - y) for x, y in zip(a, b))
        self.assertEqual(distance(corner, header_bg), 9)
        self.assertLessEqual(distance(corner, local_bg), 8)

    def test_card_gap_measures_painted_ten_points_not_padded_ax_text(self):
        ui = (ROOT / 'StyleUITests/SettingsTests.swift').read_text()
        layout = ui.split('private func assertSettingsLayout', 1)[1].split('private func assertSelectedTheme', 1)[0]
        self.assertNotIn('about.frame.minY, card.frame.maxY + 9', layout)
        for token in ['about.isHittable', 'aboutCell.frame.contains(about.frame)',
                      'assertPaintedCardGap(app, before: card, after: aboutCell, expected: 10)']:
            self.assertIn(token, layout)
        helper = (ROOT / 'StyleUITests/DisclosureCardAssertions.swift').read_text()
        self.assertNotIn('child.frame.minY - last.maxY, 20', helper)
        gap = helper.split('func assertPaintedCardGap', 1)[1].split('func disclosureHeaderBrightness', 1)[0]
        for token in ['second.minY, first.maxY + expected, accuracy: 1', 'first.midX, first.maxX - 14',
                      'CGFloat(gray.count) / scale, expected, accuracy: 1',
                      'gray.count, high - low + 1', 'second.minY, accuracy: 1', 'distance(fill, background), 8']:
            self.assertIn(token, gap)

    def test_more_buttons_delegate_to_non_lazy_navigation_hosts(self):
        source = (ROOT / 'RepoPocket/CollaborationViews.swift').read_text()
        section = source.split('struct RepositoryCommunitySection:', 1)[1].split('struct CollaborationListView:', 1)[0]
        more = section.split('DisclosureGroup(isExpanded: $expanded)', 1)[1]
        self.assertNotIn('NavigationLink', more)
        self.assertIn('Button(action: openTools)', more)
        self.assertIn('Button(action: openOwner)', more)
        self.assertEqual(more.count('.buttonStyle(.borderless)'), 2)
        self.assertIn('let openTools: () -> Void', section)
        self.assertIn('let openOwner: () -> Void', section)
        self.assertNotIn('let avatar:', section)
        for name in ['RepoPocketApp.swift', 'StylePreviewGallery.swift']:
            host = (ROOT / 'RepoPocket' / name).read_text()
            call = host.split('RepositoryCommunitySection(', 1)[1].split('\n', 1)[0]
            self.assertIn('openTools:', call)
            self.assertIn('openOwner:', call)
            self.assertIn('.appNavigationDestination(isPresented: $showingRepositoryTools)', host)
            self.assertIn('.appNavigationDestination(isPresented: $showingRepositoryOwner)', host)
        browser = (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text()
        owner = browser.split('.appNavigationDestination(isPresented: $showingRepositoryOwner)', 1)[1].split('.task', 1)[0]
        self.assertNotIn('if let repositoryInfo', owner)
        self.assertIn('repositoryInfo?.full_name ?? repo', owner)
        self.assertIn('repositoryInfo?.owner?.login', owner)


if __name__ == '__main__':
    unittest.main()
