from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import subprocess, tempfile
s='import Foundation\nstruct AppError: Error { let text: String }\nstruct WorkspaceBinding {}\n'+Path(REPO_ROOT, 'RepoPocket/TrollMetadata.swift').read_text().split('struct TrollMetadataSnapshot')[0]+r'''
let url = "https://owner.github.io/Repo/downloads/%E4%B8%AD%E6%96%87.dylib"
precondition(TrollMetadata.matches(url, repo:"owner/Repo", branch:"main", path:"downloads/中文.dylib"))
precondition(!TrollMetadata.matches(url, repo:"other/Repo", branch:"main", path:"downloads/中文.dylib"))
precondition(!TrollMetadata.matches(url, repo:"owner/Repo", branch:"main", path:"elsewhere/中文.dylib"))
precondition(TrollMetadata.matches("https://raw.githubusercontent.com/owner/Repo/main/downloads/%E4%B8%AD%E6%96%87.dylib", repo:"owner/Repo", branch:"main", path:"downloads/中文.dylib"))
let index:[String:Any] = ["unknownRoot":"retained", "packages":[["dylib":url, "name":"before", "version":"1", "section":"custom", "custom":["nested":true], "homepage":"https://external.example"], ["dylib":"https://external.example/file.dylib", "unknown":9]]]
let bytes = try TrollMetadata.updating(index, repo:"owner/Repo", branch:"main", path:"downloads/中文.dylib", fields:["name":"after", "version":"2", "author":"Author"])
let after = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
let packages = after["packages"] as! [[String:Any]]
precondition(packages.count==2 && packages[0]["dylib"] as? String==url && packages[0]["section"] as? String=="custom")
precondition(packages[0]["custom"] is [String:Any] && packages[0]["homepage"] as? String=="https://external.example")
precondition(packages[1]["unknown"] as? Int==9 && after["unknownRoot"] as? String=="retained")
let added = try TrollMetadata.updating(["packages":[["dylib":url,"name":"old","version":"1"]]],repo:"owner/Repo",branch:"main",path:"downloads/中文.dylib",fields:["name":"New","version":"2"])
let fresh = try JSONSerialization.jsonObject(with:added) as! [String:Any]
precondition((fresh["packages"] as! [[String:Any]])[0]["name"] as? String=="New")
print("PASS metadata-only URL decoding/full path, unknown fields, external entries, section and new entry")
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'main.swift';p.write_text(s)
 subprocess.run(['swiftc',str(p),'-o',d+'/test'],check=True)
 subprocess.run([d+'/test'],check=True)
 fixture = Path(REPO_ROOT, 'tests/MetadataTextFixture.swift').read_text()
 production = Path(REPO_ROOT, 'RepoPocket/TrollMetadata.swift').read_text().split('struct TrollMetadataSnapshot')[0]
 p.write_text(production + '\n' + fixture)
 subprocess.run(['swiftc',str(p),'-o',d+'/fixture'],check=True)
 subprocess.run([d+'/fixture'],check=True)
# Test-only top-level code and AppError stubs must not enter the app target.
assert 'sources: [RepoPocket, Vendor/DebCodecs, SharedInbox]' in Path(REPO_ROOT, 'project.yml').read_text()
g=Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text();m=g[g.index('    func saveMetadata'):g.index('    func saveRemoteDeb')]
assert 'workspaceHead(original.binding.repo, branch: original.binding.branch) == original.binding.head' in m
assert 'writes: [WorkspaceWrite(path: "trollpackages.json", bytes: bytes)]' in m
assert 'trollPublish(' not in m and 'downloadFile(' not in m
v=Path(REPO_ROOT, 'RepoPocket/TrollMetadataView.swift').read_text();a=Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text()
assert 'UploadView' not in v and 'TrollMetadataView(api:' in a and '编辑插件信息' in a
print('PASS metadata-only UI and stale HEAD guard contracts')
