"""Settings-specific regression contracts; native Swift fixture skips without swiftc.

Source assertions check wiring only, not SwiftUI/UIKit rendering or actual hit testing.
The Swift fixture executes extracted production descriptions/coordinator using UIKit mocks.
"""
from pathlib import Path
import ast
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / 'RepoPocket' / name).read_text()


def theme_expression():
    settings = source('RepoPocketApp.swift').split('struct SettingsView:', 1)[1]
    return re.search(r'(\[\("system", "跟随系统"\).*?\n\s*\})\)', settings, re.S).group(1)


class SettingsMenuStateTests(unittest.TestCase):
    def test_theme_selection_is_read_at_menu_resolution_not_captured_as_bool(self):
        expression = theme_expression()
        self.assertIn('selectedState: { appearance == mode }', expression)
        self.assertIn('{ appearance = mode }', expression)
        settings = source('RepoPocketApp.swift').split('struct SettingsView:', 1)[1]
        self.assertIn('@AppStorage("appearance.mode") private var appearance = "system"', settings)
        self.assertIn('singleSelection: true', settings)
        bridge = source('NativeActionMenu.swift')
        self.assertIn('var selectedState: (() -> Bool)? = nil', bridge)
        self.assertIn('state: (item.selectedState?() ?? item.selected) ? .on : .off', bridge)
        # Ordinary selected/enabled snapshots and delayed current-ID actions stay supported.
        for token in ['var selected = false', 'context.coordinator.items = items',
                      'UIDeferredMenuElement.uncached', 'DispatchQueue.main.async',
                      'self.action(item.id, in: self.items)', 'current.enabled else { return }',
                      'current.perform()']:
            self.assertIn(token, bridge)

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
        toolbar = settings.split('.toolbar {', 1)[1].split('.task {', 1)[0]
        self.assertIn('accessibilityIdentifier: "settings-options"', toolbar)
        self.assertIn(']).frame(width: 44, height: 44)', toolbar)
        section = source('UpdateFeature.swift').split('struct AppUpdateSection:', 1)[1]
        label = section.split('} label: { Image(systemName: "ellipsis")', 1)[1].split('}.softGroupedRow', 1)[0]
        self.assertIn('.frame(width: 44, height: 44)', label)
        self.assertIn('.contentShape(Rectangle())', label)
        self.assertIn('accessibilityIdentifier("settings-update-options")', label)

    def test_ui_waits_for_picker_exit_and_real_settings_hit_targets(self):
        # Host source contract only: this does not reproduce native UI timing.
        ui = (ROOT / 'StyleUITests/SettingsTests.swift').read_text()
        self.assertIn('let cancel = app.buttons["workspace.import.cancel"]', ui)
        folder = ui.split('cancel.tap()', 1)[1].split('for attempt in 1...2', 1)[0]
        self.assertIn('waitForElement(cancel, matching: "exists == false", app: app)', folder)
        self.assertIn('waitForElement(options, matching: "exists == true AND hittable == true AND enabled == true", app: app)', folder)
        safari = ui.split('for attempt in 1...2', 1)[1].split('private func openTheme', 1)[0]
        self.assertLess(safari.index('let updateOptions = updateMenuControl('), safari.index('updateOptions.tap()'))
        control = ui.split('private func updateMenuControl', 1)[1].split('private func waitForElement', 1)[0]
        for token in ['app.buttons["settings-update-options"]', 'root.descendants(matching: .button)',
                      '$0.exists && $0.isEnabled && $0.isHittable', 'actual.count, 1',
                      'root.frame.contains(actual[0].frame)', 'recordUpdateMenu(app, checkpoint: checkpoint)',
                      'XCTAssertEqual(result, .completed']:
            self.assertIn(token, control)
        self.assertIn('recordUpdateMenu(app, checkpoint: "before-folder-picker")', ui)
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

    @unittest.skipUnless(shutil.which('swiftc'), 'Live production callback fixture requires Swift compiler; not a native UI test')
    def test_production_live_selection_with_defaults_and_current_actions(self):
        bridge = source('NativeActionMenu.swift')
        item = 'struct NativeMenuItem {' + bridge.split('struct NativeMenuItem {', 1)[1].split('struct NativeActionMenu:', 1)[0]
        coordinator = 'final class Coordinator {' + bridge.split('    final class Coordinator {', 1)[1].split('\n}\n\n/// Keep', 1)[0]
        # Reuse the existing network-free UIKit mock, not a rewritten coordinator.
        tree = ast.parse((ROOT / 'Tests/test_native_action_menu.py').read_text())
        mocks = next(ast.literal_eval(node.value) for node in ast.walk(tree)
                     if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'mocks' for t in node.targets))
        fixture = (ROOT / 'Tests/Fixtures/SettingsMenuStateHarness.swift').read_text()
        fixture = fixture.replace('// PRODUCTION_THEME_EXPRESSION', theme_expression())
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'settings-menu.swift'
            path.write_text(mocks + item + coordinator + fixture)
            binary = str(Path(temp) / 'settings-menu')
            subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', binary], check=True)
            subprocess.run([binary], check=True)


if __name__ == '__main__':
    unittest.main()
