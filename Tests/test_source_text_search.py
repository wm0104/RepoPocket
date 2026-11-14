"""Fila-derived production search fixtures; host contracts do not pretend to execute Swift."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SourceTextSearchTests(unittest.TestCase):
    def source(self, name):
        return (ROOT / 'RepoPocket' / name).read_text()

    @unittest.skipUnless(shutil.which('swiftc'), 'Production search algorithm executes on macOS with Swift, not on this host')
    def test_production_search_algorithm(self):
        with tempfile.TemporaryDirectory() as directory:
            output = str(Path(directory) / 'source-search')
            subprocess.run(['swiftc', '-parse-as-library',
                            str(ROOT / 'RepoPocket/SourceTextSearch.swift'),
                            str(ROOT / 'Tests/fixtures/SourceTextSearchFixture.swift'),
                            '-o', output], check=True)
            subprocess.run([output], check=True, timeout=30)

    def test_pinned_package_and_real_public_string_api(self):
        project = (ROOT / 'project.yml').read_text()
        self.assertIn('path: Packages/RepoPocketSyntax', project)
        self.assertNotIn('Lakr233/Runestone.xcframework', project)
        for product in ['RepoPocketLanguageSupport', 'RepoPocketThemeSupport']:
            self.assertIn('product: ' + product, project)
        package = (ROOT / 'Packages/RepoPocketSyntax/Package.swift').read_text()
        self.assertIn('00426ba7f8681a90c1ea0b5c03a0e0bec8cba883', package)
        self.assertIn('4442182303a00bf2764b10ead923a1066a0946f6', package)
        self.assertNotIn('binaryTarget', package)
        self.assertNotIn('name: "RunestoneLanguageSupport"', package)
        names = 'Astro Bash C CSharp CPP CSS Elixir Elm Go Haskell HTML Java JavaScript JSON JSON5 Julia LaTeX Lua Markdown OCaml Perl PHP Python R Ruby Rust SCSS SQL Svelte Swift TOML TSX TypeScript YAML'.split()
        exports = (ROOT / 'Packages/RepoPocketSyntax/Sources/RepoPocketLanguageSupport/Exports.swift').read_text()
        self.assertEqual(exports.splitlines(), ['@_exported import Runestone'] +
                         ['@_exported import TreeSitter' + name + 'Runestone' for name in names])
        for name in names:
            self.assertIn('.product(name: "TreeSitter' + name + 'Runestone", package: "TreeSitterLanguages")', package)
        self.assertEqual(package.count('.process("Colors.xcassets")'), 2)
        syntax = self.source('SourceTextSyntax.swift')
        self.assertNotIn('static let choices', syntax)
        self.assertNotIn('language(named', syntax)
        highlighter = self.source('SourceCodeView.swift')
        self.assertIn('StringSyntaxHighlighter(theme: theme, language: language).syntaxHighlight(text)', highlighter)
        self.assertIn('static let byteLimit = 512 * 1024', highlighter)
        self.assertIn('text.utf8.count <= byteLimit', highlighter)
        self.assertNotIn('text.utf8.prefix', highlighter)
        self.assertIn('SourceTextSyntax.language(for: filename, text: text)', highlighter)
        # CommitPatchView still calls this shared entry point.
        self.assertIn('enum SourceHighlighter', highlighter)
        self.assertIn('SourceHighlighter.highlight', self.source('CommitPatchView.swift'))
        self.assertIn('static let byteLimit = 1024 * 1024', self.source('SourceLexer.swift'))

    def test_empty_document_bypasses_upstream_index_zero_access(self):
        highlighter = self.source('SourceCodeView.swift')
        guard = highlighter.split('static func highlight(', 1)[1].split('let theme:', 1)[0]
        self.assertIn('guard !text.isEmpty, !Task.isCancelled, text.utf8.count <= byteLimit,', guard)
        self.assertIn('return NSAttributedString(string: text, attributes: [.foregroundColor: UIColor.label])', guard)
        self.assertNotIn('syntaxHighlight(', guard)

    def test_decorations_and_refresh_are_not_text_mutations(self):
        bar = self.source('SourceFindBar.swift')
        surface = self.source('SourceTextSurface.swift')
        self.assertIn('class SourceSearchLayoutManager: NSLayoutManager', bar)
        self.assertIn('cornerRadius: 5', bar)
        self.assertIn('UIColor.systemOrange.withAlphaComponent(0.55)', bar)
        self.assertIn('UIColor.systemYellow.withAlphaComponent(0.25)', bar)
        self.assertNotIn('addAttribute(.backgroundColor', surface + bar)
        refresh = surface.split('private func refreshFind(', 1)[1].split('private func replace(', 1)[0]
        for marker in ['findTask?.cancel()', 'searchManager.result = nil', 'withTaskCancellationHandler',
                       'self.textView.text == value', 'self.findBar.term == term',
                       'self.findBar.matchesCase == matchCase', 'self.textView.markedTextRange == nil']:
            self.assertIn(marker, refresh)
        self.assertNotRegex(refresh, r'textView\.text\s*=(?!=)')
        self.assertIn('view.cancelTasks()', surface)

    def test_replace_has_locks_budget_and_one_native_edit(self):
        surface = self.source('SourceTextSurface.swift')
        replacement = surface.split('private func replace(', 1)[1].split('func textView(_', 1)[0]
        for marker in ['guard textView.isEditable', 'textView.markedTextRange == nil', '!findBar.hasMarkedText',
                       'SourceTextSearch.replacementRanges', 'SourceTextSearch.replacing',
                       'byteLimit: SourceTextRules.byteLimit', 'guard let current', 'apply(edit)']:
            self.assertIn(marker, replacement)
        self.assertNotIn('textView.text =', replacement)
        self.assertIn('textView.replace(range, withText: edit.replacement)', surface)
        self.assertIn('guard textView.isEditable else { return false }', surface)
        self.assertIn('textView.isEditable && textView.undoManager?.canUndo', surface)

    def test_case_is_an_actual_system_menu_and_count_remains_visible(self):
        bar = self.source('SourceFindBar.swift')
        for marker in ['UIAction(title: "区分大小写"', 'UIMenu(children: [action])',
                       'caseButton.showsMenuAsPrimaryAction = true', '.on : .off',
                       'field.rightViewMode = .always', 'replacement.isEnabled = allowsReplacement']:
            self.assertIn(marker, bar)
        self.assertNotIn('import SnapKit', bar)
        self.assertNotIn('import Then', bar)

    def test_fila_layout_keeps_wide_fields_and_hides_replacement_for_read_only(self):
        bar = self.source('SourceFindBar.swift')
        surface = self.source('SourceTextSurface.swift')
        self.assertIn('replacementRow.isHidden = !allowsReplacement', bar)
        self.assertIn('UIToolbarAppearance()', bar)
        self.assertIn('UIVisualEffectView(effect: appearance.backgroundEffect)', bar)
        self.assertIn('let field: UITextField = SourceFindInputField()', bar)
        self.assertIn('UILayoutPriority(249)', bar)
        self.assertIn('setContentHuggingPriority(.required, for: .horizontal)', bar)
        self.assertIn('[field, previous, next, undo, done]', bar)
        self.assertIn('onUndo', bar)
        self.assertIn('result.accessibilityValue = value', bar)
        self.assertIn('findBar.allowsUndo = textView.isEditable && textView.undoManager?.canUndo == true', surface)
        self.assertIn('findBarHeight.constant = findBar.barHeight', surface)
        editing = bar.split('field.addAction(UIAction', 1)[1].split('for: .editingChanged)', 1)[0]
        self.assertIn('onTermChange?()', editing)
        self.assertNotIn('onFind?', editing)
        self.assertIn('findBar.onTermChange = { [weak self] in self?.clearFindResult() }', surface)
        self.assertIn('activeFindTerm == findBar.term', surface)
        self.assertIn('findBar.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)', surface)
        self.assertIn('findBar.isHidden ? keyboardLayoutGuide.layoutFrame.minY : findBar.frame.minY', surface)
        self.assertNotIn('findBar.frame = CGRect(x: 0, y: 0', surface)
        clear = surface.split('private func clearFindResult()', 1)[1].split('private func closeFind()', 1)[0]
        for marker in ['findTask?.cancel()', 'activeFindTerm = nil', 'searchManager.result = nil', 'findBar.showResult(nil)']:
            self.assertIn(marker, clear)

    def test_copied_notice_bytes_match_their_retained_source_digests(self):
        root = ROOT / 'Licenses/SourceText'
        manifest = json.loads((root / 'SOURCE_MANIFEST.json').read_text())
        self.assertEqual(len(manifest['language_products']), 34)
        self.assertGreater(len(manifest['files']), 90)
        for metadata in manifest['files']:
            path = ROOT / metadata['path'] if metadata['path'].startswith('Packages/') else root / metadata['path']
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), metadata['sha256'], str(path))
        for name in manifest['language_products']:
            record = json.loads((root / 'TreeSitterLanguages/Tests/Updates' / (name + '.json')).read_text())
            self.assertEqual(len(record['revision']), 40)
            for notice in record.get('license_files', record.get('licenses', [])):
                self.assertTrue((root / 'TreeSitterLanguages' / notice).is_file(), notice)

    def test_notices_describe_active_source_not_clear_the_retired_binary(self):
        root = ROOT / 'Licenses/SourceText'
        audit = (root / 'AUDIT.md').read_text()
        for marker in ['00426ba7f8681a90c1ea0b5c03a0e0bec8cba883',
                       '4442182303a00bf2764b10ead923a1066a0946f6',
                       '10eb5ac119eec9cb4267a8e035066473983f5f3a', '0.27.1',
                       'not a retroactive resolution', 'remain unverified',
                       '933206d96a78f7785c13b2600182f1527dcd755c200b1271bb5bc4d8da4b17b3']:
            self.assertIn(marker, audit)
        self.assertIn('OwnGoal Studio', (root / 'Fila-MIT.txt').read_text())
        language = root / 'TreeSitterLanguages'
        self.assertIn('Munif Tanjim', (language / 'Licenses/Updates/Lua.txt').read_text())
        self.assertTrue((language / 'Licenses/Folding/nvim-treesitter-APACHE-2.0.txt').is_file())
        self.assertFalse((root / 'Runestone-wrapper-MIT.txt').exists())
        lua = json.loads((language / 'Tests/Updates/Lua.json').read_text())
        self.assertEqual(lua['revision'], '10fe0054734eec83049514ea2e718b2a56acd0c9')
        self.assertEqual(lua['repo'], 'https://github.com/tree-sitter-grammars/tree-sitter-lua')
        bundle = self.source('OpenSourceLicenses.txt')
        self.assertIn('OwnGoal Studio', bundle)
        self.assertIn('SOURCE TEXT MODULE', bundle)
        for path in [root / 'Fila-MIT.txt', root / 'Runestone-MIT.txt', root / 'TreeSitter-runtime-MIT.txt', language / 'LICENSE'] + list((language / 'Licenses').rglob('*')):
            if path.is_file():
                # Display copies omit trailing whitespace; retained evidence is byte-checked above.
                display_text = '\n'.join(line.rstrip() for line in path.read_text().splitlines()).strip()
                self.assertIn(display_text, bundle, str(path))


if __name__ == '__main__':
    unittest.main()
