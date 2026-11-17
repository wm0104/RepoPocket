from pathlib import Path
import os, shutil, subprocess, tempfile, unittest

ROOT = Path(__file__).resolve().parents[1]
def source(name):
    return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8-sig')

def completed_text_ink(pixels, width, size_left, size_right, sx=1, sy=1):
    """Mirror DownloadCenterTests' full-strip RGB scan (not AX filename maxX)."""
    background = sum(pixels[0]) // 3
    primary = secondary = 0
    primary_right = leading_right = secondary_right = -1
    secondary_left = width
    for i, rgb in enumerate(pixels):
        x = i % width
        contrast = abs(sum(rgb) // 3 - background)
        if max(rgb) - min(rgb) > 20 or contrast < 55:
            continue
        if contrast >= 180:
            primary += 1
            primary_right = max(primary_right, x)
        if x < size_left:
            leading_right = max(leading_right, x)
        if size_left <= x < size_right and contrast < 180:
            secondary += 1
            secondary_left = min(secondary_left, x)
            secondary_right = max(secondary_right, x)
    gap = (secondary_left - max(primary_right, leading_right) - 1) / sx
    coverage = max(0, secondary_right - secondary_left + 1) / (size_right - size_left)
    return dict(primary=primary, secondary=secondary, primary_right=primary_right,
                leading_right=leading_right, secondary_left=secondary_left,
                secondary_right=secondary_right, gap_pt=gap, size_coverage=coverage,
                passed=primary >= 8 * sx * sy and secondary >= 8 * sx * sy
                and coverage >= 0.6 and gap >= 2)

class DownloadCenterTests(unittest.TestCase):
    def test_account_lifecycle_and_no_stored_credentials(self):
        model, store = source('DownloadCenterModels.swift'), source('DownloadStore.swift')
        for token in ['github.com-', 'accountID', 'cancelled, interrupted', 'state = .interrupted']:
            self.assertIn(token, model)
        for token in ['.githubAccountChanged', 'for task in tasks.values { task.cancel() }', 'attempts[id] == attempt', 'source: .local', 'Task.detached', 'fingerprint: LocalStore.snapshotFileSHA256']:
            self.assertIn(token, store)
        for token in ['CredentialStore', 'browser_download_url', 'Authorization', 'archive_download_url']:
            self.assertNotIn(token, model)
        self.assertNotIn('resumeData', store)

    def test_existing_entry_points_use_one_owner(self):
        app, workflows, release = source('RepoPocketApp.swift'), source('WorkflowViews.swift'), source('ReleaseAssetDownload.swift')
        self.assertIn('DownloadCenterView(api: api)', source('RepositorySections.swift'))
        for token in ['.archive(repo:', '.file(repo:']:
            self.assertIn(token, app)
        self.assertIn('DownloadStore.shared.download(.artifact', workflows)
        self.assertIn('DownloadStore.shared.download(.releaseAsset', release)
        self.assertIn('if !self.downloader.keepsDownloadedFile', source('ReleaseManagementUI.swift'))
        self.assertIn('preservingDownload: true', source('ReleaseManagementUI.swift'))

    def test_completed_rows_show_actual_size_and_compact_native_insets(self):
        view = source('DownloadCenterView.swift')
        row = view.split('private func row(_ record:', 1)[1].split('private func perform(', 1)[0]
        for token in ['record.fileSize.map', 'ByteCountFormatter.string(fromByteCount:', 'countStyle: .file',
                      'HStack(alignment: .firstTextBaseline, spacing: 12)', '.layoutPriority(1)',
                      'Text(size).font(.subheadline).foregroundStyle(.secondary)',
                      '.fixedSize(horizontal: true, vertical: false).accessibilityHidden(true)',
                      'EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20)',
                      '.listRowInsets(record.state == .completed ?',
                      '.accessibilityValue(size.map { record.title + "，" + $0 } ?? record.title)']:
            self.assertIn(token, row)
        for token in ['FileManager', 'attributesOfItem', 'Data(contentsOf:', 'resourceValues']:
            self.assertNotIn(token, row)
        self.assertNotIn('.frame(height:', row)
        self.assertIn('.frame(minHeight: 44)', row)
        self.assertIn('record.state == .completed ? record.fileSize.map', row)

    def test_completed_rows_only_show_filename_with_native_hit_target(self):
        view = source('DownloadCenterView.swift')
        row = view.split('private func row(_ record:', 1)[1].split('private func perform(', 1)[0]
        detail = row.split('if record.state != .completed {', 1)[1].split('}.frame(minHeight: 44)', 1)[0] if 'if record.state != .completed {' in row else ''
        self.assertIn('Text(record.source.repository)', detail)
        self.assertIn('Text(record.title)', detail)
        self.assertIn('Text(record.fileName ?? record.source.name)', row)
        self.assertIn('if record.state != .completed, !record.message.isEmpty', row)
        self.assertIn('.padding(.vertical, record.state == .completed ? 0 : 4)', row)
        self.assertIn('.accessibilityValue(size.map { record.title + "，" + $0 } ?? record.title)', row)
        for token in ['.contentShape(Rectangle())', '.contextMenu', 'store.cancel(record)', 'store.retry(record, api: api)']:
            self.assertIn(token, row)

    def test_context_actions_copy_before_upload_and_confirm_delete(self):
        view = source('DownloadCenterView.swift')
        for token in ['ShareInboxStore.live().importFile', 'ShareSheet(url:', 'QLPreviewController', 'confirmationDialog', 'store.delete(record)', '.githubAccountChanged', 'action?.cancel()']:
            self.assertIn(token, view)
        self.assertNotIn('DebEditor', view)
        self.assertNotIn('ShareInboxStore.live().remove', view)
        self.assertIn('downloadForCenter', source('GitHub.swift'))
        self.assertIn('policy: redirect', source('GitHub.swift'))

    def test_completed_actions_have_no_install_or_automatic_share_fallback(self):
        view = source('DownloadCenterView.swift')
        flow = view.split('.contextMenu {', 1)[1].split('private func perform(', 1)[0]
        for token in ['TrollStore', 'installing', 'canShareFallback']:
            self.assertNotIn(token, view)
        for token in ['Label("分享"', 'Label("加入待上传文件"', '"删除文件"']:
            self.assertIn(token, flow)
        self.assertIn('generation == AccountStore.generation', view)
        self.assertIn('!RefreshFailure.isCancellation(error)', view)
        self.assertNotIn('store.download', flow)
        self.assertNotIn('store.delete', flow)
        self.assertEqual(view.count('shared = SharedFile('), 1)

    def test_targeted_ui_uses_real_list_disk_and_pending_upload(self):
        preview = source('DownloadCenterStylePreview.swift')
        for token in ['DownloadCenterView(api: api, store: store)', 'DownloadHistory(root:',
                      'DownloadRules.save(', 'ShareInboxStore.live().items()', 'DownloadStore(root: root)']:
            self.assertIn(token, preview)
        ui = (ROOT / 'StyleUITests/DownloadCenterTests.swift').read_text(encoding='utf-8')
        for token in ['app.terminate()', 'app.launch()', '加入待上传文件', '确认删除',
                      '待上传副本存在', 'XCTAssertFalse(app.buttons["用 TrollStore 安装"].exists)', 'app.buttons["取消"].tap()']:
            self.assertIn(token, ui)
        runner = (ROOT / 'Scripts/run_style_preview.sh').read_text(encoding='utf-8')
        scope = runner.split('  download-actions) TEST_ARGUMENTS=(', 1)[1].split(') ;;', 1)[0]
        for name in ['DownloadCenterTests', 'CommitFileTests', 'NativeDisclosureTests',
                     'SettingsTests', 'WorkflowInputsTests', 'UploadEditorTests']:
            self.assertIn('RepoPocketStyleUITests/' + name, scope)
        self.assertIn('/testWorkflowBatchDeleteKeepsOtherRowsAndRetriesFailures', scope)
        recheck = runner.split('  download-actions-recheck) TEST_ARGUMENTS=(', 1)[1].split(') ;;', 1)[0]
        self.assertEqual(recheck.count('-only-testing:'), 1)
        self.assertNotIn('/DownloadCenterTests', recheck)
        self.assertNotIn('/CommitFileTests', recheck)
        self.assertNotIn('/testWorkflowBatchDeleteKeepsOtherRowsAndRetriesFailures', recheck)

    def test_delete_ui_waits_for_cancelled_dialog_and_real_record_hit_target(self):
        ui = (ROOT / 'StyleUITests/DownloadCenterTests.swift').read_text(encoding='utf-8')
        deletion = ui.split('func testDeleteKeepsTheIndependentPendingUploadCopy()', 1)[1].split('func testCompletedPackagesOnlyOfferFileActionsAndKeepOriginalOnCancel()', 1)[0]
        self.assertIn('waitForFileReady(in: app, name: "插件.deb")', deletion)
        self.assertEqual(deletion.count('action: "删除文件")'), 2)
        menu = ui.split('private func openFileMenu(', 1)[1].split('private func waitForButton(', 1)[0]
        self.assertIn('row: XCUIElement', menu)
        self.assertIn('row.press(forDuration: 1)', menu)
        self.assertNotIn('waitForFileReady(', menu)
        self.assertIn('app.buttons["取消"].tap()', deletion)
        self.assertIn('app.buttons["确认删除"].tap()', deletion)
        self.assertEqual(deletion.count('"待上传副本存在"'), 2)
        self.assertIn('XCTAssertTrue(file.exists)', deletion)
        self.assertIn('"exists == false"', deletion)
        readiness = ui.split('private func waitForFileReady(', 1)[1].split('private func launch()', 1)[0]
        for token in ['download-record-', 'label BEGINSWITH', 'isEnabled', 'isHittable', 'stableSamples', 'previous', '!app.buttons["取消"].exists', '!app.buttons["确认删除"].exists', 'appFrame.contains(frame)']:
            self.assertIn(token, readiness)
        self.assertNotIn('sleep(', ui)
        self.assertNotIn('coordinate(', deletion)
        self.assertNotIn('coordinate(', readiness)
        self.assertNotIn('file.press(forDuration:', deletion)

    def test_completed_preview_plain_button_hits_its_expanded_label(self):
        view = source('DownloadCenterView.swift')
        button = view.split('guard record.state == .completed else { return }', 1)[1].split('if record.state == .connecting', 1)[0]
        label = button.split('} label: {', 1)[1].split('}.buttonStyle(.plain)', 1)[0]
        # AX exposes the full row; short labels leave its center transparent without a content shape.
        self.assertIn('.frame(maxWidth: .infinity, alignment: .leading)\n                        .contentShape(Rectangle())', label)
        self.assertIn('try store.file(record)', button)
        self.assertIn('.disabled(record.state != .completed || busyID != nil)', button)

    def test_quicklook_has_one_native_navigation_host_and_state_owned_close(self):
        view = source('DownloadCenterView.swift')
        preview = view.split('private struct DownloadFilePreview:', 1)[1]
        self.assertIn('DownloadFilePreview(url: $0.url, onClose: { preview = nil })', view)
        for token in ['-> UINavigationController', 'UINavigationController(rootViewController: controller)',
                      'barButtonSystemItem: .done', 'controller.navigationItem.leftBarButtonItem = done',
                      'download-preview-done', '@objc func close()', 'onClose()',
                      'QLPreviewControllerDelegate', 'previewControllerDidDismiss',
                      'controller.delegate = context.coordinator']:
            self.assertIn(token, preview)
        self.assertEqual(preview.count('UINavigationController(rootViewController:'), 1)
        for token in ['NavigationStack', 'NavigationView', 'removeItem', 'store.delete',
                      'store.download', 'unowned', 'interactiveDismissDisabled']:
            self.assertNotIn(token, preview)
        self.assertIn('shared = nil; preview = nil; deleting = nil;', view)

    def test_preview_ui_exercises_real_close_share_cancel_and_persisted_record(self):
        ui = (ROOT / 'StyleUITests/DownloadCenterTests.swift').read_text(encoding='utf-8')
        flow = ui.split('func testCompletedPreviewClosesReopensAndShareCancelKeepsRecord()', 1)[1].split('func testDeleteKeepsTheIndependentPendingUploadCopy()', 1)[0]
        for token in ['download-preview-done', 'done.tap()', 'start.press(forDuration: 0.05, thenDragTo: end)', 'cancelShare.tap()',
                      'app.terminate()', '-download-keep-history', 'persisted.tap()',
                      'XCTAssertEqual(persisted.identifier, identifier)', 'XCTAssertEqual(persisted.label, label)',
                      'XCTAssertEqual(records.count, count)', 'app.navigationBars["下载中心"]',
                      'download-preview-native-done', 'download-preview-returned-to-center',
                      'download-preview-share-cancel', 'download-preview-records-retained']:
            self.assertIn(token, flow)
        self.assertGreaterEqual(flow.count('done.tap()'), 4)
        self.assertIn('!app.buttons["download-preview-done"].exists', ui)

    def test_interactive_preview_dismissal_cannot_use_done_as_a_fallback(self):
        ui = (ROOT / 'StyleUITests/DownloadCenterTests.swift').read_text(encoding='utf-8')
        flow = ui.split('func testCompletedPreviewClosesReopensAndShareCancelKeepsRecord()', 1)[1].split('func testDeleteKeepsTheIndependentPendingUploadCopy()', 1)[0]
        self.assertIn('// Interactive dismissal must succeed without tapping Done.', flow)
        gesture = flow.split('// Interactive dismissal must succeed without tapping Done.', 1)[1].split('XCTAssertFalse(done.exists)', 1)[0]
        self.assertEqual(gesture.count('thenDragTo:'), 1)
        self.assertIn('CGVector(dx: 0.25, dy: 0.5)', gesture)
        self.assertIn('CGVector(dx: 0.25, dy: 0.85)', gesture)
        self.assertNotIn('for _ in', gesture)
        self.assertIn('NSPredicate(format: "exists == false")', gesture)
        self.assertIn('waitForFileReady(in: app, name: "插件.deb", context: "dismiss")', gesture)
        self.assertNotIn('done.tap()', gesture)
        self.assertNotIn('waitForExistence(timeout: 1)', gesture)
        self.assertNotIn('swipeDown()', gesture)

    def test_completed_file_ax_queries_use_buttons_and_preserve_semantics(self):
        ui = (ROOT / 'StyleUITests/DownloadCenterTests.swift').read_text(encoding='utf-8')
        for name in ['插件.deb', '应用.tipa']:
            self.assertNotIn('app.staticTexts["' + name + '"]', ui)
        for token in ['XCTAssertEqual(completed.label, name',
                      'XCTAssertEqual(completed.value as? String, "已完成，13 字节"',
                      'XCTAssertEqual(persisted.value as? String, "已完成，13 字节"',
                      'XCTAssertLessThanOrEqual(cell.frame.height, 56',
                      'XCTAssertGreaterThanOrEqual(completed.frame.height, 44',
                      'XCTAssertFalse(app.buttons["插件.deb"].exists)',
                      'XCTAttachment(string: app.debugDescription)']:
            self.assertIn(token, ui)

    def test_ui_locale_and_visible_size_do_not_use_runner_defaults(self):
        ui = (ROOT / 'StyleUITests/DownloadCenterTests.swift').read_text(encoding='utf-8')
        launch = ui.split('private func launch()', 1)[1]
        for token in ['"-AppleLanguages", "(zh-Hans)"', '"-AppleLocale", "zh_CN"']:
            self.assertIn(token, launch)
        self.assertNotIn('ByteCountFormatter', ui)
        for token in ['completed.staticTexts["13 字节"]', 'completed.staticTexts[name]',
                      'XCTAssertTrue(size.exists)', 'completed.frame.contains(size.frame)',
                      'assertVisibleCompletedFileText(app, filename: filename, size: size, row: completed)']:
            self.assertIn(token, ui)
        # The fixture must still save real bytes and derive metadata from that file.
        preview = source('DownloadCenterStylePreview.swift')
        self.assertIn('Data("local fixture".utf8)', preview)
        self.assertEqual(len('local fixture'.encode('utf-8')), 13)
        model = source('DownloadCenterModels.swift')
        self.assertIn('records[index].state == .completed ? fileSize(records[index]) : nil', model)
        self.assertIn('attributes[.size] as? NSNumber', model)

    def test_completed_text_ink_rejects_missing_and_overlapping_paint(self):
        width, height, size_left, size_right = 120, 24, 90, 118
        for dark in (False, True):
            with self.subTest(dark=dark):
                background, primary, secondary = ((28, 255, 150) if dark else (255, 0, 142))
                def fixture(name_start=3, name_end=35, show_name=True, show_size=True):
                    pixels = [(background,) * 3] * (width * height)
                    for y in range(6, 18):
                        for x in range(width):
                            if show_size and 92 <= x < 116:
                                pixels[y * width + x] = (secondary,) * 3
                            if show_name and name_start <= x < name_end:
                                pixels[y * width + x] = (primary,) * 3
                    return pixels
                def check(pixels):
                    return completed_text_ink(pixels, width, size_left, size_right)['passed']
                self.assertTrue(check(fixture()))
                self.assertFalse(check(fixture(show_name=False, show_size=False)))
                self.assertFalse(check(fixture(show_size=False)))
                self.assertFalse(check(fixture(show_name=False)))
                # Entire ROI must be scanned: dark filename over the size is NOT cropped away.
                self.assertFalse(check(fixture(name_start=85, name_end=108)))
                self.assertFalse(check(fixture(name_end=94)))
                self.assertFalse(check(fixture(name_end=92)))  # Long text with no painted gap.
                self.assertFalse(check(fixture(name_end=91)))  # Only one pixel of gap.
                tiny_size = fixture(show_size=False)
                tiny_size[10 * width + 100] = (secondary,) * 3
                self.assertFalse(check(tiny_size))

    def test_completed_text_swift_scan_keeps_full_roi_and_failure_evidence(self):
        ui = (ROOT / 'StyleUITests/DownloadCenterTests.swift').read_text(encoding='utf-8')
        scan = ui.split('private func assertVisibleCompletedFileText(', 1)[1].split('private func openFileMenu(', 1)[0]
        for token in ['sizeFrame.maxX - nameFrame.minX', 'rowFrame.contains(strip)',
                      'CGFloat(image.width) / appFrame.width', 'CGFloat(image.height) / appFrame.height',
                      'rgb.max()! - rgb.min()! <= 20', 'contrast >= 55', 'contrast >= 180',
                      'if CGFloat(x) < sizeLeft', 'contrast < 180',
                      'secondaryLeft - max(primaryRight, leadingRight) - 1',
                      'CGFloat(primary) >= 8 * sx * sy', 'CGFloat(secondary) >= 8 * sx * sy',
                      'sizeCoverage >= 0.6, gap >= 2', 'XCTAttachment(screenshot: shot)',
                      'XCTAttachment(image: UIImage(cgImage: crop))', 'frames-and-ink',
                      'attachment.lifetime = .keepAlways']:
            self.assertIn(token, scan)
        self.assertNotIn('filename.frame.maxX', ui)
        self.assertNotIn('nameFrame.maxX', scan)

    def test_readiness_separates_transition_from_three_exact_frame_samples(self):
        ui = (ROOT / 'StyleUITests/DownloadCenterTests.swift').read_text(encoding='utf-8')
        readiness = ui.split('private func waitForFileReady(', 1)[1].split('override func tearDownWithError()', 1)[0]
        geometry = readiness.split('let geometry = XCTNSPredicateExpectation', 1)[1]
        sampling = geometry.split('guard stableSamples >= 3', 1)[0]
        for token in ['let transition = XCTNSPredicateExpectation', 'rowIsUnobstructed()',
                      'timeout: 10', 'frame == previous ? stableSamples + 1 : 1',
                      '!frame.isEmpty', 'appFrame.contains(frame)', 'stableSamples = 0',
                      'guard stableSamples >= 3', 'guard rowIsUnobstructed() else',
                      'verifiedFrame == frame', 'verifiedAppFrame.contains(verifiedFrame)']:
            self.assertIn(token, readiness)
        for token in ['.exists', '.isEnabled', '.isHittable', 'rowIsUnobstructed()']:
            self.assertNotIn(token, sampling, 'Frame-only rounds must not repeat serial AX guards')
        self.assertEqual(readiness.count('XCTWaiter.wait('), 2)
        for token in ['!app.buttons["download-preview-done"].exists', '!app.buttons["取消"].exists',
                      '!app.buttons["确认删除"].exists', '!app.sheets.firstMatch.exists',
                      '!app.alerts.firstMatch.exists', 'row.exists', 'row.isEnabled', 'row.isHittable']:
            self.assertIn(token, readiness)
        self.assertNotIn('sleep(', ui)

    def test_readiness_failure_trace_is_lightweight_and_names_entry_or_dismiss(self):
        ui = (ROOT / 'StyleUITests/DownloadCenterTests.swift').read_text(encoding='utf-8')
        readiness = ui.split('private func waitForFileReady(', 1)[1].split('override func tearDownWithError()', 1)[0]
        for token in ['context: String', '"enter"', '"dismiss"', 'record("transition"',
                      'record("geometry"', 'record("verify"', 'phase=', 'frame=', 'appFrame=',
                      'stableSamples=', 'elapsed=', 'blocker=', 'XCTAttachment(string: diagnostics)',
                      'download-readiness-timing-and-ax', 'XCTAssertEqual(result, .completed, diagnostics)']:
            self.assertIn(token, ui)
        self.assertNotIn('debugDescription', readiness, 'Only tearDown should read the full failure AX tree')
        self.assertIn('screenshot(app, "download-failure-" + name)', ui)
        self.assertIn('XCTAttachment(string: app.debugDescription)', ui)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production Swift download history executes on macOS')
    def test_history_and_controller(self):
        harness = (ROOT / 'Tests/Fixtures/DownloadCenterHarness.swift').read_text()
        for marker, filename in [('RULES', 'DownloadRules.swift'), ('MODEL', 'DownloadCenterModels.swift'), ('STORE', 'DownloadStore.swift')]:
            harness = harness.replace('// PRODUCTION_' + marker, source(filename).replace('import SwiftUI', 'import Foundation'))
        with tempfile.TemporaryDirectory(dir=os.environ.get('REPOPOCKET_TEST_WORK_DIR')) as folder:
            swift = Path(folder) / 'main.swift'
            swift.write_text(harness, encoding='utf-8')
            subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(Path(folder) / 'test')], check=True)
            subprocess.run([str(Path(folder) / 'test')], check=True, timeout=40)

if __name__ == '__main__': unittest.main()
