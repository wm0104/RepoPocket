"""Keep the shipped theme palette usable if a device cannot load its catalog."""
from pathlib import Path
import json
import re
import unittest

ROOT = Path(__file__).resolve().parents[1] / 'Packages/RepoPocketSyntax/Sources'


class ThemeColorResourceTests(unittest.TestCase):
    def test_source_and_patch_highlighting_can_bypass_runestone_default_theme(self):
        app = Path(__file__).resolve().parents[1] / 'RepoPocket'
        source = (app / 'SourceCodeView.swift').read_text(encoding='utf-8')
        guard = source.split('static func highlight(', 1)[1].split('let theme:', 1)[0]
        self.assertIn('runestoneThemeAvailable,', guard)
        self.assertIn('return NSAttributedString(string: text, attributes: [.foregroundColor: UIColor.label])', guard)
        check = source.split('private static let runestoneThemeAvailable', 1)[1].split('}()', 1)[0]
        self.assertIn('Bundle.main.bundleURL.appendingPathComponent("Runestone_Runestone.bundle")', check)
        self.assertIn('UIColor(named: "theme_" + $0, in: bundle, compatibleWith: nil) != nil', check)
        self.assertEqual(set(re.findall(r'"([a-z_]+)"', check)), {
            'foreground', 'gutter_background', 'gutter_hairline', 'line_number',
            'current_line', 'line_number_current_line', 'invisible_characters',
            'page_guide_hairline', 'page_guide_background', 'marked_text', 'selection', 'theme_',
        })
        for caller in ('SourceTextSurface.swift', 'CommitPatchView.swift'):
            self.assertIn('SourceHighlighter.highlight(', (app / caller).read_text(encoding='utf-8'))

    def test_both_theme_loaders_do_not_force_unwrap_missing_colors(self):
        for name in ('Tomorrow', 'OneDark'):
            with self.subTest(theme=name):
                text = (ROOT / ('Runestone' + name + 'Theme') / (name + 'Theme.swift')).read_text(encoding='utf-8')
                loader = text.split('convenience init(namedInModule name: String)', 1)[1]
                self.assertIn('if let color = UIColor(named: name, in: .module, compatibleWith: nil)', loader)
                self.assertNotIn('compatibleWith: nil)!', loader)
                self.assertNotIn('fatalError', loader)

    def test_fallbacks_match_every_existing_asset_without_new_colors(self):
        for name in ('Tomorrow', 'OneDark'):
            with self.subTest(theme=name):
                folder = ROOT / ('Runestone' + name + 'Theme')
                text = (folder / (name + 'Theme.swift')).read_text(encoding='utf-8')
                matches = re.findall(r'case "([^"]+)": self.init\(red: ([\d.]+), green: ([\d.]+), blue: ([\d.]+), alpha: ([\d.]+)\)', text)
                actual = {key: tuple(map(float, values)) for key, *values in matches}
                expected = {}
                for path in (folder / 'Colors.xcassets').glob('*.colorset/Contents.json'):
                    color = json.loads(path.read_text(encoding='utf-8'))['colors'][0]['color']
                    self.assertEqual(color['color-space'], 'srgb')
                    expected[path.parent.stem] = tuple(float(color['components'][key]) for key in ('red', 'green', 'blue', 'alpha'))
                self.assertTrue(expected)
                self.assertEqual(actual, expected)


if __name__ == '__main__':
    unittest.main()
