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
 var body:[String:Any]=[:]; var method="";var files:[String]=[];var invalidContent=false
 init(){let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[Fixture.self];session=URLSession(configuration:config)}
 var isCurrentSession:Bool {active}
 func ensureActiveAccount() throws {guard active else {throw CancellationError()}}
 func requireWriteAccess(_ repo:String) async throws {pushChecks+=1;guard push else {throw AppError(text:"denied")}}
 static func component(_ s:String)->String {s.addingPercentEncoding(withAllowedCharacters:.alphanumerics)!}
 static func repoPath(_ repo:String)throws->String {"/repos/" + (try RepositoryInput.parse(repo))}
 func url(_ path:String)throws->URL {URL(string:"https://api.github.com"+path)!}
 func request(_ url:URL,method:String,body:Data)throws->URLRequest {
   try ensureActiveAccount();self.method=method;self.body=(try JSONSerialization.jsonObject(with:body)) as! [String:Any]
   var r=URLRequest(url:url);r.httpMethod=method;r.httpBody=body;r.setValue("Bearer fixture-only",forHTTPHeaderField:"Authorization");return r
 }
 func check(_ data:Data,_ response:URLResponse,operation:String)throws {
   try ensureActiveAccount();guard let h=response as? HTTPURLResponse,(200..<300).contains(h.statusCode) else {throw AppError(text:"server denied")}
 }
 func communityRead(_ path:String,query:[URLQueryItem]=[])async throws->Data {try ensureActiveAccount();queries=query;return payload}
 func resolvedBranch(_ repo:String,branch:String)async throws->String {"main"}
 func workspaceHead(_ repo:String,branch:String)async throws->String {String(repeating:"a",count:40)}
 func file(_ repo:String,path:String,branch:String)async throws->Entry {
   precondition(branch==String(repeating:"a",count:40));files.append(path)
   return Entry(name:path,path:path,type:"file",sha:"x",size:4,download_url:nil,content:Data(invalidContent ? [0,1,2,3] : Array("a\nb\n".utf8)).base64EncodedString(),encoding:"base64")
 }
MUTATE
}
'''.replace('MUTATE', mutate)
        for name in ['RepositoryInput.swift','CommunityModels.swift','NativeRepositoryModels.swift','NativeRepositoryAPI.swift','OfficialUpdateRedirectPolicy.swift']:
            source += '\n' + ((models+'\n') if name=='RepositoryInput.swift' else '') + (ROOT/'RepoPocket'/name).read_text()
        source += (ROOT/'RepoPocket/RepositoryReadmeSection.swift').read_text().split('struct RepositoryReadmeSection')[0].replace('import SwiftUI','import Foundation')
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
   _ = try await api.communityMutate("owner/repo",action:.comment(7),text:"reply")
   precondition(api.pushChecks==0 && api.method=="POST" && api.body["body"] as? String=="reply")
   let before=Fixture.count()
   do {_ = try await api.communityMutate("owner/repo",action:.merge(7,String(repeating:"b",count:40)));preconditionFailure()}catch{}
   precondition(Fixture.count()==before && api.pushChecks==1)
   api.push=true
   _ = try await api.communityMutate("owner/repo",action:.merge(7,String(repeating:"b",count:40)))
   precondition(api.body["sha"] as? String==String(repeating:"b",count:40) && api.method=="PUT")
   _ = try await api.communityMutate("owner/repo",action:.cancelRun(10));precondition(api.pushChecks==3)
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

if __name__=='__main__':unittest.main()
