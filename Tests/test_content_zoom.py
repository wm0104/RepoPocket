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
        self.assertIn('if scrolling, web.pageZoom != CGFloat(scale) { web.pageZoom = CGFloat(scale) }', update)
        self.assertLess(update.index('web.pageZoom = CGFloat(scale)'), update.index('guard context.coordinator.identity'))
        identity = update.split('let identity =', 1)[1].split('guard context.coordinator.identity', 1)[0]
        self.assertNotIn('scale', identity)

    def test_markdown_keeps_theme_and_uses_a_separate_reader_for_long_comments(self):
        source = self.source('ReadingViews.swift')
        community = source.split('struct CommunityMarkdown:', 1)[1].split('struct RepositoryReadmeView:', 1)[0]
        self.assertIn('.markdownTheme(.gitHub)', community)
        self.assertIn('.markdownTextStyle(\\.text) { FontSize(16 * scale) }', community)
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
