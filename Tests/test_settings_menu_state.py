"""Settings-specific regression contracts.

Source assertions check wiring only, not SwiftUI/UIKit rendering or actual hit testing.
Native UIKit choices are verified by the production SettingsView UI test.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / 'RepoPocket' / name).read_text()


class SettingsMenuStateTests(unittest.TestCase):
    def test_theme_selection_reads_the_same_persisted_value_as_the_checkmark(self):
        settings = source('RepoPocketApp.swift').split('struct SettingsOptionsMenu:', 1)[1]
        self.assertIn('@AppStorage("appearance.mode") private var appearance = "system"', settings)
        self.assertIn('selected: appearance == mode, selectedState: { appearance == mode }', settings)
        self.assertIn('{ appearance = mode }', settings)
        self.assertNotIn('AnyView', settings)
        self.assertNotIn('.id(', settings)

    def test_folder_picker_is_root_owned_and_reports_non_cancellation_errors(self):
        app = source('RepoPocketApp.swift').split('struct AccountRootView:', 1)[0]
        self.assertIn('.background(DownloadFolderPresentation(downloads: downloads))', app)
        self.assertNotIn('.sheet(item: $downloads.picker', app)
        self.assertNotIn('downloadPickerPresented', app)
        bridge = app.split('private struct DownloadFolderPresentation:', 1)[1]
        self.assertIn('WorkspaceDocumentPicker(request: request, allowsMultipleSelection: false, cancelTitle: "取消")', app)
        for token in ['view?.window?.rootViewController', 'while let presented = presenter.presentedViewController',
                      'presenter.present(controller, animated: true)', 'UIHostingController(rootView: picker)',
                      'UIAlertController(title: "下载位置不可用"', 'downloads.clearError()']:
            self.assertIn(token, bridge)
        self.assertNotIn('connectedScenes', bridge)
        self.assertNotIn('accountPresentation.showing', bridge)

    def test_folder_presentation_only_finishes_and_dismisses_its_own_request(self):
        app = source('RepoPocketApp.swift').split('struct AccountRootView:', 1)[0]
        bridge = app.split('private struct DownloadFolderPresentation:', 1)[1]
        for token in ['UIAdaptivePresentationControllerDelegate', 'presentationControllerDidDismiss',
                      'downloads.picker?.id == id', 'downloads.selected(urls)', 'downloads.selected(nil)',
                      'controller.dismiss(animated: true)', 'transitionCoordinator',
                      'dismantleUIView', 'coordinator.stop()']:
            self.assertIn(token, bridge)
        # Dismiss this picker, never the root/presenting sheet, and wait for its transition.
        self.assertNotIn('presenter.dismiss(', bridge)
        self.assertNotIn('rootViewController?.dismiss(', bridge)
        self.assertIn('self.controller = nil', bridge)
        self.assertIn('self.synchronize()', bridge)

    def test_preview_does_not_reset_persisted_theme_on_reload(self):
        preview = source('SettingsStylePreview.swift')
        self.assertIn('@AppStorage("appearance.mode")', preview)
        self.assertNotIn('appearance = "system"', preview.split('}.task {', 1)[1])
        self.assertIn('settings-theme-probe', preview)

    def test_existing_sheet_authorization_fixture_calls_the_real_store_without_erasing_bookmarks(self):
        preview = source('SettingsStylePreview.swift')
        for token in ['-settings-folder-sheet-preview', 'SettingsFolderAuthorizationPreview()',
                      'try await DownloadStore.shared.requireAuthorization()',
                      'setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)']:
            self.assertIn(token, preview)
        self.assertNotIn('removeObject(forKey:', preview)
        ui = (ROOT / 'StyleUITests/SettingsTests.swift').read_text()
        test = ui.split('func testFolderAuthorizationPresentsAboveExistingSheet()', 1)[1].split('func testFolderPickerCancels', 1)[0]
        for token in ['for attempt in 1...2', 'app.buttons["workspace.import.cancel"]',
                      'XCTAssertTrue(cancel.isHittable)', 'XCTAssertTrue(parent.isHittable)',
                      'label == \'已取消\'', 'settings-folder-over-existing-sheet-']:
            self.assertIn(token, test)

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

    def test_update_presentations_have_one_stable_row_owner(self):
        section = source('UpdateFeature.swift').split('struct AppUpdateSection:', 1)[1]
        header, rows = section.split('            if !checker.message.isEmpty', 1)
        for modifier in ['.sheet(isPresented: $showingOfficialReleases)',
                         '.sheet(item: $share, onDismiss: { checker.sharing = false })',
                         '.alert("使用 TrollStore 更新"']:
            self.assertIn(modifier, header)
            self.assertNotIn(modifier, rows)
        self.assertIn('}.softGroupedRow(top: !connected, cardVerticalPadding: 0)', header)

    def test_settings_entries_keep_explicit_44_point_bounds(self):
        bridge = source('NativeActionMenu.swift')
        self.assertEqual(bridge.count('constraint(greaterThanOrEqualToConstant: 44)'), 2)
        settings = source('RepoPocketApp.swift').split('struct SettingsView:', 1)[1]
        self.assertIn('.frame(width: 44, height: 44)', settings)
        self.assertIn('accessibilityIdentifier: "settings-options"', settings)
        section = source('UpdateFeature.swift').split('struct AppUpdateSection:', 1)[1]
        label = section.split('} label: { Image(systemName: "ellipsis")', 1)[1].split('}.softGroupedRow', 1)[0]
        self.assertIn('.frame(width: 44, height: 44)', label)
        self.assertIn('.contentShape(Rectangle())', label)
        self.assertIn('accessibilityIdentifier("settings-update-options")', label)

    def test_theme_probe_is_read_only_after_the_native_menu_has_closed(self):
        ui = (ROOT / 'StyleUITests/SettingsTests.swift').read_text()
        helper = ui.split('private func checkAppearanceAndPersistence()', 1)[1].split('func testFolderAuthorization', 1)[0]
        initial = helper.split('app.buttons["跟随系统"].tap()', 1)[1].split('for (title, value)', 1)[0]
        self.assertLess(initial.index('matching: "exists == false"'), initial.index('waitForTheme("system"'))
        self.assertLess(initial.index('matching: "exists == true AND hittable == true AND enabled == true"'), initial.index('waitForTheme("system"'))
        cycle = helper.split('app.buttons[title].tap()', 1)[1].split('openTheme(app); assertSelectedTheme', 1)[0]
        self.assertLess(cycle.index('matching: "exists == false"'), cycle.index('waitForTheme(value'))
        self.assertIn('addTeardownBlock', helper)
        self.assertIn('settings-state-timeout-ax', helper)

    def test_modal_picker_waits_for_files_to_exist_before_checking_interaction(self):
        ui = (ROOT / 'StyleUITests/SettingsTests.swift').read_text()
        modal = ui.split('func testFolderAuthorizationPresentsAboveExistingSheet()', 1)[1].split('func testFolderPickerCancels', 1)[0]
        self.assertLess(modal.index('cancel.waitForExistence(timeout: 10)'),
                        modal.index('matching: "exists == true AND hittable == true AND enabled == true"'))
        self.assertIn('XCTAssertTrue(cancel.isHittable)', modal)

    def test_ui_checks_real_nested_menu_and_real_update_hit_targets(self):
        # Host source contract only: this does not reproduce native UI timing.
        ui = (ROOT / 'StyleUITests/SettingsTests.swift').read_text()
        self.assertIn('let options = app.buttons["settings-options"]', ui)
        for token in ['app.buttons["通用"]', 'app.buttons["主题"]', 'app.buttons["选择文件夹"]',
                      'assertVisibleThemeCheckmark(', 'closeTheme(app)']:
            self.assertIn(token, ui)
        appearance = ui.split('func testProfileAndAboutStayVisibleWithNativeMenu()', 1)[1].split('private func checkAppearanceAndPersistence', 1)[0]
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
        self.assertIn('tapNativeSafariDone(app', safari)
        native = (ROOT / 'StyleUITests/NativeSafariAssertions.swift').read_text(encoding='utf-8')
        self.assertIn('done.isHittable', native)

if __name__ == '__main__':
    unittest.main()
