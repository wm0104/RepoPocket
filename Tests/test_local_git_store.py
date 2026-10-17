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

    def test_project_file_import_service_is_available(self):
        self.assertTrue((ROOT / 'RepoPocket/LocalGitImport.swift').is_file(),
                        'Local Git has no file/folder import service')

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
  catch {precondition((try? String(contentsOf:file))=="external edit")}
  let current=try LocalGitFileAccess.read(root:folder,path:"代码.py")
  do {try LocalGitFileAccess.write(root:folder,path:"代码.py",text:String(repeating:"x",count:1024*1024+1),expected:current.fingerprint);preconditionFailure("oversized save accepted")} catch {}
  try LocalGitFileAccess.write(root:folder,path:"代码.py",text:"edited",expected:current.fingerprint)
  precondition((try? String(contentsOf:file))=="edited")
  do {_=try LocalGitFileAccess.read(root:folder,path:"../registry");preconditionFailure("escaped root")} catch {}
  let link=folder.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(at:link,withDestinationURL:sibling)
  do {_=try LocalGitFileAccess.read(root:folder,path:"link");preconditionFailure("followed symlink")} catch {}
  let last=try LocalGitFileAccess.read(root:folder,path:"代码.py")
  try LocalGitFileAccess.delete(root:folder,path:"代码.py",expected:last.fingerprint)
  precondition(!FileManager.default.fileExists(atPath:file.path))
  precondition((try? String(contentsOf:sibling))=="keep")
  let binary=folder.appendingPathComponent("binary.bin")
  try Data([0,255,0,1]).write(to:binary)
  do {_=try LocalGitFileAccess.read(root:folder,path:"binary.bin");preconditionFailure("binary opened as text")} catch {}
  let binaryHash=try LocalGitFileAccess.fileFingerprint(root:folder,path:"binary.bin")
  try LocalGitFileAccess.delete(root:folder,path:"binary.bin",expected:binaryHash)
  precondition(!FileManager.default.fileExists(atPath:binary.path))
  try store.remove(project)
  precondition(FileManager.default.fileExists(atPath:folder.path))
  let loaded=LocalGitRegistry(directory:parent.appendingPathComponent("registry"),internalRoot:parent)
  precondition(loaded.projects.isEmpty)
  let restored=try loaded.prepare(folder);precondition(restored.id==project.id)
  try loaded.attach(restored);precondition(loaded.projects.count==1)
  let wrong=LocalGitProject(id:project.id,name:project.name,bookmark:project.bookmark,identity:"different directory",metadataID:project.metadataID,usesPrivateGit:project.usesPrivateGit)
  do {try LocalGitFileAccess.withRoot(wrong,internalRoot:parent){_ in preconditionFailure("wrong identity accepted")};preconditionFailure("identity not checked")} catch {}
  let bad=LocalGitProject(id:UUID(),name:"bad",bookmark:Data([0,1]),identity:project.identity,metadataID:UUID(),usesPrivateGit:true)
  do {try LocalGitFileAccess.withRoot(bad,internalRoot:parent){_ in preconditionFailure("invalid bookmark accepted")};preconditionFailure("bookmark not checked")} catch {}
  let broken=parent.appendingPathComponent("broken")
  try FileManager.default.createDirectory(at:broken,withIntermediateDirectories:true)
  let record=broken.appendingPathComponent("projects.json")
  try Data("corrupt".utf8).write(to:record)
  let corrupt=LocalGitRegistry(directory:broken,internalRoot:parent)
  precondition(!corrupt.error.isEmpty)
  do {try corrupt.attach(project);preconditionFailure("overwrote unreadable registry")} catch {}
  precondition((try? String(contentsOf:record))=="corrupt")
  print("PASS original identity, duplicate import, edit conflict, symlink, exact delete and retained project")
 }
}
''', encoding='utf-8')
            command = ['swiftc', '-parse-as-library', *[str(ROOT/'RepoPocket'/f) for f in FILES[:3]], str(fixture), '-o', str(root/'check')]
            subprocess.run(command, check=True)
            subprocess.run([str(root/'check')], check=True)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift fixture runs on macOS')
    def test_binary_folder_import_preserves_paths_bytes_and_existing_files(self):
        fixture_source = r'''
import Foundation
@main struct Fixture {
 static func main() throws {
  let fm = FileManager.default
  let parent = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fm.createDirectory(at: parent, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: parent) }
  let root = parent.appendingPathComponent("worktree")
  let inbox = parent.appendingPathComponent("inbox")
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
  let debs = inbox.appendingPathComponent("debs")
  try fm.createDirectory(at: debs.appendingPathComponent("嵌套"), withIntermediateDirectories: true)
  let binary = Data([0,255,1,0,127,65,66])
  try binary.write(to: debs.appendingPathComponent("插件.deb"))
  try Data("print(1)\n".utf8).write(to: debs.appendingPathComponent("嵌套/代码.py"))
  let zip = inbox.appendingPathComponent("文件.zip")
  try Data([0x50,0x4b,3,4,0,255]).write(to: zip)
  let shell = inbox.appendingPathComponent("run.sh")
  try Data("#!/bin/sh\necho ok\n".utf8).write(to: shell)
  try fm.setAttributes([.posixPermissions:0o755], ofItemAtPath:shell.path)
  let keep = root.appendingPathComponent("保留.bin")
  try binary.write(to: keep)
  let result = try LocalGitImport.copy(sources:[debs,zip,shell],into:root)
  precondition(Set(result.paths)==["debs/插件.deb","debs/嵌套/代码.py","文件.zip","run.sh"])
  precondition((try? Data(contentsOf:root.appendingPathComponent("debs/插件.deb")))==binary)
  precondition((try? Data(contentsOf:debs.appendingPathComponent("插件.deb")))==binary)
  precondition(!fm.fileExists(atPath:root.appendingPathComponent("插件.deb").path), "Folder was flattened")
  precondition((try? fm.attributesOfItem(atPath:root.appendingPathComponent("run.sh").path)[.posixPermissions] as? NSNumber)?.intValue==0o755)
  do { _=try LocalGitImport.copy(sources:[debs],into:root);preconditionFailure("Overwrote existing folder") } catch {}
  precondition((try? Data(contentsOf:keep))==binary)
  let link = inbox.appendingPathComponent("linked.deb")
  try fm.createSymbolicLink(at:link,withDestinationURL:keep)
  do {_=try LocalGitImport.copy(sources:[link],into:root);preconditionFailure("Imported symlink")} catch {}
  let bad = inbox.appendingPathComponent("bad")
  try fm.createDirectory(at:bad.appendingPathComponent(".git"),withIntermediateDirectories:true)
  do {_=try LocalGitImport.copy(sources:[bad],into:root);preconditionFailure("Imported Git metadata")} catch {}
  precondition(!fm.fileExists(atPath:root.appendingPathComponent("bad").path))
  let sub = root.appendingPathComponent("target")
  try fm.createDirectory(at:sub,withIntermediateDirectories:true)
  _=try LocalGitImport.copy(sources:[zip],into:root,directory:"target")
  precondition((try? Data(contentsOf:sub.appendingPathComponent("文件.zip")))==(try? Data(contentsOf:zip)))
  do {_=try LocalGitImport.copy(sources:[root],into:root,directory:"target");preconditionFailure("Imported project into itself")} catch {}
  let fresh = inbox.appendingPathComponent("cancelled.deb")
  try binary.write(to:fresh)
  do {
   _=try LocalGitImport.copy(sources:[fresh],into:root) {
    if (try fm.contentsOfDirectory(atPath:root.path)).contains(where:{$0.hasPrefix(".repopocket-import-")}) {throw CancellationError()}
   }
   preconditionFailure("Ignored cancellation")
  } catch {}
  precondition(!fm.fileExists(atPath:root.appendingPathComponent("cancelled.deb").path))
  precondition(!(try fm.contentsOfDirectory(atPath:root.path)).contains(where:{$0.hasPrefix(".repopocket-import-")}))
  let collision = inbox.appendingPathComponent("collision.deb")
  try binary.write(to:collision)
  do {
   _=try LocalGitImport.copy(sources:[collision],into:root) {
    let stage = try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).first(where:{$0.lastPathComponent.hasPrefix(".repopocket-import-")})
    if let stage, fm.fileExists(atPath:stage.appendingPathComponent("collision.deb").path), !fm.fileExists(atPath:root.appendingPathComponent("collision.deb").path) {
     try Data("external".utf8).write(to:root.appendingPathComponent("collision.deb"))
    }
   }
   preconditionFailure("Overwrote file created during import")
  } catch {}
  precondition((try? String(contentsOf:root.appendingPathComponent("collision.deb")))=="external")
  let huge = inbox.appendingPathComponent("too-large.deb")
  fm.createFile(atPath:huge.path,contents:nil)
  let handle = try FileHandle(forWritingTo:huge);try handle.truncate(atOffset:129*1024*1024);try handle.close()
  do {_=try LocalGitImport.copy(sources:[huge],into:root);preconditionFailure("Exceeded per-file budget")} catch {}
  precondition(!fm.fileExists(atPath:root.appendingPathComponent("too-large.deb").path))
  precondition((try? Data(contentsOf:keep))==binary)
  print("PASS binary/ZIP/Python import, outer folder, executable bit, source retention, no overwrite, symlink/Git metadata, cancellation and budgets")
 }
}
'''
        # Evaluate throwing reads before using precondition's nonthrowing closure.
        fixture_source = fixture_source.replace('precondition(!(try fm.contentsOfDirectory(atPath:root.path)).contains(where:{$0.hasPrefix(".repopocket-import-")}))', 'let leftovers = try fm.contentsOfDirectory(atPath:root.path);precondition(!leftovers.contains(where:{$0.hasPrefix(".repopocket-import-")}))')
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            fixture = folder/'Fixture.swift'; fixture.write_text(fixture_source,encoding='utf-8')
            binary = folder/'check'
            production = ['LocalGitModels.swift','LocalGitFileAccess.swift','LocalGitImport.swift']
            subprocess.run(['swiftc','-parse-as-library',*[str(ROOT/'RepoPocket'/name) for name in production],str(fixture),'-o',str(binary)],check=True)
            subprocess.run([str(binary)],check=True)


if __name__ == '__main__':
    unittest.main()
