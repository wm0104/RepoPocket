"""Real Swift persistence/file-edit boundaries, compiled on macOS."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FILES = ['LocalGitModels.swift', 'LocalGitFileAccess.swift', 'LocalGitRegistry.swift', 'LocalGitEngine.swift']


class LocalGitStoreTests(unittest.TestCase):
    def test_production_services_exist(self):
        for name in FILES:
            self.assertTrue((ROOT / 'RepoPocket' / name).exists(), 'Missing local Git service: ' + name)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift fixture runs on macOS')
    def test_original_folder_retention_conflict_and_single_file_delete(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / 'Fixture.swift'
            fixture.write_text(r'''
import Foundation
@main struct Fixture {
 @MainActor static func main() throws {
  let parent=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:parent)}
  let folder=parent.appendingPathComponent("原目录")
  try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  let file=folder.appendingPathComponent("代码.py"), sibling=folder.appendingPathComponent("保留.txt")
  try Data("initial".utf8).write(to:file);try Data("keep".utf8).write(to:sibling)
  let store=LocalGitRegistry(directory:parent.appendingPathComponent("registry"),internalRoot:parent)
  let project=try store.prepare(folder)
  try store.attach(project)
  let duplicate=try store.prepare(folder)
  precondition(duplicate.id==project.id)
  let opened=try LocalGitFileAccess.read(root:folder,path:"代码.py")
  try Data("external edit".utf8).write(to:file)
  do {try LocalGitFileAccess.write(root:folder,path:"代码.py",text:"overwrite",expected:opened.fingerprint);preconditionFailure("stale editor saved")}
  catch {precondition(try String(contentsOf:file)=="external edit")}
  let current=try LocalGitFileAccess.read(root:folder,path:"代码.py")
  try LocalGitFileAccess.write(root:folder,path:"代码.py",text:"edited",expected:current.fingerprint)
  precondition(try String(contentsOf:file)=="edited")
  do {_=try LocalGitFileAccess.read(root:folder,path:"../registry");preconditionFailure("escaped root")} catch {}
  let link=folder.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(at:link,withDestinationURL:sibling)
  do {_=try LocalGitFileAccess.read(root:folder,path:"link");preconditionFailure("followed symlink")} catch {}
  let last=try LocalGitFileAccess.read(root:folder,path:"代码.py")
  try LocalGitFileAccess.delete(root:folder,path:"代码.py",expected:last.fingerprint)
  precondition(!FileManager.default.fileExists(atPath:file.path))
  precondition(try String(contentsOf:sibling)=="keep")
  try store.remove(project)
  precondition(FileManager.default.fileExists(atPath:folder.path))
  let loaded=LocalGitRegistry(directory:parent.appendingPathComponent("registry"),internalRoot:parent)
  precondition(loaded.projects.isEmpty)
  let restored=try loaded.prepare(folder);precondition(restored.id==project.id)
  try loaded.attach(restored);precondition(loaded.projects.count==1)
  print("PASS original identity, duplicate import, edit conflict, symlink, exact delete and retained project")
 }
}
''', encoding='utf-8')
            command = ['swiftc', '-parse-as-library', *[str(ROOT/'RepoPocket'/f) for f in FILES[:3]], str(fixture), '-o', str(root/'check')]
            subprocess.run(command, check=True)
            subprocess.run([str(root/'check')], check=True)


if __name__ == '__main__':
    unittest.main()
