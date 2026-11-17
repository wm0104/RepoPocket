"""Settings-specific regression contracts; native Swift fixture skips without swiftc.

Source assertions check wiring only, not SwiftUI/UIKit rendering or actual hit testing.
Inline choices are verified by the production SettingsView UI test.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / 'RepoPocket' / name).read_text()


class SettingsMenuStateTests(unittest.TestCase):
    def test_theme_selection_reads_the_same_persisted_value_as_the_checkmark(self):
        settings = source('RepoPocketApp.swift').split('struct SettingsView:', 1)[1]
        self.assertIn('@AppStorage("appearance.mode") private var appearance = "system"', settings)
        self.assertIn('Button { appearance = mode }', settings)
        self.assertIn('let selectedAppearance = appearance', settings)
        self.assertIn('if selectedAppearance == mode {', settings)
        self.assertIn('.accessibilityAddTraits(selectedAppearance == mode ? [.isSelected] : [])', settings)

    def test_preview_does_not_reset_persisted_theme_on_reload(self):
        preview = source('SettingsStylePreview.swift')
        self.assertIn('@AppStorage("appearance.mode")', preview)
        self.assertNotIn('appearance = "system"', preview.split('}.task {', 1)[1])
        self.assertIn('settings-theme-probe', preview)

    def test_official_release_presentation_is_owned_outside_transient_menu(self):
        section = source('UpdateFeature.swift').split('struct AppUpdateSection:', 1)[1]
        self.assertIn('@State private var showingOfficialReleases = false', section)
        menu = section.split('Menu {', 1)[1].split('}.softGroupedRow(top:', 1)[0]
        self.assertNotIn('InAppLinkButton(', menu)
        self.assertNotIn('.sheet(', menu)
        self.assertIn('Button("官方发行版页")', menu)
        self.assertIn('DispatchQueue.main.async { showingOfficialReleases = true }', menu)
        sheet = section.split('.sheet(isPresented: $showingOfficialReleases)', 1)[1].split('.sheet(item: $share', 1)[0]
        self.assertIn('ContainedWebPage(url: URL(string: "https://github.com/wm0104/RepoPocket/releases")!', sheet)
        self.assertIn('showingOfficialReleases = false', sheet)
        self.assertNotIn('UIApplication.shared.open', section)
        self.assertIn('Task { await checker.check(api: api) }', section)
        self.assertIn('onDismiss: { checker.sharing = false }', section)
        self.assertIn('safariViewControllerDidFinish', source('NativeLinkDestination.swift'))

    def test_settings_entries_keep_explicit_44_point_bounds(self):
        bridge = source('NativeActionMenu.swift')
        self.assertEqual(bridge.count('constraint(greaterThanOrEqualToConstant: 44)'), 2)
        settings = source('RepoPocketApp.swift').split('struct SettingsView:', 1)[1]
        self.assertIn('.frame(minHeight: 44).contentShape(Rectangle())', settings)
        self.assertIn('.accessibilityIdentifier("settings-appearance")', settings)
        section = source('UpdateFeature.swift').split('struct AppUpdateSection:', 1)[1]
        label = section.split('} label: { Image(systemName: "ellipsis")', 1)[1].split('}.softGroupedRow', 1)[0]
        self.assertIn('.frame(width: 44, height: 44)', label)
        self.assertIn('.contentShape(Rectangle())', label)
        self.assertIn('accessibilityIdentifier("settings-update-options")', label)

    def test_ui_checks_inline_disclosure_and_real_update_hit_targets(self):
        # Host source contract only: this does not reproduce native UI timing.
        ui = (ROOT / 'StyleUITests/SettingsTests.swift').read_text()
        self.assertIn('let options = app.buttons["外观"]', ui)
        self.assertIn('XCTAssertFalse(app.buttons["theme-system"].exists)', ui)
        appearance = ui.split('func testProfileAndAboutStayVisibleWithInlineAppearance()', 1)[1].split('private func checkAppearanceAndPersistence', 1)[0]
        self.assertIn('checkAppearanceAndPersistence()', appearance)
        self.assertIn('settings-compact-native-menu', appearance)
        self.assertIn('func testUpdateMenuReturnsFromOfficialReleasesAfterThemeChanges()', ui)
        safari = ui.split('for attempt in 1...2', 1)[1].split('private func openTheme', 1)[0]
        self.assertLess(safari.index('let updateOptions = updateMenuControl('), safari.index('updateOptions.tap()'))
        control = ui.split('private func updateMenuControl', 1)[1].split('private func waitForElement', 1)[0]
        for token in ['app.buttons["settings-update-options"]', 'root.descendants(matching: .button)',
                      '$0.exists && $0.isEnabled && $0.isHittable', 'actual.count, 1',
                      'root.frame.contains(actual[0].frame)', 'recordUpdateMenu(app, checkpoint: checkpoint)',
                      'XCTAssertEqual(result, .completed']:
            self.assertIn(token, control)
        self.assertIn('recordUpdateMenu(app, checkpoint: "after-appearance-toggle")', ui)
        self.assertIn('XCTAssertTrue(updateOptions.isHittable)', safari)
        self.assertIn('waitForElement(done, matching: "exists == false", app: app)', safari)
        self.assertIn('waitForElement(options, matching: "exists == true AND hittable == true AND enabled == true", app: app)', safari)
        waiter = ui.split('private func waitForElement', 1)[1].split('private func', 1)[0]
        for token in ['XCTNSPredicateExpectation', 'timeout: 10', 'result != .completed',
                      'keepScreenshot(app, name:', 'XCTAttachment(string: app.debugDescription)',
                      'add(hierarchy)', 'XCTAssertEqual(result, .completed']:
            self.assertIn(token, waiter)
        self.assertNotRegex(ui, r'\bsleep\s*\(|coordinate\(')
        # Keep the actual native checkmark, theme persistence, and two Safari visits.
        self.assertIn('XCTAssertEqual(item.isSelected, title == expected', ui)
        self.assertIn('app.terminate()', ui)
        self.assertIn('waitForTheme(value, app: app)', ui)
        self.assertIn('for attempt in 1...2', ui)
        self.assertIn('XCTAssertTrue(done.isHittable)', ui)

if __name__ == '__main__':
    unittest.main()
