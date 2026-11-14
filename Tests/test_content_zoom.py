"""Shared content-only zoom contracts and executable production scale rules."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ContentZoomIntegrationTests(unittest.TestCase):
    def source(self, name):
        return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')

    def test_shared_controls_are_explicit_and_do_not_transform_the_page(self):
        source = self.source('ContentZoom.swift')
        for marker in ['struct ContentZoomControls', '@Binding var scale: Double',
                       'content-zoom-out', 'content-zoom-reset', 'content-zoom-in',
                       'scale = 1', '.buttonStyle(.borderless)']:
            self.assertIn(marker, source)
        self.assertNotIn('scaleEffect', source)
        self.assertNotIn('@AppStorage', source)

    def test_shared_source_surface_updates_font_without_replacing_text(self):
        editor = self.source('SourceCodeView.swift')
        surface = self.source('SourceTextSurface.swift')
        self.assertIn('ContentZoomControls(scale: $scale)', editor)
        self.assertIn('scale: scale', editor)
        self.assertIn('UIFontMetrics(forTextStyle: .subheadline)', surface)
        self.assertIn('traitCollectionDidChange', surface)
        self.assertIn('refreshFont()', surface)
        font_update = surface.split('private func refreshFont()', 1)[1].split('func textViewDidChange', 1)[0]
        self.assertNotIn('textView.text =', font_update)
        self.assertIn('textView.selectedRange = selection', font_update)
        self.assertIn('textView.invalidateSourceGeometry()', font_update)
        self.assertIn('gutterFont', surface)

    def test_patch_and_diff_measure_the_font_they_render(self):
        for name in ['CommitPatchView.swift', 'LocalDiffPreview.swift']:
            source = self.source(name)
            self.assertIn('ContentZoomControls(scale: $scale)', source)
            self.assertIn('CodeMetrics.monospacedWidth(value, font: font)', source)
            self.assertIn('.font(Font(codeFont))', source)
            self.assertIn('dynamicTypeSize', source)
            self.assertNotIn('scaleEffect', source)
        metrics = self.source('CodeMetrics.swift')
        self.assertIn('font: UIFont', metrics)
        self.assertIn('UIFontMetrics(forTextStyle: .caption1)', metrics)

    def test_highlighted_patch_keeps_text_and_colors_but_inherits_the_scaled_font(self):
        conversion = self.source('CommitPatchView.swift').split('colored = colors.mapValues { value in', 1)[1].split('return AttributedString(text)', 1)[0]
        self.assertIn('NSMutableAttributedString(attributedString: value)', conversion)
        self.assertIn('text.removeAttribute(.font, range:', conversion)
        self.assertNotIn('.foregroundColor', conversion)
        self.assertNotIn('NSAttributedString(string:', conversion)

    def test_reading_font_keeps_github_attributes_and_the_fixed_css_baseline(self):
        source = self.source('ReadingViews.swift')
        community = source.split('struct CommunityMarkdown:', 1)[1].split('struct RepositoryReadmeView:', 1)[0]
        self.assertNotIn('.markdownTextStyle(\\.text) { FontSize', community)
        style = source.split('private struct ReadingMarkdownTextStyle: TextStyle {', 1)[1].split('struct CommunityMarkdown:', 1)[0]
        self.assertIn('let base: any TextStyle', style)
        self.assertLess(style.index('base._collectAttributes(in: &attributes)'), style.index('FontSize(16 * scale)._collectAttributes(in: &attributes)'))
        document = self.source('ReadmeDocument.swift')
        self.assertIn('font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 16px; line-height: 1.5;', document)
        self.assertIn('-webkit-text-size-adjust: 100%', document)
        self.assertNotIn('font: -apple-system-body', document)

    def test_old_conflict_body_uses_one_shared_zoom_without_scaling_actions(self):
        source = self.source('WorkspaceView.swift').split('private var conflictSheet:', 1)[1].split('@MainActor private func importItems', 1)[0]
        self.assertIn('ContentZoomControls(scale: $conflictScale)', source)
        self.assertEqual(source.count('.font(Font(CodeMetrics.font(scale: conflictScale)))'), 3)
        self.assertNotIn('scaleEffect', source)

    def test_eof_note_explains_git_patch_without_reinterpreting_it(self):
        source = self.source('CommitPatchView.swift')
        self.assertIn('file.patch?.contains("\\\\ No newline at end of file") == true', source)
        self.assertIn('行尾换行变化也可能显示删/增', source)

    def test_diff_budget_falls_back_to_original_text_without_counts(self):
        source = self.source('LocalDiffPreview.swift')
        self.assertIn('catch LocalDiffModel.Failure.budgetExceeded', source)
        self.assertIn('result = nil; fullText = true', source)
        self.assertIn('变化范围超过计算预算，无法精确计算差异，已显示原文对照。', source)
        self.assertNotIn('大段变化按删除/新增展示', source)

    def test_diff_line_numbers_keep_the_existing_caption2_style(self):
        source = self.source('LocalDiffPreview.swift')
        self.assertIn('UIFontMetrics(forTextStyle: .caption2)', source)
        self.assertIn('.font(Font(numberFont))', source)

    def test_web_zoom_updates_without_reloading_or_changing_inline_height(self):
        source = self.source('ReadmeHTMLView.swift')
        update = source.split('func updateUIView(', 1)[1].split('static func dismantleUIView', 1)[0]
        self.assertIn('context.coordinator.applyScale(scale, to: web)', update)
        self.assertLess(update.index('context.coordinator.applyScale(scale, to: web)'), update.index('guard context.coordinator.identity'))
        self.assertIn('article.style.zoom', source)
        self.assertIn("article.style.webkitTextSizeAdjust = 'auto'", source)
        self.assertIn('web.evaluateJavaScript(', source)
        self.assertIn('self.identity == document, self.appliedScale == scale', source)
        self.assertNotIn('setZoomScale(', source)
        self.assertNotIn('web.pageZoom =', source)
        identity = update.split('let identity =', 1)[1].split('guard context.coordinator.identity', 1)[0]
        self.assertNotIn('scale', identity)
        probe = self.source('ReadingZoomStylePreview.swift')
        self.assertIn('zoom: getComputedStyle(article).zoom', probe)
        self.assertNotIn('zoom=\\(web.scrollView.zoomScale)', probe)
        self.assertIn('pageZoom=\\(web.pageZoom)', probe)

    def test_markdown_keeps_theme_and_uses_a_separate_reader_for_long_comments(self):
        source = self.source('ReadingViews.swift')
        community = source.split('struct CommunityMarkdown:', 1)[1].split('struct RepositoryReadmeView:', 1)[0]
        self.assertIn('var theme = Theme.gitHub', community)
        self.assertIn('theme.text = ReadingMarkdownTextStyle(base: theme.text, scale: scale)', community)
        self.assertNotIn('TextStyleBuilder.buildPartialBlock', community)
        self.assertIn('.markdownTheme(readingTheme)', community)
        self.assertIn('Button("放大阅读")', community)
        self.assertIn('if !reader, offersReading', community)
        self.assertIn('reader: true', community)
        self.assertIn('ContentZoomControls(scale: $scale)', community)
        self.assertNotIn('scaleEffect', community)

    def test_native_zoom_regressions_measure_unique_stable_content(self):
        reading = (ROOT / 'StyleUITests/ReadingZoomTests.swift').read_text(encoding='utf-8')
        controls = (ROOT / 'StyleUITests/ContentZoomTests.swift').read_text(encoding='utf-8')
        self.assertIn('controls.height, 44 - 0.000001', controls)
        self.assertIn('app.scrollViews["community-markdown-reader"]', reading)
        self.assertIn('reader.staticTexts', reading)
        self.assertNotIn('number(baseline, "height") * 1.5', reading)
        self.assertIn('stableFrame(sentinel)', reading)
        self.assertIn('baseline.width * 2', reading)
        self.assertIn('resetFrame.width, baseline.width', reading)

    def test_pinch_reuses_the_content_scale_and_handles_gesture_end_and_cancel(self):
        source = self.source('ContentZoom.swift')
        self.assertIn('MagnificationGesture()', source)
        self.assertNotIn('MagnifyGesture()', source)
        self.assertIn('.simultaneousGesture(', source)
        self.assertIn('including: enabled ? .all : .subviews', source)
        self.assertIn('@GestureState private var pinching', source)
        self.assertIn('if !active { initialScale = nil }', source)
        self.assertIn('UIPinchGestureRecognizer(target:', source)
        self.assertIn('pinch.cancelsTouchesInView = false', source)
        self.assertIn('[.ended, .cancelled, .failed]', source)
        self.assertIn('ContentZoomRules.clamped(', source)

    def test_native_pinch_prioritizes_content_zoom_without_text_selection_pan(self):
        source = self.source('ContentZoom.swift')
        simultaneous = source.split('shouldRecognizeSimultaneouslyWith otherGestureRecognizer:', 1)[1]
        self.assertIn('(otherGestureRecognizer.view as? UIScrollView)?.panGestureRecognizer === otherGestureRecognizer', simultaneous)
        self.assertNotIn('return otherGestureRecognizer is UIPanGestureRecognizer', simultaneous)
        priority = source.split('shouldBeRequiredToFailBy otherGestureRecognizer:', 1)[1].split('\n    }', 1)[0]
        self.assertIn('otherGestureRecognizer is UIPinchGestureRecognizer', priority)

    def test_editor_captures_selection_before_pinch_touches_can_move_the_caret(self):
        source = self.source('ContentZoom.swift')
        self.assertIn('shouldReceive touch: UITouch', source)
        self.assertIn('if gestureRecognizer.numberOfTouches == 0 { prepare() }', source)
        surface = self.source('SourceTextSurface.swift')
        self.assertIn('self?.selectionBeforePinch = self?.textView.selectedRange', surface)
        pinch = surface.split('pinch = ContentPinchGesture(view: horizontal', 1)[1].split('refreshFont()\n', 1)[0]
        self.assertLess(pinch.index('textView.selectedRange = selection'), pinch.index('self.refreshFont()'))

    def test_every_zoom_surface_accepts_pinch_without_a_second_web_scale(self):
        surface = self.source('SourceTextSurface.swift')
        self.assertIn('ContentPinchGesture(view: horizontal', surface)
        self.assertIn('self.refreshFont(); self.scaleChanged?(value)', surface)
        self.assertIn('view.scaleChanged = onScaleChange', surface)
        web = self.source('ReadmeHTMLView.swift')
        self.assertIn('ContentPinchGesture(view: web', web)
        self.assertIn('web.scrollView.pinchGestureRecognizer?.isEnabled = false', web)
        self.assertIn('if parent.scrolling { webView.scrollView.pinchGestureRecognizer?.isEnabled = false }', web)
        self.assertIn('coordinator?.parent.onScaleChange(value)', web)
        self.assertNotIn('UIScrollViewDelegate', web)
        reading = self.source('ReadingViews.swift')
        self.assertIn('.contentPinchZoom(scale: $scale, enabled: reader)', reading)
        self.assertEqual(reading.count('onScaleChange: { scale = $0 }'), 2)
        self.assertIn('onScaleChange: { scale = $0 }', self.source('ReadingZoomStylePreview.swift'))
        self.assertIn('.contentPinchZoom(scale: $scale)', self.source('CommitPatchView.swift'))
        self.assertEqual(self.source('LocalDiffPreview.swift').count('.contentPinchZoom(scale: $scale)'), 2)
        self.assertEqual(self.source('WorkspaceView.swift').count('.contentPinchZoom(scale: $conflictScale)'), 3)

    def test_continuous_pinch_does_not_restart_diff_parsing_or_initial_position(self):
        patch = self.source('CommitPatchView.swift')
        render_key = patch.split('private var renderKey:', 1)[1].split('var body:', 1)[0]
        self.assertNotIn('String(scale)', render_key)
        self.assertIn('(codeWidth - 30) * CGFloat(scale) + 30', patch)
        local = self.source('LocalDiffPreview.swift')
        task_key = local.split('.task(id:', 1)[1].split(') {', 1)[0]
        self.assertNotIn('String(scale)', task_key)
        self.assertIn('(codeWidth - 28) * CGFloat(scale) + 28', local)
        for source in [patch, local]:
            self.assertIn('font = CodeMetrics.font(scale: 1)', source)

    def test_native_zoom_tests_perform_real_pinches_and_preserve_content(self):
        controls = (ROOT / 'StyleUITests/ContentZoomTests.swift').read_text(encoding='utf-8')
        reading = (ROOT / 'StyleUITests/ReadingZoomTests.swift').read_text(encoding='utf-8')
        self.assertIn('code.pinch(withScale:', controls)
        self.assertIn('app.scrollViews.firstMatch.pinch(withScale:', controls)
        self.assertIn('enlarged["selection"], baseline["selection"]', controls)
        self.assertIn('number(pinched, "offset"), 0', controls)
        self.assertIn('web.pinch(withScale:', reading)
        self.assertIn('text.pinch(withScale:', reading)
        self.assertIn('pinched["loads"], "1"', reading)
        self.assertIn('readme-zoom-native-dom-ax', reading)
        self.assertIn('XCTAssertNil(enlarged["domError"])', reading)
        preview = self.source('ReadingZoomStylePreview.swift')
        self.assertTrue(preview.startswith('#if DEBUG'))
        self.assertIn('getBoundingClientRect()', preview)
        self.assertIn('completionHandler: { value, error in', preview)
        self.assertNotIn('in: nil, in: .defaultClient', preview)
        for measurement in ['domWidth: rect.width', 'domHeight: rect.height', 'fontSize:',
                            'viewportScale:', 'viewportWidth:', 'innerWidth, scrollY, selectedLength:',
                            'domError=', 'invalid-probe-result', 'zoom: getComputedStyle(article).zoom', 'offset=', 'scrollZoom=']:
            self.assertIn(measurement, preview)

    def test_exact_glyph_scale_probe_is_fixed_metric_and_still_checks_system_body_text(self):
        preview = self.source('ReadingZoomStylePreview.swift')
        self.assertIn('font-family:Courier,monospace;font-kerning:none;font-optical-sizing:none', preview)
        self.assertIn('BODY_SENTINEL', preview)
        reading = (ROOT / 'StyleUITests/ReadingZoomTests.swift').read_text(encoding='utf-8')
        self.assertIn('stableFrame(bodySentinel)', reading)
        self.assertIn('bodyBaseline.width * 1.8', reading)
        self.assertIn('bodyBaseline.width * 0.7', reading)
        self.assertIn('baseline.width * 2, accuracy: 1', reading)
        self.assertIn('baseline.width * 0.6, accuracy: 1', reading)
        self.assertIn('number(visibleEnlarged, "domHeight") * 2, accuracy: 1', reading)
        self.assertIn('reducedInk.height, baselineInk.height * 0.6, accuracy: 1', reading)
        self.assertIn('enlargedInk.height, baselineInk.height * 2, accuracy: 1', reading)
        self.assertIn('resetInk.height, baselineInk.height, accuracy: 1', reading)
        self.assertIn('CGContext(data:', reading)
        self.assertIn('No visible glyph pixels in the actual screenshot', reading)
        self.assertIn('sentinel.frame.height > baseline.height * 1.8', reading)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production Swift rules execute on macOS')
    def test_production_zoom_steps_clamp_and_reset_without_roundoff_drift(self):
        fixture = '''
import Foundation
@main struct Fixture {
 static func main() {
  var scale = 1.0
  for _ in 0..<30 { scale = ContentZoomRules.adjusted(scale, by: -1) }
  precondition(scale == 0.6)
  for _ in 0..<30 { scale = ContentZoomRules.adjusted(scale, by: 1) }
  precondition(scale == 2.0)
  scale = 1
  for _ in 0..<4 { scale = ContentZoomRules.adjusted(scale, by: -1) }
  for _ in 0..<4 { scale = ContentZoomRules.adjusted(scale, by: 1) }
  precondition(abs(scale - 1) < 0.00001)
  precondition(ContentZoomRules.adjusted(0.6, by: -1) == 0.6)
  precondition(ContentZoomRules.adjusted(2, by: 1) == 2)
  precondition(ContentZoomRules.clamped(0.1) == 0.6)
  precondition(ContentZoomRules.clamped(3) == 2)
  precondition(ContentZoomRules.clamped(1.357) == 1.357)
  print("PASS actual production zoom bounds, repeated steps and reset")
 }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory) / 'Fixture.swift'
            main.write_text(fixture, encoding='utf-8')
            output = str(Path(directory) / 'test')
            subprocess.run(['swiftc', '-parse-as-library', str(ROOT / 'RepoPocket/ContentZoom.swift'), str(main), '-o', output], check=True)
            subprocess.run([output], check=True, timeout=20)


if __name__ == '__main__':
    unittest.main()
