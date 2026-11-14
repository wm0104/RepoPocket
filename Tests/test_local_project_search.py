"""Recursive local name/path search: production Swift fixture + UI safety contracts."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LocalProjectSearchTests(unittest.TestCase):
    def test_search_is_project_scoped_and_reuses_existing_openers(self):
        source = (ROOT / 'RepoPocket/LocalProjectEditor.swift').read_text()
        self.assertIn('Image(systemName: "magnifyingglass")', source)
        self.assertIn('LocalProjectSearchView', source)
        search = source.split('struct LocalProjectSearchView:', 1)[1]
        self.assertIn('LocalGitEngine.shared.file', search)
        self.assertIn('LocalGitFileAccess.searchEntries(root: root)', search)
        self.assertIn('LocalGitFileAccess.coordinate(root, writing: false)', search)
        self.assertIn('LocalProjectFilesView(', search)
        self.assertIn('LocalProjectEditor(', search)
        self.assertIn('LocalProjectDebEditor(', search)
        self.assertIn('filePresentation.didDismiss()', search)
        self.assertIn('.id(file.id)', search)
        self.assertIn('Text(entry.path)', search)
        self.assertIn('SoftGroupRows', search)
        self.assertIn('generation == AccountStore.generation', search)
        self.assertIn('api.isCurrentSession', search)
        self.assertIn('withTaskCancellationHandler', search)
        self.assertIn('.githubAccountChanged', search)
        body = search.split('var body: some View', 1)[1].split('private func load()', 1)[0]
        self.assertNotIn('contentsOfDirectory', body)
        self.assertNotIn('Data(contentsOf:', search)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production local search fixture runs on macOS')
    def test_recursive_search_paths_metadata_symlinks_limits_and_cancellation(self):
        fixture = r'''
import Foundation
@main struct Fixture {
 static func main() async throws {
  let fm = FileManager.default
  let parent = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let root = parent.appendingPathComponent("project")
  let outside = parent.appendingPathComponent("outside")
  try fm.createDirectory(at: root.appendingPathComponent("Sources/Nested"), withIntermediateDirectories: true)
  try fm.createDirectory(at: outside, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: parent) }
  try Data("not a name match".utf8).write(to: root.appendingPathComponent("Sources/Nested/中文.swift"))
  try Data("SECRET-CONTENT".utf8).write(to: root.appendingPathComponent("README.md"))
  try Data("outside".utf8).write(to: outside.appendingPathComponent("leak.swift"))
  try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
  try Data("credentials".utf8).write(to: root.appendingPathComponent(".git/config"))
  try fm.createDirectory(at: root.appendingPathComponent("Sources/.GIT"), withIntermediateDirectories: true)
  try Data().write(to: root.appendingPathComponent("Sources/.GIT/secret"))
  try fm.createSymbolicLink(at: root.appendingPathComponent("linked-dir"), withDestinationURL: outside)
  try fm.createSymbolicLink(at: root.appendingPathComponent("linked-file"), withDestinationURL: outside.appendingPathComponent("leak.swift"))
  try fm.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
  let original = try Data(contentsOf: root.appendingPathComponent("Sources/Nested/中文.swift"))
  let entries = try LocalGitFileAccess.searchEntries(root: root)
  precondition(entries.map(\.path) == ["Sources", "Sources/Nested", "README.md", "Sources/Nested/中文.swift"])
  precondition(entries.filter { $0.matches("中文") }.map(\.path) == ["Sources/Nested/中文.swift"])
  precondition(entries.filter { $0.matches("sources/nested/") }.map(\.path) == ["Sources/Nested/中文.swift"])
  precondition(entries.filter { $0.matches(" Nested ") }.map(\.path) == ["Sources/Nested", "Sources/Nested/中文.swift"])
  precondition(entries.filter { $0.matches("SECRET-CONTENT") }.isEmpty)
  precondition(entries.filter { $0.matches(" ") }.isEmpty)
  let after = try Data(contentsOf: root.appendingPathComponent("Sources/Nested/中文.swift"))
  precondition(after == original)
  var checks = 0
  do {
   _ = try LocalGitFileAccess.searchEntries(root: root) { checks += 1; if checks == 3 { throw CancellationError() } }
   preconditionFailure("scan ignored cancellation")
  } catch is CancellationError {}
  let job = LocalGitSearchJob(); job.cancel()
  do { _ = try LocalGitFileAccess.searchEntries(root: root) { try job.check() }; preconditionFailure("cancelled job scanned") } catch is CancellationError {}
  do { _ = try LocalGitFileAccess.searchEntries(root: root.appendingPathComponent("linked-dir")); preconditionFailure("symlink root accepted") } catch is LocalGitError {}
  let scoped = LocalGitProject(id: UUID(), name: "project", bookmark: try root.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil), identity: "wrong", metadataID: UUID(), usesPrivateGit: true)
  do { _ = try LocalGitFileAccess.withRoot(scoped, internalRoot: parent) { try LocalGitFileAccess.searchEntries(root: $0) }; preconditionFailure("wrong root identity scanned") } catch is LocalGitError {}
  let wide = parent.appendingPathComponent("wide")
  try fm.createDirectory(at: wide, withIntermediateDirectories: true)
  for index in 0...2000 { try Data().write(to: wide.appendingPathComponent("file\(index)")) }
  do { _ = try LocalGitFileAccess.searchEntries(root: wide); preconditionFailure("partial oversized directory") } catch is LocalGitError {}
  let huge = parent.appendingPathComponent("huge")
  try fm.createDirectory(at: huge, withIntermediateDirectories: true)
  for directory in 0..<11 {
   let folder = huge.appendingPathComponent("d\(directory)")
   try fm.createDirectory(at: folder, withIntermediateDirectories: true)
   for index in 0..<1900 { try Data().write(to: folder.appendingPathComponent("file\(index)")) }
  }
  do { _ = try LocalGitFileAccess.searchEntries(root: huge); preconditionFailure("partial oversized project") } catch is LocalGitError {}
  print("PASS local recursive path search, metadata/symlink exclusions, read-only scan, scope, cancellation and limits")
 }
}
'''
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / 'Fixture.swift'
            main.write_text(fixture, encoding='utf-8')
            binary = str(Path(folder) / 'check')
            sources = ['ChinaDate.swift', 'LocalGitModels.swift', 'LocalGitFileAccess.swift']
            subprocess.run(['swiftc', '-parse-as-library', *[str(ROOT / 'RepoPocket' / f) for f in sources], str(main), '-o', binary], check=True)
            subprocess.run([binary], check=True, timeout=120)


if __name__ == '__main__':
    unittest.main()
