import subprocess, tempfile, zipfile, stat, urllib.request, hashlib, os, json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as d:
 root = Path(d)
 (root/'Sources'/'ZIPRegression').mkdir(parents=True)
 (root/'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ZIPRegression", platforms: [.macOS(.v12)], dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19")], targets: [.executableTarget(name: "ZIPRegression", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")])])
''')
 fixtures = [('valid', 'nested/a.txt', False), ('traversal', '../escape', False), ('absolute', '/escape', False), ('backslash', 'a\\b', False), ('symlink', 'link', True)]
 for name, path, link in fixtures:
  with zipfile.ZipFile(root/(name+'.zip'), 'w') as z:
   info=zipfile.ZipInfo(path)
   if link:
    info.create_system=3; info.external_attr=(stat.S_IFLNK | 0o777)<<16
   z.writestr(info, '/etc/passwd' if link else 'hello')
 with zipfile.ZipFile(root/'duplicate.zip', 'w') as z:
  z.writestr('A.txt','a'); z.writestr('a.txt','b')
 for name, items in {
  'entrylimit': [('d'+str(i)+'/', '') for i in range(20001)],
  'empty': [],
  'directory': [('repo/', ''), ('repo/a.txt','hello')],
  'literal': [('目录/', ''), ('目录/100%25#U4E2D.txt', 'hello')],
  'parentcase': [('A/x','a'), ('a/y','b')],
  'unicode': [('é.txt','a'), ('e\u0301.txt','b')],
  'fileparent': [('a','a'), ('a/b','b')],
  'implicit': [('a/b','hello'), ('a/','')],
 }.items():
  with zipfile.ZipFile(root/(name+'.zip'),'w') as z:
   for path, text in items: z.writestr(path,text)
 actual_sha='9230587cf32b3e49d377e7e6bd410326f4183172'
 urllib.request.urlretrieve('https://codeload.github.com/wm0104/trollfools-repo/zip/'+actual_sha,root/'real.zip')
 assert hashlib.sha256((root/'real.zip').read_bytes()).hexdigest() == '1aaad06f1eff7a3dc772433aabc3b1d6f6a8e50b8a7534c1fbaf55e490e84c93'
 with zipfile.ZipFile(root/'real.zip') as z:
  # Compare every extracted byte, not just a static source string contract.
  manifest=[(i.filename, hashlib.sha256(z.read(i)).hexdigest()) for i in z.infolist() if not i.is_dir()]
 original = Path(REPO_ROOT, 'tests/WorkspaceZIP-original.swift.txt').read_text().replace('enum WorkspaceZIP {','enum OriginalWorkspaceZIP {')
 tests = '''
let fm = FileManager.default
let base = URL(fileURLWithPath: CommandLine.arguments[1])
let oldOutput = fm.temporaryDirectory.appendingPathComponent("RepoPocket-baseline-" + UUID().uuidString, isDirectory: true)
defer { try? fm.removeItem(at: oldOutput) }
print("RUNTIME", ProcessInfo.processInfo.operatingSystemVersionString)
print("BASELINE raw:", oldOutput.path, "standard:", oldOutput.standardizedFileURL.pathComponents)
print("BASELINE first target:", oldOutput.appendingPathComponent("trollfools-repo-9230587cf32b3e49d377e7e6bd410326f4183172/").standardizedFileURL.pathComponents)
try fm.createDirectory(at: oldOutput, withIntermediateDirectories: true)
do {
 try OriginalWorkspaceZIP.extract(base.appendingPathComponent("real.zip"), to: oldOutput)
 print("BASELINE original extraction succeeded on", ProcessInfo.processInfo.operatingSystemVersionString, "(not a reproduction of the reported device failure)")
} catch {
 print("BASELINE actual ZIP failure:", error.localizedDescription)
 let baselineArchive = try Archive(url: base.appendingPathComponent("real.zip"), accessMode: .read)
 if let entry = baselineArchive.first(where: { _ in true }) {
  let child = oldOutput.appendingPathComponent(entry.path).standardizedFileURL
  print("BASELINE first entry:", entry.path)
  print("BASELINE base components:", oldOutput.standardizedFileURL.pathComponents)
  print("BASELINE child components:", child.pathComponents)
 }
 precondition(error.localizedDescription.contains("ZIP 路径越界"), "unexpected baseline failure")
}
let valid = Set(["valid", "directory", "literal", "implicit", "real"])
for name in ["valid", "directory", "literal", "implicit", "real", "traversal", "absolute", "backslash", "symlink", "duplicate", "parentcase", "unicode", "fileparent", "entrylimit", "empty"] {
 let output = base.appendingPathComponent(name + "-out", isDirectory: true)
 try fm.createDirectory(at: output, withIntermediateDirectories: true)
 var rejected = false
 do { try WorkspaceZIP.extract(base.appendingPathComponent(name + ".zip"), to: output) } catch { rejected = true }
 precondition(rejected == !valid.contains(name), name)
 if !valid.contains(name) { precondition(try! fm.contentsOfDirectory(atPath: output.path).isEmpty) }
 if name == "literal" { precondition(fm.fileExists(atPath: output.appendingPathComponent("目录/100%25#U4E2D.txt").path)) }
}
print("PASS: real ZIPFoundation extraction; zip slip, absolute, backslash, symlink and duplicate rejection before writes")
'''
 (root/'Sources'/'ZIPRegression'/'main.swift').write_text('import Foundation\nstruct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }\n'+original+Path(REPO_ROOT, 'RepoPocket/WorkspaceZIP.swift').read_text()+tests)
 subprocess.run(['swift','run','--package-path',str(root),'ZIPRegression',str(root)],check=True)
 for name, expected in manifest:
  assert hashlib.sha256((root/'real-out'/name).read_bytes()).hexdigest() == expected, name
 print('PASS native macOS: every actual ZIP file SHA256 matches', flush=True)
 # Run the same production code against UIKit-platform Foundation as well.
 devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j']))['devices']
 iphones=[v for runtime, values in devices.items() if 'iOS' in runtime for v in values if v['name'].startswith('iPhone')]
 assert iphones, 'iOS simulator unavailable'
 udid=iphones[0]['udid']
 if iphones[0]['state'] != 'Booted': subprocess.run(['xcrun','simctl','boot',udid],check=True)
 subprocess.run(['xcrun','simctl','bootstatus',udid,'-b'],check=True)
 sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
 triple='arm64-apple-ios16.0-simulator'
 build_args=['swift','build','--package-path',str(root),'--triple',triple,'--sdk',sdk,'-Xlinker','-syslibroot','-Xlinker',sdk]
 subprocess.run(build_args,check=True)
 bin_path=subprocess.check_output(build_args+['--show-bin-path'],text=True).strip()
 binary=Path(bin_path)/'ZIPRegression'
 assert binary.exists(), str(binary)
 subprocess.run(['file',str(binary)],check=True)
 subprocess.run(['codesign','--force','--sign','-',str(binary)],check=True)
 # New output directories for the second execution; fixtures remain identical.
 for output in root.glob('*-out'):
  import shutil
  shutil.rmtree(output)
 env=dict(os.environ)
 subprocess.run(['xcrun','simctl','spawn',udid,str(binary),str(root)],env=env,check=True)
 for name, expected in manifest:
  assert hashlib.sha256((root/'real-out'/name).read_bytes()).hexdigest() == expected, name
 print('PASS: pinned actual GitHub ZIP, every file byte hash; directory URL; literal percent/#U/Unicode; implicit directories; collisions before writes')
