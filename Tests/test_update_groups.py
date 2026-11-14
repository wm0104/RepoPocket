from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import itertools
import re
import shutil
import subprocess
import tempfile
import unittest

feature = Path(REPO_ROOT, 'RepoPocket/UpdateFeature.swift').read_text()
body = feature.split('struct AppUpdateSection: View {', 1)[1]
settings = Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text().split('struct SettingsView: View {', 1)[1]
style = Path(REPO_ROOT, 'RepoPocket/WorkspaceSelectionUI.swift').read_text()


class UpdateGroupTests(unittest.TestCase):
    def test_each_concrete_row_is_decorated_once(self):
        rows = [line.strip() for line in body.splitlines()
                if re.search(r'\b(Button|Text|Link|ProgressView)\(', line)]
        self.assertEqual(len(rows), 11)
        for row in rows:
            self.assertEqual(row.count('.softGroupedRow('), 1, row)
        self.assertEqual(body.count('top: true'), 1)
        self.assertNotIn('bottom:', body)
        self.assertIn('.softGroupedRow(top: true)', rows[0])
        self.assertNotRegex(body, r'(?m)^\s*\}\.softGroupedRow')
        self.assertNotIn('.listRowBackground', body)
        self.assertNotIn('.background(', body)
        self.assertIn('}.sheet(item: $share, onDismiss:', body)
        block = settings.split('AppUpdateSection(api: api, checker: updateChecker)', 1)[1].split('}.formStyle', 1)[0]
        self.assertIn('.softGroupedRow(bottom: true)', block)
        self.assertNotIn('top: true', block)
        self.assertNotIn('Section', block)
        self.assertIn('listRowSeparator(.hidden)', style)
        self.assertIn('.overlay(alignment: .bottom)', style)
        self.assertIn('if !bottom {', style)
        self.assertIn('.frame(height: 0.5)', style)
        self.assertEqual(style.count('.listRowBackground('), 1)

    def test_all_dynamic_states_have_only_outer_corners(self):
        # Read the actual source branches and row modifiers, rather than
        # maintaining a separate list of expected boundary flags.
        version = next(line for line in settings.splitlines() if 'Text("RepoPocket ' in line)
        state_count = 0
        for checking, message, release, ipa, downloading, downloaded in itertools.product((False, True), repeat=6):
            active = [True]
            rows = []
            for raw in body.split('        Group {', 1)[1].split('        }.sheet', 1)[0].splitlines():
                line = raw.strip()
                if line == '}':
                    active.pop()
                    continue
                condition = None
                for marker, value in [
                    ('if !checker.message.isEmpty {', message),
                    ('if let release = checker.release {', release),
                    ('if let ipa = release.ipaURL {', ipa),
                    ('if checker.downloaded == nil {', not downloaded),
                    ('if checker.downloading {', downloading),
                    ('if let file = checker.downloaded {', downloaded),
                ]:
                    if line.startswith(marker):
                        condition = value
                        break
                inline = condition is not None and line.endswith('}')
                enabled = all(active) and (condition is None or condition)
                if condition is not None and not inline:
                    active.append(enabled)
                if enabled and re.search(r'\b(Button|Text|Link|ProgressView)\(', line):
                    rows.append(('top: true' in line, 'bottom: true' in line))
            self.assertEqual(active, [True])
            rows.append(('top: true' in version, 'bottom: true' in version))
            self.assertEqual(rows[0], (True, False))
            self.assertEqual(rows[-1], (False, True))
            self.assertTrue(all(row == (False, False) for row in rows[1:-1]))
            self.assertEqual(sum(top for top, _ in rows), 1)
            self.assertEqual(sum(bottom for _, bottom in rows), 1)
            state_count += 1
        self.assertEqual(state_count, 64)
        print('PASS 64 dynamic update combinations: initial/checking/error/release/no IPA/download/cancel/downloaded; one top, one bottom, straight intermediate rows')

    @unittest.skipUnless(shutil.which('swiftc'), 'SwiftUI geometry runs in macOS Actions')
    def test_production_shape_geometry_in_swift(self):
        shape = style.split('struct SoftGroupShape: Shape {', 1)[1].split('\nextension View {', 1)[0]
        source = 'import SwiftUI\nstruct SoftGroupShape: Shape {' + shape + '''
let rect = CGRect(x: 0, y: 0, width: 320, height: 60)
for top in [false, true] {
    for bottom in [false, true] {
        let path = SoftGroupShape(top: top, bottom: bottom).path(in: rect)
        precondition(path.contains(CGPoint(x: 1, y: 1)) == !top)
        precondition(path.contains(CGPoint(x: 319, y: 1)) == !top)
        precondition(path.contains(CGPoint(x: 1, y: 59)) == !bottom)
        precondition(path.contains(CGPoint(x: 319, y: 59)) == !bottom)
        precondition(path.contains(CGPoint(x: 160, y: 1)))
        precondition(path.contains(CGPoint(x: 160, y: 59)))
    }
}
print("PASS production SoftGroupShape Swift geometry: symmetric outer corners and straight internal edges")
'''
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / 'main.swift'
            main.write_text(source)
            subprocess.run(['swiftc', str(main), '-o', folder + '/geometry'], check=True)
            subprocess.run([folder + '/geometry'], check=True)


if __name__ == '__main__':
    unittest.main()
