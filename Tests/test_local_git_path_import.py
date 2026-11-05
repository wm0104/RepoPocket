"""Explicit path associations keep the same directory identity and old records."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LocalGitPathImportTests(unittest.TestCase):
    def test_launch_diagnostic_keeps_the_pre_filza_signing_policy(self):
        entitlements = plistlib.loads((ROOT / 'Entitlements.plist').read_bytes())
        self.assertNotIn('com.apple.private.security.no-sandbox', entitlements)
        self.assertNotIn('platform-application', entitlements)
        self.assertIs(entitlements['get-task-allow'], False)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production path/identity fixture requires macOS Swift')
    def test_pasted_paths_are_local_directories_and_association_does_not_follow_replacements(self):
        source = r'''
import Foundation
@main struct Fixture {
 @MainActor static func main() throws {
  let fm = FileManager.default
  let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let root = base.appendingPathComponent("原项目 with spaces")
  let owned = base.appendingPathComponent("owned")
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  try fm.createDirectory(at: owned, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: base) }
  let file = root.appendingPathComponent("keep.txt")
  try Data("unchanged".utf8).write(to: file)
  let registry = LocalGitRegistry(directory: base.appendingPathComponent("registry"), internalRoot: owned)
  for input in [root.path, "\"" + root.path + "\"", root.absoluteString] {
   let project = try registry.preparePath(input)
   precondition(project.directPath == root.resolvingSymlinksInPath().standardizedFileURL.path)
   precondition(registry.projects.isEmpty, "path entry must not silently attach")
   let restored = try JSONDecoder().decode(LocalGitProject.self, from: JSONEncoder().encode(project))
   let text = try LocalGitFileAccess.withRoot(restored, internalRoot: owned) { try String(contentsOf: $0.appendingPathComponent("keep.txt")) }
   precondition(text == "unchanged")
  }
  for input in ["", "relative/project", "/", "https://example.com/project", "file://server/share", "file:relative", "file:../relative", file.path, root.path + "\nother"] {
   do { _ = try registry.preparePath(input); preconditionFailure("invalid path accepted: \(input)") } catch {}
  }
  let project = try registry.preparePath(root.path)
  let spaced = base.appendingPathComponent("项目 ")
  try fm.createDirectory(at: spaced, withIntermediateDirectories: false)
  for input in ["\"" + spaced.path + "\"", spaced.absoluteString] {
   let selected = try registry.preparePath(input)
   let restored = try JSONDecoder().decode(LocalGitProject.self, from: JSONEncoder().encode(selected))
   let path = try LocalGitFileAccess.withRoot(restored, internalRoot: owned) { $0.path }
   precondition(path == spaced.path, "persisted path was trimmed on reopening")
  }
  var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
  legacy.removeValue(forKey: "directPath")
  let old = try JSONDecoder().decode(LocalGitProject.self, from: JSONSerialization.data(withJSONObject: legacy))
  precondition(old.directPath == nil && old.identity == project.identity)
  try fm.moveItem(at: root, to: base.appendingPathComponent("old"))
  try fm.createDirectory(at: root, withIntermediateDirectories: false)
  do { _ = try LocalGitFileAccess.withRoot(project, internalRoot: owned) { $0 }; preconditionFailure("followed replacement directory") } catch {}
  print("PASS explicit local path, legacy records, original content and directory identity")
 }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / 'Fixture.swift'
            fixture.write_text(source, encoding='utf-8')
            files = ['ChinaDate.swift', 'LocalGitModels.swift', 'LocalGitFileAccess.swift', 'LocalGitRegistry.swift']
            subprocess.run(['swiftc', '-parse-as-library', *[str(ROOT / 'RepoPocket' / p) for p in files],
                            str(fixture), '-o', str(root / 'check')], check=True)
            subprocess.run([str(root / 'check')], check=True, timeout=20)


if __name__ == '__main__':
    unittest.main()
