"""Approved 1.0.9 home, quoted replies and honest daily activity coverage."""
from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]

class HomeCommunityTests(unittest.TestCase):
    def test_refresh_replaces_pending_request_and_title_only_issue_is_retained(self):
        source=(ROOT/'RepoPocket/ActivityCalendar.swift').read_text().split('func load(refresh:',1)[1]
        self.assertNotIn('!busy',source.split('if refresh',1)[0], 'Refresh must cancel before checking busy')
        composer=(ROOT/'RepoPocket/CollaborationComposer.swift').read_text()
        self.assertIn('CollaborationDraftRules.hasContent(',composer)
        people=(ROOT/'RepoPocket/UserConnectionsView.swift').read_text()
        self.assertIn('已达读取上限',people)
        discussion=(ROOT/'RepoPocket/CollaborationViews.swift').read_text().split('struct DiscussionView:',1)[1].split('struct PullFilesView:',1)[0]
        self.assertIn('.sheet(item: $composerTarget)',discussion)
        self.assertNotIn('LazyVGrid(', (ROOT/'RepoPocket/ActivityCalendarView.swift').read_text())

    def test_home_uses_destinations_and_shared_search(self):
        app = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
        home = app.split('struct RepositoriesView:',1)[1].split('struct BrowserView:',1)[0]
        self.assertIn('RepositoryHomeLinksSection(', home)
        self.assertNotIn('RepositoryInlineSection(', home)
        self.assertIn('PersonalIssuesSection(', home)
        for name in ['RepositorySections.swift','UserConnectionsView.swift']:
            source = (ROOT/'RepoPocket'/name).read_text()
            self.assertIn('ListSearchField(', source)
            self.assertIn('ListSearchButton(', source)
        composer = (ROOT/'RepoPocket/CollaborationComposer.swift').read_text()
        self.assertIn('replyContext', composer)
        self.assertIn('text: submittedText', composer)
        chart = (ROOT/'RepoPocket/NativeStatisticsView.swift').read_text().split('struct NativeActivityChartView:',1)[1].split('struct NativeDeveloper:',1)[0]
        self.assertNotIn('NativeHistogram(', chart)
        self.assertIn('ActivityCalendarView(', chart)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production Swift fixtures run on macOS')
    def test_production_search_reply_activity_and_request_budget(self):
        github = (ROOT/'RepoPocket/GitHub.swift').read_text()
        models = github[github.index('struct User: Decodable'):github.index('struct Release: Decodable')]
        prefix = r'''import Foundation
import Combine
struct AppError: LocalizedError { let text:String; var errorDescription:String? {text} }
enum RefreshFailure { static func isCancellation(_ error:Error)->Bool { error is CancellationError } }
@MainActor final class GitHub {
 var isCurrentSession = true
 var pages:[Int]=[]
 var batches:[[CommunityEvent]]=[]
 var operation:((Int) async throws -> [CommunityEvent])?
 func communityEvents(_ login:String, page:Int) async throws -> [CommunityEvent] {
  pages.append(page)
  if let operation { return try await operation(page) }
  return batches.isEmpty ? [] : batches.removeFirst()
 }
}
'''
        files=['RepositoryInput.swift','CommunityModels.swift','ChinaDate.swift','HomeCommunityModels.swift','ActivityCalendar.swift']
        fixture = r'''
@main struct Run {
 static func event(_ id:String,_ date:String?) -> CommunityEvent {
  CommunityEvent(id:id,type:"PushEvent",actor:.init(login:"a",avatar_url:nil),repo:.init(name:"a/r"),created_at:date)
 }
 @MainActor static func drain(_ store:ActivityCalendarStore) async { while store.busy { await Task.yield() } }
 @MainActor static func main() async throws {
  precondition(HomeListSearch.matches(" 中文 PYTHON ", fields:["中文 python 仓库"]))
  precondition(HomeListSearch.matches("", fields:["anything"]))
  precondition(!HomeListSearch.matches("missing", fields:["anything"]))
  precondition(try PersonalIssueRules.query(login:"alice",filter:.involved) == "is:issue involves:alice")
  do { _ = try PersonalIssueRules.query(login:"alice repo:secret",filter:.mentioned); preconditionFailure() } catch {}
  let context = CommentReplyContext(id:7,login:"alice",body:"> old quote\n\n这次正文\n第二行",url:nil)
  precondition(CollaborationDraftRules.hasContent(number:nil,title:"A title",text:""))
  precondition(!CollaborationDraftRules.hasContent(number:nil,title:" ",text:"body"))
  precondition(!CollaborationDraftRules.hasContent(number:4,title:"",text:" \n "))
  let reply = try context.submission("谢谢",repo:"o/r",number:4)
  let target=DiscussionComposerTarget.reply(context)
  precondition(target.replyContext?.id==7 && target.id=="reply-7" && DiscussionComposerTarget.comment.replyContext==nil)
  precondition(reply.contains("@alice") && reply.contains("> 这次正文") && reply.contains("> 第二行"))
  precondition(reply.contains("#issuecomment-7") && !reply.contains("old quote") && reply.hasSuffix("谢谢"))
  do { _ = try context.submission(" \n ",repo:"o/r",number:4); preconditionFailure() } catch {}
  let now=ChinaDate.parse("2026-10-19T05:00:00Z")!
  let events=[event("1","2026-10-18T16:01:00Z"),event("1","2026-10-18T16:01:00Z"),event("2","2026-10-17T16:01:00Z")]
  let partial=ActivityCalendar.days(events:events,exhausted:false,now:now)
  precondition(partial.count==30 && partial.last!.id=="2026-10-19" && partial.last!.count==1)
  precondition(ActivityCalendar.recordRange(events)=="2026-10-18 — 2026-10-19")
  precondition(partial[28].count==1 && !partial[28].complete && partial[27].count==nil)
  let full=ActivityCalendar.days(events:events,exhausted:true,now:now)
  precondition(full[27].count==0 && full[27].complete && full.last!.count==1)
  let malformed=ActivityCalendar.days(events:[event("bad",nil)],exhausted:true,now:now)
  precondition(malformed.allSatisfy {$0.count==nil})
  let jan=ActivityCalendar.days(events:[],exhausted:true,now:ChinaDate.parse("2027-01-01T03:00:00Z")!)
  precondition(jan.first!.id=="2026-12-03" && jan.last!.id=="2027-01-01")
  let api=GitHub(), store=ActivityCalendarStore()
  api.batches=(1...10).map {p in (1...30).map {event("\(p)-\($0)","2026-10-19T00:00:00Z")} }
  store.load(api:api,login:"a"); await drain(store)
  precondition(api.pages==[1,2,3] && store.items.count==90 && !store.exhausted)
  store.load(api:api,login:"a"); await drain(store)
  store.load(api:api,login:"a"); await drain(store)
  store.load(api:api,login:"a"); await drain(store)
  precondition(api.pages==Array(1...10) && store.items.count==300 && store.limited && !store.exhausted)
  store.load(api:api,login:"a"); await drain(store); precondition(api.pages.count==10)
  api.isCurrentSession=false; store.load(refresh:true,api:api,login:"a"); await drain(store)
  precondition(api.pages.count==10)
  let retryAPI=GitHub(), retryStore=ActivityCalendarStore()
  var attempts=0
  retryAPI.operation={_ in attempts+=1; if attempts==1 { throw AppError(text:"offline") }; return [] }
  retryStore.load(api:retryAPI,login:"a"); await drain(retryStore)
  precondition(!retryStore.error.isEmpty && retryAPI.pages==[1])
  retryStore.load(api:retryAPI,login:"a"); await drain(retryStore)
  precondition(retryAPI.pages==[1,1] && retryStore.exhausted && retryStore.error.isEmpty)
  let cancelledAPI=GitHub(), cancelledStore=ActivityCalendarStore()
  var gate:CheckedContinuation<[CommunityEvent],Never>?
  cancelledAPI.operation={_ in await withCheckedContinuation { gate=$0 } }
  cancelledStore.load(api:cancelledAPI,login:"a")
  while gate==nil { await Task.yield() }
  cancelledStore.cancel(); cancelledAPI.isCurrentSession=false
  gate!.resume(returning:[event("stale","2026-10-19T00:00:00Z")])
  for _ in 0..<20 { await Task.yield() }
  precondition(cancelledStore.items.isEmpty && !cancelledStore.busy)
  let replacingAPI=GitHub(), replacingStore=ActivityCalendarStore()
  var old:CheckedContinuation<[CommunityEvent],Never>?
  replacingAPI.operation={_ in await withCheckedContinuation {old=$0} }
  replacingStore.load(api:replacingAPI,login:"a")
  while old==nil { await Task.yield() }
  replacingAPI.operation={_ in [event("new","2026-10-19T00:00:00Z")] }
  replacingStore.load(refresh:true,api:replacingAPI,login:"a")
  await drain(replacingStore)
  old!.resume(returning:[event("old","2026-10-19T00:00:00Z")])
  for _ in 0..<20 { await Task.yield() }
  precondition(replacingStore.items.map(\.id)==["new"] && replacingStore.exhausted && !replacingStore.busy)
  print("PASS production list search, quoted reply, bounded daily coverage, timezone and activity paging")
 }
}
'''
        fixture=fixture.replace('precondition(try PersonalIssueRules.query(login:"alice",filter:.involved) == "is:issue involves:alice")', 'let q=try PersonalIssueRules.query(login:"alice",filter:.involved); precondition(q == "is:issue involves:alice")')
        source=prefix+models+'\n'+'\n'.join((ROOT/'RepoPocket'/f).read_text() for f in files)+fixture
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'Fixture.swift';path.write_text(source)
            exe=str(Path(folder)/'test')
            subprocess.run(['swiftc','-parse-as-library',str(path),'-o',exe],check=True)
            subprocess.run([exe],check=True,timeout=30)

if __name__=='__main__': unittest.main()
