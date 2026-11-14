"""Compact row source contracts; the optional harness executes the real Swift comparator.

These contracts do not compile SwiftUI or prove native hit testing/chevron behavior.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def directory_rows():
    app = (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text(encoding='utf-8')
    return app.split('@SoftGroupRowsBuilder private var directoryRows:', 1)[1].split('    var body: some View {', 1)[0]


class CompactDirectoryRowsTests(unittest.TestCase):
    def test_small_single_line_labels_leave_room_for_time(self):
        rows = directory_rows()
        self.assertNotIn('ByteCountFormatter', rows)
        self.assertNotIn('width: 40, height: 44', rows)
        self.assertNotIn('.background(.thinMaterial', rows)
        self.assertNotIn('VStack', rows)
        self.assertEqual(rows.count('Text(e.name).lineLimit(1).truncationMode(.tail)'), 2)
        self.assertEqual(rows.count('.frame(maxWidth: .infinity, alignment: .leading)'), 2)
        self.assertEqual(rows.count('.font(.body).frame(width: 20)'), 2)

    def test_navigation_overlays_are_separate_from_time_and_menus(self):
        rows = directory_rows()
        # Only the name area owns the invisible link; the time is its sibling.
        self.assertEqual(rows.count('label: { Color.clear.contentShape(Rectangle()) }'), 2)
        self.assertEqual(rows.count('.buttonStyle(.plain).opacity(0)'), 2)
        self.assertEqual(rows.count('.accessibilityLabel(e.name)'), 2)
        self.assertEqual(rows.count('.accessibilityHidden(false)'), 2)
        self.assertEqual(rows.count('.frame(minHeight: 28)'), 2)
        self.assertEqual(rows.count('PathCommitMetadataLink('), 2)
        # Balance each overlay closure so mere token presence cannot hide nested controls.
        overlays = rows.split('.overlay {')[1:]
        self.assertEqual(len(overlays), 2)
        for overlay in overlays:
            depth = 1
            for end, char in enumerate(overlay):
                depth += (char == '{') - (char == '}')
                if depth == 0:
                    break
            self.assertEqual(depth, 0)
            navigation = overlay[:end]
            self.assertEqual(navigation.count('NavigationLink {'), 1)
            self.assertNotIn('PathCommitMetadataLink(', navigation)
            self.assertNotIn('Button(', navigation)
            self.assertNotIn('Menu {', navigation)
            self.assertIn('.accessibilityIdentifier("repository-entry-" + e.path)', navigation,
                          'Entry identifiers must not propagate over sibling time controls')
            self.assertNotIn('.accessibilityIdentifier("repository-entry-" + e.path)', overlay[end:],
                             'The enclosing file row must not overwrite the path-commit identifier')
            self.assertIn('PathCommitMetadataLink(', overlay[end:])
        self.assertNotIn('NavigationLink(value:', rows)
        for token in ['DirectoryBrowserDestination(api: api, repo: repo, path: e.path, branch: activeBranch)',
                      'FileView(api: api, repo: repo, entry: e, branch: activeBranch, canWrite: canWrite)',
                      '复制文件夹链接', '复制文件链接', '复制 raw 链接', 'Button("删除", role: .destructive)',
                      'deleteAccount = api.accountID; deleteGeneration = AccountStore.generation',
                      'deleteBranch = activeBranch; deleteEntry = e',
                      '.disabled(deleting || busy || activeBranch.isEmpty)',
                      'if canWrite && e.name.lowercased().hasSuffix(".deb")', 'debEntry = e']:
            self.assertIn(token, rows)

    def test_only_presentation_is_sorted_by_name_with_stable_ties(self):
        rows = directory_rows()
        self.assertIn('for e in entries.sorted(by: Self.directoryEntryPrecedes)', rows)
        app = (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text(encoding='utf-8')
        sort = app.split('private static func directoryEntryPrecedes', 1)[1].split('@SoftGroupRowsBuilder', 1)[0]
        for token in ['lhs.type == "dir"', 'rhs.type == "dir"',
                      'lhs.name.localizedStandardCompare(rhs.name)',
                      'lhs.name < rhs.name', 'lhs.path < rhs.path']:
            self.assertIn(token, sort)
        self.assertNotIn('committedDate', sort)

    def test_time_only_label_preserves_commit_navigation_and_invalid_date_fallback(self):
        metadata = (ROOT / 'RepoPocket/PathCommitMetadata.swift').read_text(encoding='utf-8')
        link = metadata.split('struct PathCommitMetadataLink:', 1)[1]
        self.assertIn('if let commit', link)
        self.assertIn('ChinaDate.parse(commit.committedDate)', link)
        self.assertIn('Text(PathCommitRelativeTime.text(for: date, now: context.date))', link)
        self.assertIn('Text("查看提交")', link)
        self.assertNotIn('Text(commit.messageHeadline)', link)
        self.assertIn('.frame(maxWidth: 96, alignment: .trailing)', link)
        self.assertNotIn('NavigationLink', link, 'A second row NavigationLink can also activate the directory route')
        self.assertIn('Button { openCommit(commit) } label:', link)
        self.assertIn('.buttonStyle(.borderless)', link)
        self.assertIn('.contentShape(Rectangle())', link)
        self.assertNotIn('navigationDestination', link, 'Destination registration must stay outside the lazy List')
        browser = (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text(encoding='utf-8').split('struct BrowserView:', 1)[1].split('struct FileView:', 1)[0]
        self.assertEqual(directory_rows().count('{ openedPathCommit = $0 }'), 2)
        route = browser.split('.appNavigationDestination(isPresented: Binding(get: { openedPathCommit != nil }', 1)[1].split('.appNavigationDestination', 1)[0]
        self.assertIn('if !$0 { openedPathCommit = nil }', route)
        self.assertIn('if let commit = openedPathCommit', route)
        self.assertIn('CommitDetailView(api: api, repo: repo, sha: commit.oid)', route)
        self.assertNotIn('.opacity(0)', link)
        self.assertNotIn('.accessibilityHidden(true)', link)
        self.assertIn('.accessibilityLabel(path + " 最近提交：" + commit.messageHeadline)', link)
        self.assertIn('.accessibilityIdentifier("path-commit-" + path)', link)

    def test_ui_checks_exact_path_sha_and_original_directory_return(self):
        ui = (ROOT / 'StyleUITests/StyleBoundaryTests.swift').read_text(encoding='utf-8')
        helper = ui.split('private func assertPathCommit(', 1)[1].split('    func testReadOnlySource', 1)[0]
        for token in ['time.tap()', 'app.staticTexts[oid].exists', 'app.staticTexts["Fixture latest " + path]',
                      'app.navigationBars["提交详情"].buttons[parentTitle]', 'back.tap()',
                      'app.navigationBars[parentTitle].waitForExistence', 'time.waitForExistence',
                      'repository-path-commit-return-']:
            self.assertIn(token, helper)
        self.assertNotIn('coordinate(', helper)

    @unittest.skipUnless(shutil.which('swiftc'), 'Real comparator execution requires native Swift; source contracts are not compilation')
    def test_real_swift_comparator(self):
        app = (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text(encoding='utf-8')
        comparator = 'static func directoryEntryPrecedes' + app.split('private static func directoryEntryPrecedes', 1)[1].split('@SoftGroupRowsBuilder', 1)[0]
        github = (ROOT / 'RepoPocket/GitHub.swift').read_text(encoding='utf-8')
        entry = 'struct Entry:' + github.split('struct Entry:', 1)[1].split('struct Release:', 1)[0]
        harness = (ROOT / 'Tests/Fixtures/CompactDirectoryRowsHarness.swift').read_text(encoding='utf-8')
        with tempfile.TemporaryDirectory(prefix='repopocket-compact-rows-') as directory:
            source = Path(directory) / 'Fixture.swift'
            binary = Path(directory) / 'fixture'
            source.write_text('import Foundation\n' + entry + '\nenum DirectoryRowSort {\n' + comparator + '\n}\n' + harness, encoding='utf-8')
            subprocess.run(['swiftc', str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
