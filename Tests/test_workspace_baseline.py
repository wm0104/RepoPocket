"""Compile production baseline/selection/redirect rules; UI and download invariants."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import subprocess, tempfile
w=Path(REPO_ROOT, 'RepoPocket/WorkspaceView.swift').read_text()
g=Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text()
a=g.split('    func associateWorkspace(',1)[1].split('    func commitWorkspace(',1)[0]
assert 'JSONDecoder().decode(LocalSnapshot.self' in a
assert 'WorkspaceBaselineRules.matches(original: original, verified: verified.snapshot)' in a
assert 'LocalStore.saveBinding(verified' in a and 'LocalStore.snapshot(folder)' not in a
assert '"ahead", "identical"' in a and '/compare/' in a
f=g.split('    func fetchWorkspace(',1)[1].split('    func downloadWorkspace(',1)[0]
assert 'session.bytes' not in f and '/contents/' not in f
assert '/git/blobs/' in f and 'application/vnd.github.raw+json' in f
assert 'finish(expectedGit: item.sha)' in f and 'snapshotFileSHA256(target)' in f
assert 'redirect: URLSessionTaskDelegate = ArchiveRedirectPolicy()' in g
assert 'session.download(for: request, delegate: redirect)' in g
assert 'for attempt in 0..<3' in a
assert 'top: change.id == changes.first?.id && binding != nil && !busy' in w
assert 'softGroupedRow(top: !changes.isEmpty && !busy)' in w
assert '.disabled(busy || binding == nil)' in w
assert 'baselineRevision).focused($focusedField, equals: .baselineRevision)' in w
rules=Path(REPO_ROOT, 'RepoPocket/WorkspaceBaselineRules.swift').read_text()
selection=Path(REPO_ROOT, 'RepoPocket/WorkspaceSelection.swift').read_text()
source='import Foundation\nstruct LocalSnapshot { var hashes: [String:String] = [:] }\n'+rules+'\n'+selection+r'''
precondition(WorkspaceBaselineRules.validRevision("9230587"))
precondition(WorkspaceBaselineRules.validRevision(String(repeating:"a",count:40)))
for bad in ["main","123456","123456g",String(repeating:"a",count:41),"../9230587"] { precondition(!WorkspaceBaselineRules.validRevision(bad)) }
let original = LocalSnapshot(hashes:["gone":"A","edited":"B"])
let remote = LocalSnapshot(hashes:["gone":"A","edited":"B"])
let current = LocalSnapshot(hashes:["edited":"C"])
precondition(WorkspaceBaselineRules.matches(original:original,verified:remote))
precondition(!WorkspaceBaselineRules.matches(original:current,verified:remote))
precondition(!WorkspaceBaselineRules.matches(original:original,verified:LocalSnapshot(hashes:["edited":"B"])))
precondition(WorkspaceBaselineRules.retryable(domain:NSURLErrorDomain,code:NSURLErrorNetworkConnectionLost))
precondition(WorkspaceBaselineRules.retryable(domain:NSURLErrorDomain,code:NSURLErrorTimedOut))
precondition(!WorkspaceBaselineRules.retryable(domain:NSURLErrorDomain,code:NSURLErrorCancelled))
precondition(!WorkspaceBaselineRules.retryable(domain:"HTTP",code:403))
var session = WorkspaceSelectionSession()
let scope = WorkspaceSelectionScope(accountID:"a",folder:URL(fileURLWithPath:"/workspace"),repository:"r/r",branch:"main")
session.toggle("workspace/gone",in:scope)
session.scanSucceeded(["workspace/gone","workspace/edited"],in:scope)
precondition(session.selected(in:scope)==["workspace/gone"])
session.toggle("workspace/gone",in:scope)
precondition(session.selected(in:scope).isEmpty)
let policy = ArchiveRedirectPolicy()
let task = URLSession.shared.dataTask(with:URL(string:"https://api.github.com")!)
let response = HTTPURLResponse(url:URL(string:"https://api.github.com/repos/r/r/zipball")!,statusCode:302,httpVersion:nil,headerFields:nil)!
for host in ["codeload.github.com","raw.githubusercontent.com","evil.example"] {
 var r = URLRequest(url:URL(string:"https://"+host+"/test")!)
 r.setValue("test-not-secret",forHTTPHeaderField:"Authorization")
 r.setValue("test-cookie",forHTTPHeaderField:"Cookie")
 var called=false
 policy.urlSession(URLSession.shared,task:task,willPerformHTTPRedirection:response,newRequest:r) { result in
  called=true
  if host=="evil.example" { precondition(result==nil) }
  else { precondition(result?.value(forHTTPHeaderField:"Authorization")==nil); precondition(result?.value(forHTTPHeaderField:"Cookie")==nil) }
 }
 precondition(called)
}
print("PASS production Swift: original versus edited baseline, exact historic SHA, transient retry, deletion checkbox persistence, cross-host credentials")
'''
with tempfile.TemporaryDirectory() as d:
    f=Path(d)/'main.swift';f.write_text(source)
    subprocess.run(['swiftc',str(f),'-o',d+'/test'],check=True)
    subprocess.run([d+'/test'],check=True)
print('PASS production download and UI invariants: disk raw blob, length/SHA1/SHA256, untouched ZIP, historic ancestor, one section top')
