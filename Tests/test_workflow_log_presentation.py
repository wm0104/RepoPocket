"""Actions log presentation: exact originals, explicit markers, production UTF-16 search."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WorkflowLogPresentationTests(unittest.TestCase):
    def test_long_log_ui_matches_localized_line_numbers_without_dropping_navigation_checks(self):
        ui = (ROOT / 'StyleUITests/WorkflowLogTests.swift').read_text(encoding='utf-8')
        self.assertEqual(ui.count('position.label.contains(30001.formatted(.number))'), 2)
        self.assertEqual(ui.count('position.label.contains(30010.formatted(.number))'), 1)
        self.assertNotIn('position.label.contains("30001")', ui)
        for token in ['position.label.contains("1/2")', 'report["selectedVisible"], "1"',
                      'XCTAssertGreaterThan(Int(report["verticalOffset"]',
                      'XCTAssertLessThanOrEqual(abs(after - before), 3', 'workflow-log-toggle-raw',
                      'screenshot(app, "workflow-log-long-located")']:
            self.assertIn(token, ui)

    def test_native_regressions_check_tail_error_visibility_and_refresh_position(self):
        ui = (ROOT / 'StyleUITests/WorkflowLogTests.swift').read_text(encoding='utf-8')
        probe = (ROOT / 'RepoPocket/SourceStylePreview.swift').read_text(encoding='utf-8')
        zip_test = (ROOT / 'Tests/test_workspace_zip.py').read_text(encoding='utf-8')
        for token in ['assertLongErrorNavigation(app)', '30001', '30010', 'selectedVisible',
                      'workflow-error-next', 'workflow-error-previous', 'abs(after - before)']:
            self.assertIn(token, ui)
        for token in ['count: 30000', 'viewport.intersects', 'text.caretRect', 'text.contentOffset.y']:
            self.assertIn(token, probe)
        for token in ['16*1024*1024+1', "count == 40002", 'readJob(', 'job-invalid.log', 'job-oversized.log']:
            self.assertIn(token, zip_test)

    def test_job_log_is_bounded_but_no_longer_silently_a_prefix(self):
        github = (ROOT / 'RepoPocket/GitHub.swift').read_text(encoding='utf-8')
        method = github.split('func communityJobLog(', 1)[1].split('\n    }', 1)[0]
        self.assertNotIn('256 * 1024', method)
        self.assertNotIn('String(decoding:', method)
        self.assertIn('WorkflowLogArchiveDownloadPolicy()', method)
        self.assertIn('WorkflowLogArchiveRules.readJob', method)
        self.assertIn('ensureActiveAccount()', method)

    def test_error_navigation_is_explicit_and_initial_only(self):
        reader = (ROOT / 'RepoPocket/WorkflowLogView.swift').read_text(encoding='utf-8')
        for token in ['var failed = false', 'didAutoLocate', 'SourceTextReveal',
                      'workflow-error-previous', 'workflow-error-next', 'workflow-error-position',
                      'errorLocations', '未定位到更具体的报错']:
            self.assertIn(token, reader)
        self.assertNotIn('presentation.rawText == rawText {', reader)
        surface = (ROOT / 'RepoPocket/SourceTextSurface.swift').read_text(encoding='utf-8')
        for token in ['lastRevealID', 'pendingReveal', 'pendingReadingOffset',
                      'scrollRangeToVisible', 'NSMaxRange(request.range)']:
            self.assertIn(token, surface)
        shipping = (ROOT / 'RepoPocket/WorkflowViews.swift').read_text(encoding='utf-8')
        inline = shipping.split('struct WorkflowInlineLog:', 1)[1].split('struct WorkflowLogView:', 1)[0]
        self.assertLess(inline.index('else if let output'), inline.index('else if loading'))
        full_screen = shipping.split('if expandedSteps.contains(step.number), step.conclusion != \"skipped\",', 1)[1].split('SoftGroupRow(\"full-log-', 1)[0]
        self.assertNotIn('!logs.loading', full_screen)
        self.assertNotIn('logs.error.isEmpty', full_screen)

    def test_inline_log_controls_do_not_share_the_automatic_list_row_action(self):
        reader = (ROOT / 'RepoPocket/WorkflowLogView.swift').read_text(encoding='utf-8').split('SourceCodeView(', 1)[0]
        self.assertIn('.buttonStyle(.borderless)', reader)
        self.assertGreaterEqual(reader.count('minHeight: 44'), 3)
    def test_archive_keeps_original_text_and_existing_safety_budgets(self):
        archive = (ROOT / 'RepoPocket/WorkflowLogArchive.swift').read_text(encoding='utf-8')
        self.assertIn('WorkflowStepOutput(text: text, limited: false)', archive)
        self.assertNotIn('text.replacingOccurrences', archive)
        for value in ['32 * 1024 * 1024', '16 * 1024 * 1024', 'count <= 5000',
                      'Task.checkCancellation()', 'String(data: bytes, encoding: .utf8)']:
            self.assertIn(value, archive)

    def test_reader_defaults_to_complete_read_only_context_and_copies_original(self):
        reader = (ROOT / 'RepoPocket/WorkflowLogView.swift').read_text(encoding='utf-8')
        self.assertIn('@State private var showingRaw = false', reader)
        self.assertIn('UIPasteboard.general.string = presentation.rawText', reader)
        self.assertIn('showingRaw ? presentation.rawText : presentation.displayText', reader)
        self.assertIn('showingRaw ? [] : presentation.lines', reader)
        for forbidden in ['TextEditor(', 'becomeFirstResponder', '.filter(', 'errorsOnly']:
            self.assertNotIn(forbidden, reader)
        shipping = (ROOT / 'RepoPocket/WorkflowViews.swift').read_text(encoding='utf-8')
        self.assertEqual(shipping.count('WorkflowLogReader(rawText:'), 3)

    def test_severity_is_an_opt_in_layout_decoration_not_persistent_text_attributes(self):
        for name in ['SourceCodeView.swift', 'SourceTextSurface.swift']:
            text = (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')
            self.assertIn('var logLines: [WorkflowLogPresentation.Line] = []', text)
        layout = (ROOT / 'RepoPocket/SourceFindBar.swift').read_text(encoding='utf-8').split('final class SourceSearchLayoutManager:', 1)[1]
        self.assertIn('var logLines: [WorkflowLogPresentation.Line]', layout)
        self.assertIn('UIColor.systemRed', layout)
        self.assertIn('UIColor.systemOrange', layout)
        self.assertIn('invalidateDisplay(forCharacterRange:', layout)
        self.assertNotIn('addAttributes(', layout)
        self.assertNotIn('setAttributes(', layout)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production Foundation log/search fixture requires macOS Swift')
    def test_native_explicit_markers_original_bytes_context_and_utf16_ranges(self):
        harness = r'''
import Foundation
@main struct LogRegression {
    static func main() throws {
        let raw = "before 😀 中文\r\n"
            + "2026-11-12T01:02:03.1234567Z \u{1B}[31m##[error]中文失败 😀\u{1B}[0m\r\n"
            + "2026-11-12T01:02:04Z ##[warning]中文警告\n"
            + "::error file=Sources/代码.swift,line=4::明确失败\n"
            + "2026-11-12T01:02:05Z ::warning title=磁盘::空间不足\n"
            + "ERROR: 明确的行首错误\n"
            + "let error = \"normal source\"\n"
            + "echo '##[error]not a command'\n\n##[group]keep group\n##[endgroup]\nafter\n"
        let value = try WorkflowLogPresentation(rawText: raw)
        precondition(value.rawText == raw && Array(value.rawText.utf8) == Array(raw.utf8))
        let clean = raw.replacingOccurrences(of: "\u{1B}[31m", with: "").replacingOccurrences(of: "\u{1B}[0m", with: "")
        precondition(value.displayText == clean)
        precondition(value.errorCount == 3 && value.warningCount == 2 && value.lines.count == 5)
        precondition(value.lines[0].number == 2)
        precondition((raw as NSString).substring(with: value.lines[0].rawRange).contains("\u{1B}[31m"))
        precondition(value.displayText.hasPrefix("before 😀 中文\r\n") && value.displayText.hasSuffix("after\n"))
        precondition(value.displayText.contains("\n\n##[group]keep group\n##[endgroup]\n"))
        let source = value.displayText as NSString
        for line in value.lines {
            precondition(line.range.location >= 0 && NSMaxRange(line.range) <= source.length)
            let text = source.substring(with: line.range)
            precondition(!text.contains("\n") && !text.contains("\r"))
            precondition(text.contains("##[") || text.contains("::") || text.hasPrefix("ERROR:"))
        }
        for text in [value.rawText, value.displayText] {
            let expected = (text as NSString).range(of: "中文失败 😀")
            let result = SourceTextSearch.find(text, term: "中文失败 😀", matchCase: true,
                                               selection: NSRange(location: 0, length: 0), forwards: true)!
            precondition(result.range == expected && result.count == 1)
            precondition((text as NSString).substring(with: result.range) == "中文失败 😀")
        }
        for invalid in ["", "\n\r\n", "error: lowercase is not the declared ERROR: marker",
                        "source error word", "x ERROR: not leading", "##[errors]bad", "##[warning ]bad",
                        "::errorx::bad", "::warning missing delimiter", "prefix ##[error]bad",
                        "not-a-time ##[error]bad", "print(\"ERROR: example\")"] {
            let value = try WorkflowLogPresentation(rawText: invalid)
            precondition(value.rawText == invalid && value.displayText == invalid && value.lines.isEmpty, invalid)
        }
        let final = try WorkflowLogPresentation(rawText: "  ERROR: no trailing newline 😀")
        precondition(final.errorCount == 1 && final.lines[0].range.length == final.displayText.utf16.count)
        let large = String(repeating: "ordinary context 😀\n", count: 40_000) + "##[error]last error\n"
        let full = try WorkflowLogPresentation(rawText: large)
        precondition(full.rawText == large && full.displayText == large && full.errorCount == 1)
        precondition(full.lines[0].range.location == (large as NSString).range(of: "##[error]").location)
        precondition(full.errorLocations.first?.number == 40_001)
        let ordered = try WorkflowLogPresentation(rawText: "##[error]Process completed with exit code 1.\n"
            + "ordinary context 😀\n2026-11-12T01:02:04Z ERROR: 具体错误\n"
            + "/Users/runner/Sources/代码.swift:12:4: error: compile failed\n")
        precondition(ordered.errorCount == 3 && ordered.errorLocations.count == 2)
        precondition(ordered.errorLocations.map(\.number) == [3, 4])
        precondition(!ordered.onlyExitSummary)
        let summary = try WorkflowLogPresentation(rawText: "##[error]Process completed with exit code 1.")
        precondition(summary.onlyExitSummary && summary.errorLocations.count == 1)
        let crlf = try WorkflowLogPresentation(rawText: "a\r\n\u{1B}[31mERROR: 中文😀\u{1B}[0m\r\nb\r\n")
        precondition(crlf.errorLocations[0].number == 2)
        precondition((crlf.rawText as NSString).substring(with: crlf.errorLocations[0].rawRange).contains("\u{1B}[31m"))
        print("PASS production Actions log explicit error/warning markers, invalid lookalikes, exact originals/full context/CRLF, ANSI display only and UTF16 search")
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory) / 'LogRegression.swift'
            main.write_text(harness, encoding='utf-8')
            executable = Path(directory) / 'log-regression'
            subprocess.run(['swiftc', '-parse-as-library', str(ROOT / 'RepoPocket/WorkflowLogPresentation.swift'),
                            str(ROOT / 'RepoPocket/SourceTextSearch.swift'), str(main), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=60)


if __name__ == '__main__':
    unittest.main()
