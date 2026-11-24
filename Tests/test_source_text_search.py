"""Fila-derived production search fixtures; host contracts do not pretend to execute Swift."""
from pathlib import Path
import hashlib
import json
import re
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
        self.assertIn('static let byteLimit = 1024 * 1024', self.source('SourceTextRules.swift'))

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

    def validate_active_licenses(self, bundle, package=None, read_bytes=None):
        package = package if package is not None else (ROOT / 'Packages/RepoPocketSyntax/Package.swift').read_text()
        read_bytes = read_bytes or (lambda path: (ROOT / path).read_bytes())
        encoded = bundle.split('--- BEGIN ACTIVE SOURCE EVIDENCE JSON ---\n', 1)[1].split('\n--- END ACTIVE SOURCE EVIDENCE JSON ---', 1)[0]
        # Freeze all selected revisions, notice identities and resource digests, not just their shape.
        self.assertEqual(hashlib.sha256(encoded.encode()).hexdigest(),
                         '99bf1e57649555867f94d98010ce44cd0f5b77bcb856458d1edc1c8818a62f2e')
        evidence = json.loads(encoded)
        for revision in ['00426ba7f8681a90c1ea0b5c03a0e0bec8cba883',
                         '4442182303a00bf2764b10ead923a1066a0946f6']:
            self.assertIn('revision: "' + revision + '"', package)
            self.assertIn(revision, bundle)
        self.assertEqual(len(evidence['languages']), 34)
        linked = set(re.findall(r'product\(name: "TreeSitter(\w+)Runestone"', package))
        self.assertEqual(linked, set(evidence['languages']))
        self.assertEqual(len(evidence['notices']), 45)
        for section, digest in evidence['notices'].items():
            self.assertEqual(bundle.count('--- ' + section + ' ---'), 1, section)
            body = bundle.split('--- ' + section + ' ---', 1)[1].split('\n--- ', 1)[0]
            body = '\n'.join(line.rstrip() for line in body.splitlines()).strip()
            self.assertEqual(hashlib.sha256(body.encode()).hexdigest(), digest, section)
        for record in evidence['languages'].values():
            self.assertRegex(record['revision'], r'^[0-9a-f]{40}$')
            notices = record.get('license_files', record.get('licenses', []))
            self.assertTrue(notices, record)
            for notice in notices:
                self.assertIn(notice, evidence['notices'])
        self.assertEqual(len(evidence['resources']), 27)
        for path, digest in evidence['resources'].items():
            self.assertEqual(hashlib.sha256(read_bytes(path)).hexdigest(), digest, path)
        return evidence

    def test_active_notices_pins_and_resource_bytes(self):
        self.validate_active_licenses(self.source('OpenSourceLicenses.txt'))
        self.assertFalse((ROOT / 'Licenses').exists())

    def test_notices_describe_active_source_not_clear_the_retired_binary(self):
        bundle = self.source('OpenSourceLicenses.txt')
        evidence = self.validate_active_licenses(bundle)
        for marker in ['10eb5ac119eec9cb4267a8e035066473983f5f3a', '0.27.1',
                       'not a retroactive resolution', 'remain unverified',
                       'OwnGoal Studio', 'Munif Tanjim', 'SOURCE TEXT MODULE',
                       'Apache-2.0', 'Yams 5.1.3', 'Kirill Simonov', 'Ingy döt Net']:
            self.assertIn(marker, bundle)
        lua = evidence['languages']['Lua']
        self.assertEqual(lua['revision'], '10fe0054734eec83049514ea2e718b2a56acd0c9')
        self.assertEqual(lua['repo'], 'https://github.com/tree-sitter-grammars/tree-sitter-lua')
        self.assertIn('Source text: TreeSitterLanguages/Licenses/Folding/nvim-treesitter-APACHE-2.0.txt', evidence['notices'])

    def test_missing_required_notice_is_rejected(self):
        bundle = self.source('OpenSourceLicenses.txt')
        for author in ['OwnGoal Studio', 'Munif Tanjim', 'JP Simard.', 'Kirill Simonov']:
            with self.subTest(author=author), self.assertRaises(AssertionError):
                self.validate_active_licenses(bundle.replace(author, 'REMOVED'))

    def test_wrong_package_or_language_revision_is_rejected(self):
        bundle = self.source('OpenSourceLicenses.txt')
        package = (ROOT / 'Packages/RepoPocketSyntax/Package.swift').read_text()
        with self.assertRaises(AssertionError):
            self.validate_active_licenses(bundle, package.replace('00426ba7f8681a90c1ea0b5c03a0e0bec8cba883', '0' * 40))
        with self.assertRaises(AssertionError):
            self.validate_active_licenses(bundle.replace('10fe0054734eec83049514ea2e718b2a56acd0c9', '0' * 40))

    def test_tampered_local_resource_is_rejected(self):
        bundle = self.source('OpenSourceLicenses.txt')
        evidence = self.validate_active_licenses(bundle)
        resource = next(path for path in evidence['resources'] if 'Colors.xcassets' in path)
        with self.assertRaises(AssertionError):
            self.validate_active_licenses(bundle, read_bytes=lambda path: (ROOT / path).read_bytes() + (b'changed' if path == resource else b''))


if __name__ == '__main__':
    unittest.main()
