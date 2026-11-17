"""Keep the shipped theme palette usable if a device cannot load its catalog."""
from pathlib import Path
import json
import re
import unittest

ROOT = Path(__file__).resolve().parents[1] / 'Packages/RepoPocketSyntax/Sources'


class ThemeColorResourceTests(unittest.TestCase):
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
