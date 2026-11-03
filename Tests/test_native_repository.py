"""Production mutation transport uses URLProtocol fixtures; never writes to GitHub."""
from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(shutil.which('swiftc'), 'Swift regression runs on macOS')
class NativeRepositoryTests(unittest.TestCase):
    def test_native_repository(self):
        api = (ROOT/'RepoPocket/GitHub.swift').read_text()
        models = api[api.index('struct User: Decodable'):api.index('struct Release: Decodable')]
        mutate = api[api.index('    func communityMutate('):api.index('    func communityStarDates(')]
        source = r'''
import Foundation
struct AppError: LocalizedError { let text:String; var errorDescription:String? { text } }
final class Fixture: URLProtocol {
 static let lock=NSLock(); static var seen:[URLRequest]=[]; static var status=200
 override class func canInit(with request:URLRequest)->Bool { true }
 override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
 override func startLoading() {
   Self.lock.lock(); Self.seen.append(request); let status=Self.status; Self.lock.unlock()
   client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
   client?.urlProtocol(self,didLoad:Data("{}".utf8));client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading() {}
 static func count()->Int { lock.lock();defer {lock.unlock()};return seen.count }
}
@MainActor final class GitHub {
 let session:URLSession
 var active=true; var push=false; var pushChecks=0; var payload=Data(); var queries:[URLQueryItem]=[]
 var payloads:[String:Data]=[:]; var paths:[String]=[]; var branches:[String]=[]
 var body:[String:Any]=[:]; var method="";var files:[String]=[];var invalidContent=false
 init(){let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[Fixture.self];session=URLSession(configuration:config)}
 var isCurrentSession:Bool {active}
 func ensureActiveAccount() throws {guard active else {throw CancellationError()}}
 func requireWriteAccess(_ repo:String) async throws {pushChecks+=1;guard push else {throw AppError(text:"denied")}}
 static func component(_ s:String)->String {s.addingPercentEncoding(withAllowedCharacters:.alphanumerics.union(CharacterSet(charactersIn:"-._~")))!}
 static func repoPath(_ repo:String)throws->String {"/repos/" + (try RepositoryInput.parse(repo))}
FILE_PATH
 func url(_ path:String)throws->URL {URL(string:"https://api.github.com"+path)!}
 func request(_ url:URL,method:String,body:Data)throws->URLRequest {
   try ensureActiveAccount();self.method=method;self.body=(try JSONSerialization.jsonObject(with:body)) as! [String:Any]
   var r=URLRequest(url:url);r.httpMethod=method;r.httpBody=body;r.setValue("Bearer fixture-only",forHTTPHeaderField:"Authorization");return r
 }
 func check(_ data:Data,_ response:URLResponse,operation:String)throws {
   try ensureActiveAccount();guard let h=response as? HTTPURLResponse,(200..<300).contains(h.statusCode) else {throw AppError(text:"server denied")}
 }
 func communityRead(_ path:String,query:[URLQueryItem]=[])async throws->Data {try ensureActiveAccount();queries=query;paths.append(path);return payloads[path] ?? payload}
 func resolvedBranch(_ repo:String,branch:String)async throws->String {branch.isEmpty ? "main" : branch}
 func workspaceHead(_ repo:String,branch:String)async throws->String {branches.append(branch);return String(repeating:"a",count:40)}
 func file(_ repo:String,path:String,branch:String)async throws->Entry {
   precondition(branch==String(repeating:"a",count:40));files.append(path)
   return Entry(name:path,path:path,type:"file",sha:"x",size:4,download_url:nil,content:Data(invalidContent ? [0,1,2,3] : Array("a\nb\n".utf8)).base64EncodedString(),encoding:"base64")
 }
MUTATE
}
'''.replace('MUTATE', mutate).replace('FILE_PATH', api[api.index('    static func filePath('):api.index('    private func url(')])
        for name in ['RepositoryInput.swift','CommunityModels.swift','NativeRepositoryModels.swift','NativeRepositoryAPI.swift','OfficialUpdateRedirectPolicy.swift']:
            source += '\n' + ((models+'\n') if name=='RepositoryInput.swift' else '') + (ROOT/'RepoPocket'/name).read_text()
        source += (ROOT/'RepoPocket/RepositoryReadmeSection.swift').read_text().split('struct RepositoryReadmeSection')[0].replace('import SwiftUI','import Foundation')
        remote = (ROOT/'RepoPocket/WorkspaceRemote.swift').read_text()
        source += remote[remote.index('struct GitObject:'):remote.index('extension LocalStore')]
        source += '\nextension GitHub {' + (ROOT/'RepoPocket/RepositoryFileSearch.swift').read_text().split('extension GitHub {', 1)[1]
        source += r'''
@main struct Run {
 @MainActor static func main() async throws {
   precondition(NativeStatisticsRules.lineCount("")==0)
   precondition(WorkflowStatusPresentation(status:"completed",conclusion:"success").tone=="green")
   precondition(WorkflowStatusPresentation(status:"completed",conclusion:"failure").title=="失败")
   precondition(WorkflowStatusPresentation(status:"in_progress",conclusion:nil).title=="运行中")
   precondition(WorkflowStatusPresentation(status:"completed",conclusion:nil).title=="状态未知")
   precondition(WorkflowStatusPresentation(status:"queued",conclusion:nil).title=="等待运行")
   precondition(WorkflowStatusPresentation(status:"in_progress",conclusion:"success").title=="运行中")
   precondition(WorkflowTime.elapsed(start:"2026-10-15T00:00:00Z",end:"2026-10-15T00:11:38Z",running:false)=="11分38秒")
   precondition(WorkflowTime.elapsed(start:"2026-10-15T00:00:00.000Z",end:"2026-10-15T00:00:26.000Z",running:false)=="26秒")
   precondition(WorkflowTime.elapsed(start:nil,end:nil,running:false)==nil)
   precondition(WorkflowTime.elapsed(start:"2026-10-15T00:01:00Z",end:"2026-10-15T00:00:00Z",running:false)==nil)
   precondition(WorkflowTime.elapsed(start:"0001-01-01T00:00:00Z",end:nil,running:true)==nil)
   let now=WorkflowTime.date("2026-10-15T00:02:15Z")!
   precondition(WorkflowTime.elapsed(start:"2026-10-15T00:00:00Z",end:nil,running:true,now:now)=="2分15秒")
   let legacy=try JSONDecoder().decode(WorkflowRun.self,from:Data(#"{"id":1,"run_number":1,"head_sha":"abc","status":"completed","created_at":"2026-10-15T00:00:00Z"}"#.utf8))
   precondition(legacy.run_started_at==nil && legacy.actor==nil && legacy.updated_at==nil)
   let retriedJob=try JSONDecoder().decode(WorkflowJob.self,from:Data(#"{"id":9,"name":"build","status":"completed","run_attempt":2}"#.utf8))
   precondition(retriedJob.run_attempt==2)
   let legacyJob=try JSONDecoder().decode(WorkflowJob.self,from:Data(#"{"id":9,"name":"build","status":"completed"}"#.utf8))
   precondition(legacyJob.run_attempt==nil)
   precondition(NativeStatisticsRules.lineCount("a\nb\n")==2)
   precondition(NativeStatisticsRules.lineCount("a\nb")==2)
   let short="# 自述\n简介";precondition(!ReadmePreviewRules.needsExpansion(short))
   let long=String(repeating:"一行\n",count:40);precondition(ReadmePreviewRules.needsExpansion(long))
   precondition(ReadmePreviewRules.preview(long).split(separator:"\n").count==24)
   let wide=String(repeating:"中",count:4000);precondition(ReadmePreviewRules.preview(wide).count==1800)
   for action in [CommunityMutation.comment(0),.state(1,"bad"),.merge(1,"bad"),.cancelRun(-1),.rerun(0),.deleteRun(0)] {
     do {_ = try CommunityMutationRules.request(action,text:"test");preconditionFailure()}catch{}
   }
   do {_ = try CommunityMutationRules.request(.createIssue,title:" ");preconditionFailure()}catch{}
   do {_ = try CommunityMutationRules.request(.comment(1),text:String(repeating:"x",count:60001));preconditionFailure()}catch{}
   let api=GitHub();defer{api.session.invalidateAndCancel()}
   api.payload=Data(#"{"workflow_runs":[]}"#.utf8)
   _ = try await api.workflowRuns("owner/repo",branch:"feature/fix",page:2,failedOnly:true)
   precondition(api.queries.contains { $0.name=="status" && $0.value=="failure" })
   precondition(api.queries.contains { $0.name=="branch" && $0.value=="feature/fix" })
   precondition(api.queries.contains { $0.name=="page" && $0.value=="2" })
   _ = try await api.workflowRuns("owner/repo",branch:"",page:1)
   precondition(!api.queries.contains { $0.name=="status" || $0.name=="branch" })
   _ = try await api.workflowRuns("owner/repo",branch:"feature/fix",page:1,headSHA:String(repeating:"b",count:40))
   precondition(api.queries.contains { $0.name=="head_sha" && $0.value==String(repeating:"b",count:40) })
   precondition(api.queries.contains { $0.name=="branch" && $0.value=="feature/fix" })
   do { _ = try await api.workflowRuns("owner/repo",branch:"main",page:1,headSHA:"latest");preconditionFailure("invalid SHA accepted") } catch {}
   let sha=String(repeating:"b",count:40)
   api.payload=Data(("{\"workflow_runs\":[{\"id\":1,\"run_number\":1,\"head_sha\":\""+sha+"\",\"head_branch\":\"feature/fix\",\"status\":\"queued\",\"created_at\":\"2026-10-15T00:00:00Z\"},{\"id\":2,\"run_number\":2,\"head_sha\":\"other\",\"head_branch\":\"feature/fix\",\"status\":\"queued\",\"created_at\":\"2026-10-15T00:00:00Z\"}]}").utf8)
   let pinned=try await api.workflowRuns("owner/repo",branch:"feature/fix",page:1,headSHA:sha)
   precondition(pinned.map(\.id)==[1])
   let commitPath="/repos/owner/repo/git/commits/"+String(repeating:"a",count:40)
   let treePath="/repos/owner/repo/git/trees/tree-sha"
   api.payloads[commitPath]=Data(#"{"sha":"head","tree":{"sha":"tree-sha"}}"#.utf8)
   api.payloads[treePath]=Data(#"{"tree":[{"path":"源代码","mode":"040000","type":"tree","sha":"d"},{"path":"源代码/test.swift","mode":"100644","type":"blob","sha":"f","size":4},{"path":"linked","mode":"120000","type":"blob","sha":"l"},{"path":"module","mode":"160000","type":"commit","sha":"m"}],"truncated":false}"#.utf8)
   let entries=try await api.repositoryEntries("owner/repo",branch:"feature/search")
   precondition(api.branches.last=="feature/search" && entries.map(\.type)==["dir","file"])
   precondition(entries[1].path=="源代码/test.swift" && entries[1].sha=="f")
   precondition(api.queries.contains { $0.name=="recursive" && $0.value=="1" })
   api.payloads[treePath]=Data(#"{"tree":[],"truncated":true}"#.utf8)
   do { _=try await api.repositoryEntries("owner/repo",branch:"feature/search");preconditionFailure("partial tree accepted") } catch {}
   api.payloads=[:]
   _ = try await api.communityMutate("owner/repo",action:.comment(7),text:"reply")
   precondition(api.pushChecks==0 && api.method=="POST" && api.body["body"] as? String=="reply")
   let before=Fixture.count()
   do {_ = try await api.communityMutate("owner/repo",action:.merge(7,String(repeating:"b",count:40)));preconditionFailure()}catch{}
   precondition(Fixture.count()==before && api.pushChecks==1)
   api.push=true
   _ = try await api.communityMutate("owner/repo",action:.merge(7,String(repeating:"b",count:40)))
   precondition(api.body["sha"] as? String==String(repeating:"b",count:40) && api.method=="PUT")
    let beforeCancel=Fixture.count()
    var cancellation=WorkflowCancellationState()
    precondition(cancellation.begin() && !cancellation.begin(), "Repeated taps must not send another cancellation")
    Fixture.status=202
    _ = try await api.communityMutate("owner/repo",action:.cancelRun(10));precondition(api.pushChecks==3)
    cancellation.accepted()
    precondition(cancellation.waiting && cancellation.message.contains("已接受取消请求"))
    cancellation.observe(status:"in_progress",conclusion:nil)
    precondition(cancellation.waiting && !cancellation.begin(), "Acceptance is not completion")
    cancellation.observe(status:"completed",conclusion:"cancelled")
    precondition(!cancellation.waiting && cancellation.message=="运行已取消。")
    precondition(Fixture.count()==beforeCancel+1)
    for unexpected in [200,204,409] {
      Fixture.status=unexpected
      do {_ = try await api.communityMutate("owner/repo",action:.cancelRun(10));preconditionFailure("Cancel requires 202")}catch{}
    }
    var unknown=WorkflowCancellationState();precondition(unknown.begin())
    unknown.uncertain("连接中断")
    precondition(unknown.waiting && unknown.message.contains("尚未确认"))
    unknown.observe(status:"completed",conclusion:"success")
    precondition(!unknown.waiting && unknown.message.contains("成功") && !unknown.message.contains("已取消"))
    var delayed=WorkflowCancellationState();precondition(delayed.begin());delayed.accepted();delayed.stopWaiting()
    precondition(!delayed.waiting && !delayed.begin() && delayed.message.contains("刷新"))
    Fixture.status=200
   _ = try await api.communityMutate("owner/repo",action:.state(7,"closed"));precondition(api.body["state"] as? String=="closed")
   let beforeDelete=Fixture.count();api.push=false
   do {_ = try await api.communityMutate("owner/repo",action:.deleteRun(10));preconditionFailure()}catch{}
   precondition(Fixture.count()==beforeDelete);api.push=true
   api.payload=Data(#"{"status":"in_progress"}"#.utf8)
   do {_ = try await api.communityMutate("owner/repo",action:.deleteRun(10));preconditionFailure()}catch{}
   precondition(Fixture.count()==beforeDelete)
   api.payload=Data(#"{"status":"completed"}"#.utf8)
   Fixture.status=200
   do {_ = try await api.communityMutate("owner/repo",action:.deleteRun(10));preconditionFailure()}catch{}
   Fixture.status=204
   _ = try await api.communityMutate("owner/repo",action:.deleteRun(10))
   precondition(api.method=="DELETE")
   Fixture.lock.lock();let deletion=Fixture.seen.last!;Fixture.lock.unlock()
   precondition(deletion.url!.path=="/repos/owner/repo/actions/runs/10" && deletion.httpBody==nil)
   Fixture.status=200
   api.active=false;let inactive=Fixture.count()
   do {_ = try await api.communityMutate("owner/repo",action:.comment(7),text:"must not send");preconditionFailure()}catch{}
   precondition(Fixture.count()==inactive);api.active=true
   Fixture.status=403
   do {_ = try await api.communityMutate("owner/repo",action:.comment(7),text:"denied");preconditionFailure()}catch{}
   Fixture.status=200
   api.payload=Data(#"{"tree":[{"path":"a.swift","type":"blob","size":4},{"path":"huge.swift","type":"blob","size":999999}],"truncated":false}"#.utf8)
   let summary=try await api.codeLineSummary("owner/repo",branch:"main",progress:{_ in})
   precondition(summary.files==1 && summary.lines==2 && summary.skipped==1)
   let many=(0..<50).map { ["path":"invalid\($0).swift","type":"blob","size":4] as [String:Any] }
   api.payload=try JSONSerialization.data(withJSONObject:["tree":many,"truncated":false]);api.invalidContent=true;api.files=[]
   let invalid=try await api.codeLineSummary("owner/repo",branch:"main",progress:{_ in})
   precondition(api.files.count==40 && invalid.files==0 && invalid.skipped==50)
   let policy=WorkflowLogRedirectPolicy()
   let task=api.session.dataTask(with:URL(string:"https://api.github.com/")!)
   defer{task.cancel()}
   let response=HTTPURLResponse(url:URL(string:"https://api.github.com/")!,statusCode:302,httpVersion:nil,headerFields:nil)!
   var cdn=URLRequest(url:URL(string:"https://sample.blob.core.windows.net/log")!);cdn.setValue("secret",forHTTPHeaderField:"Authorization");cdn.setValue("secret",forHTTPHeaderField:"Cookie")
   policy.urlSession(api.session,task:task,willPerformHTTPRedirection:response,newRequest:cdn){clean in
     precondition(clean != nil && clean!.value(forHTTPHeaderField:"Authorization")==nil && clean!.value(forHTTPHeaderField:"Cookie")==nil)
   }
   policy.urlSession(api.session,task:task,willPerformHTTPRedirection:response,newRequest:URLRequest(url:URL(string:"https://example.com/log")!)){precondition($0==nil)}
   print("PASS native collaboration production transport: author comments, push-gated merge/actions, SHA pinning, inactive account/server denial; bounded fixed-head line counts, README folding and stripped CDN credentials. No live writes.")
 }
}
'''
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'main.swift';p.write_text(source)
            exe=str(Path(folder)/'test')
            subprocess.run(['swiftc','-parse-as-library',str(p),'-o',exe],check=True)
            subprocess.run([exe],check=True,timeout=30)

class WorkflowCancellationWiringTests(unittest.TestCase):
    def test_cancel_request_waits_for_terminal_state_without_repeated_post(self):
        view = (ROOT/'RepoPocket/WorkflowViews.swift').read_text(encoding='utf-8').split('struct WorkflowRunView: View {',1)[1].split('struct WorkflowJobView:',1)[0]
        self.assertIn('@State private var cancellation = WorkflowCancellationState()', view)
        self.assertIn('guard cancellation.begin() else { return }', view)
        self.assertIn('cancellation.accepted()', view)
        self.assertIn('cancellation.observe(status: value.status, conclusion: value.conclusion)', view)
        self.assertIn('cancellation.requested', view)
        self.assertIn('cancellation.message', view)
        self.assertIn('else { cancellation = WorkflowCancellationState(); message =', view)
        self.assertIn('scenePhase == .active', view)
        self.assertIn('Task.sleep(nanoseconds: 5_000_000_000)', view)
        self.assertIn('try Task.checkCancellation()', view)
        self.assertIn('api.isCurrentSession', view)
        self.assertNotIn('force-cancel', view)

    def test_transport_requires_github_cancel_acceptance(self):
        source = (ROOT/'RepoPocket/GitHub.swift').read_text(encoding='utf-8')
        mutation = source.split('    func communityMutate(',1)[1].split('    func communityStarDates(',1)[0]
        self.assertIn('if case .cancelRun = action, (response.1 as? HTTPURLResponse)?.statusCode != 202', mutation)


if __name__=='__main__':unittest.main()
