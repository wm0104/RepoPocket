"""Page-owned production request state: scrolling never invalidates loaded values."""
from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT=Path(__file__).resolve().parents[1]
class PageLifecycleTests(unittest.TestCase):
 def test_home_owns_state_and_scroll_refresh_does_not_invalidate_sections(self):
  app=(ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
  browser=app.split('struct BrowserView: View {',1)[1].split('struct FileView:',1)[0]
  self.assertIn('@StateObject private var readmeState',browser)
  self.assertIn('@StateObject private var homeRelease',browser)
  self.assertIn('@StateObject private var homeRuns',browser)
  refresh=browser.split('.refreshable {',1)[1].split('.toolbar {',1)[0]
  self.assertNotIn('homeRefreshRevision +=',refresh)
  self.assertNotIn('release',refresh)
  readme=(ROOT/'RepoPocket/RepositoryReadmeSection.swift').read_text()
  self.assertNotIn('entry = nil; document = nil',readme)
  self.assertIn('@ObservedObject var state: RepositoryReadmeState',readme)
  highlights=(ROOT/'RepoPocket/RepositoryHomeHighlights.swift').read_text()
  self.assertNotIn('release = nil',highlights)
  self.assertNotIn('run = nil',highlights)
 def test_approved_interface_changes(self):
  app=(ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
  self.assertFalse('WorkspaceView(api: api).tabItem' in app,'Local workspace tab must be removed without deleting documents')
  browser=app.split('struct BrowserView: View {',1)[1].split('struct FileView:',1)[0]
  self.assertFalse('.swipeActions(' in browser,'Code files use context menu deletion only')
  self.assertIn('.contextMenu {',browser)
  self.assertIn('font-size: 16px', (ROOT/'RepoPocket/ReadmeDocument.swift').read_text())
  self.assertIn('configuration.barCollapsingEnabled = false',(ROOT/'RepoPocket/NativeLinkDestination.swift').read_text())
 @unittest.skipUnless(shutil.which('swiftc'),'Production async request fixtures execute on macOS')
 def test_production_requests_coalesce_and_preserve_loaded_data(self):
  model='import Foundation\nstruct ReadmeDocument { let text: String }\n'+(ROOT/'RepoPocket/RepositoryPageState.swift').read_text()
  fixture=r''' 
import Foundation
struct FixtureError: Error {}
@main struct Run {
 @MainActor static func main() async throws {
  let state=RepositoryPageLoadState<String>()
  var calls=0
  await state.load(key:"account:A/repo/main", operation:{calls+=1;return "first"})
  for _ in 0..<20 {await state.load(key:"account:A/repo/main",operation:{calls+=1;return "unexpected"})}
  precondition(calls==1 && state.value=="first" && !state.loading)
  await state.load(key:"account:A/repo/main",refresh:true,operation:{calls+=1;throw FixtureError()})
  precondition(calls==2 && state.value=="first" && !state.error.isEmpty)
  await state.load(key:"account:A/repo/main",operation:{calls+=1;return "unexpected"})
  precondition(calls==2)
  await state.load(key:"account:A/repo/main",refresh:true,operation:{calls+=1;return "updated"})
  precondition(calls==3 && state.value=="updated" && state.error.isEmpty)
  let pending=RepositoryPageLoadState<String>()
  var gate:CheckedContinuation<String,Error>?
  var reads=0
  let first=Task {await pending.load(key:"A",operation:{reads+=1;return try await withCheckedThrowingContinuation{gate=$0}})}
  while gate==nil {await Task.yield()}
  let second=Task {await pending.load(key:"A",operation:{reads+=1;return "duplicate"})}
  await Task.yield();first.cancel()
  gate?.resume(returning:"retained");gate=nil
  await first.value;await second.value
  precondition(reads==1 && pending.value=="retained" && !pending.loading)
  await pending.load(key:"A",operation:{reads+=1;return "duplicate"})
  precondition(reads==1)
  let stale=Task {await pending.load(key:"old",operation:{return try await withCheckedThrowingContinuation{gate=$0}})}
  while gate==nil {await Task.yield()}
  await pending.load(key:"new-account",operation:{"new"})
  gate?.resume(returning:"old");gate=nil;await stale.value
  precondition(pending.value=="new")
  var valid=false
  await pending.load(key:"invalid-account",operation:{"private"},isValid:{valid})
  precondition(pending.value==nil && !pending.loading)
  valid=true
  await pending.load(key:"invalid-account",operation:{"accepted"},isValid:{valid})
  precondition(pending.value=="accepted")
  let readme=RepositoryReadmeState()
  await readme.load(key:"main",operation:{RepositoryReadmeContent(branch:"main",document:ReadmeDocument(text:"first"))})
  readme.expanded=true;readme.bodyHeight=800
  await readme.load(key:"main",operation:{preconditionFailure("scroll reloaded README")})
  precondition(readme.expanded && readme.bodyHeight==800)
  await readme.load(key:"dev",operation:{RepositoryReadmeContent(branch:"dev",document:ReadmeDocument(text:"second"))})
  precondition(!readme.expanded && readme.bodyHeight==180 && readme.value?.branch=="dev")
  print("PASS page-owned coalescing, twenty appearances, caller cancellation, retained refresh failure, stale completion and account invalidation")
 }
}
'''
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'Fixture.swift';p.write_text(model+fixture)
   subprocess.run(['swiftc','-parse-as-library',str(p),'-o',d+'/test'],check=True)
   subprocess.run([d+'/test'],check=True)
if __name__=='__main__':unittest.main()
