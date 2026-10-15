"""Exercise production read API routing, optional GitHub payloads, pagination
isolation, readme bounds, encoded filters and OAuth validation without a network."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('swiftc'), 'production Swift tests run on macOS CI')
class CommunityTests(unittest.TestCase):
    def test_production_community(self):
        source = (ROOT/'RepoPocket/GitHub.swift').read_text()
        models = source[source.index('struct User: Decodable'):source.index('struct Release: Decodable')]
        oauth = (ROOT/'RepoPocket/DeviceOAuth.swift').read_text()
        program = '''import Foundation
import Combine
struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
enum RefreshFailure { static func isCancellation(_ error: Error) -> Bool { error is CancellationError } }
@MainActor final class GitHub {
 var isCurrentSession = true
 var calls: [(String, [URLQueryItem])] = []
 var payload = Data("[]".utf8)
 var added: [String] = []
 var accountErrors: [Error] = []
 var accountAttempts = 0
 func addAccount(token: String) async throws {
   try Task.checkCancellation(); guard isCurrentSession else { throw CancellationError() }
   accountAttempts += 1
   if !accountErrors.isEmpty { throw accountErrors.removeFirst() }
   added.append(token)
 }
 static func component(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
 static func repoPath(_ repo: String) throws -> String { "/repos/" + (try RepositoryInput.parse(repo)) }
 func communityRead(_ path: String, query: [URLQueryItem]) async throws -> Data {
   calls.append((path, query)); return payload
 }
}
'''+models+'\n'+(ROOT/'RepoPocket/RepositoryInput.swift').read_text()+'\n'+(ROOT/'RepoPocket/DesktopModels.swift').read_text()+'\n'+(ROOT/'RepoPocket/RepositorySearchRules.swift').read_text()+'\n'+(ROOT/'RepoPocket/CommunityModels.swift').read_text()+'\n'+(ROOT/'RepoPocket/CommunityAPI.swift').read_text()+'\n'+(ROOT/'RepoPocket/CommunityPaging.swift').read_text()+'\n'+oauth+r'''
struct Row: Identifiable { let id: Int }
enum SampleError: Error { case offline }
final class OAuthFixtureProtocol: URLProtocol {
 private static let lock = NSLock()
 private static var payloads: [Data] = []
 private static var recorded: [URLRequest] = []
 static func reset(_ values: [String]) { lock.lock(); defer { lock.unlock() }; payloads=values.map { Data($0.utf8) }; recorded=[] }
 static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
 private static func next(_ request: URLRequest) -> Data {
   lock.lock(); defer { lock.unlock() }; recorded.append(request)
   return payloads.isEmpty ? Data(#"{"error":"access_denied"}"#.utf8) : payloads.removeFirst()
 }
 override class func canInit(with request: URLRequest) -> Bool { true }
 override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
 override func startLoading() {
   let data=Self.next(request)
   if let code = Int(String(decoding:data,as:UTF8.self)) {
     client?.urlProtocol(self,didFailWithError:URLError(URLError.Code(rawValue:code))); return
   }
   client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
   client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading() {}
}
@main struct Run {
 @MainActor static func drain(_ store: CommunityPageStore<Row>) async { while store.busy { await Task.yield() } }
 @MainActor static func drainOAuth(_ controller: DeviceOAuthController) async { while controller.busy { await Task.yield() } }
 @MainActor static func main() async throws {
   let decoder = JSONDecoder()
   let api = GitHub()
   let minimal = Data(#"{"id":1,"number":2,"title":"例子","state":"open","html_url":"https://github.com/o/r/issues/2"}"#.utf8)
   let issue = try decoder.decode(CollaborationItem.self, from: minimal)
   precondition(issue.user == nil && issue.body == nil && issue.pull_request == nil)
   api.payload = Data(("[" + String(decoding:minimal,as:UTF8.self) + "]").utf8)
   let issues = try await api.collaborationItems("o/r", kind: .issues, state: "all", page: 2)
   precondition(issues.count == 1 && api.calls.last!.0 == "/repos/o/r/issues")
   precondition(api.calls.last!.1.contains { $0.name == "page" && $0.value == "2" })
   do { _ = try await api.collaborationItems("o/r", kind:.issues,state:"bad",page:1); preconditionFailure() } catch {}
   do { _ = try CommunityRules.page(11); preconditionFailure() } catch {}
   api.payload = Data("[]".utf8)
   _ = try await api.collaborationComments("o/r", number: 2, stream: .conversation, page: 1)
   precondition(api.calls.last!.0 == "/repos/o/r/issues/2/comments")
   _ = try await api.collaborationComments("o/r", number: 2, stream: .reviews, page: 1)
   precondition(api.calls.last!.0 == "/repos/o/r/pulls/2/reviews")
   _ = try await api.collaborationComments("o/r", number: 2, stream: .inline, page: 1)
   precondition(api.calls.last!.0 == "/repos/o/r/pulls/2/comments")
   _ = try await api.pullFiles("o/r", number: 2, page: 1)
   precondition(api.calls.last!.0 == "/repos/o/r/pulls/2/files")
   api.payload = Data()
   let emptyContributors = try await api.contributors("o/r",page:1)
   precondition(emptyContributors.isEmpty)
   do { _ = try await api.pullFiles("o/r", number: -1, page:1); preconditionFailure() } catch {}
   let readme = Entry(name:"README.md",path:"docs/README.md",type:"file",sha:"abc",size:3,download_url:nil,content:Data("中文".utf8).base64EncodedString(),encoding:"base64")
   precondition(try CommunityRules.readmeText(readme) == "中文")
   let binary = Entry(name:"README.md",path:"README.md",type:"file",sha:"x",size:2,download_url:nil,content:Data([0,1]).base64EncodedString(),encoding:"base64")
   do { _ = try CommunityRules.readmeText(binary); preconditionFailure() } catch {}
   let huge = Entry(name:"README.md",path:"README.md",type:"file",sha:"x",size:999999,download_url:nil,content:"YQ==",encoding:"base64")
   do { _ = try CommunityRules.readmeText(huge); preconditionFailure() } catch {}
   for url in ["javascript:alert(1)","file:///tmp/x","http://github.com","https://user:password@github.com"] {
     precondition(CommunityRules.webURL(url) == nil)
   }
   let base = CommunityRules.readingBase("o/r",branch:"feature/a",file:"文 档/README.md",raw:true)!
   precondition(base.host == "raw.githubusercontent.com" && base.absoluteString.contains("%20"))
   let rootBase = CommunityRules.readingBase("o/r",branch:"main",file:"README.md",raw:false)!
   precondition(rootBase.absoluteString == "https://github.com/o/r/blob/main/README.md")
   precondition(URL(string:"#heading",relativeTo:rootBase)!.absoluteURL.absoluteString == "https://github.com/o/r/blob/main/README.md#heading")
   let sample = "let 中文 = \"if 12\" // return 30\nvar n = 42"
   let tokens = SourceLexer.tokens(sample,hashComments:false)
   let words = tokens.map { (sample as NSString).substring(with:$0.range) }
   precondition(words == ["let","\"if 12\"","// return 30","var","42"])
   let pathological = "/*" + String(repeating:"a/*",count:32000)
   let start = Date()
   precondition(SourceLexer.tokens(pathological,hashComments:false).count == 1)
   precondition(Date().timeIntervalSince(start) < 3)
   let hashTokens = SourceLexer.tokens("# if 3\nreturn 4",hashComments:true)
   precondition(hashTokens.count == 3)
   let options = RepositorySearchOptions(language:"C++",sort:.stars,ascending:true)
   let endpoint = RepositorySearchRules.endpoint(kind:.repositories,query:"a&b 中文",page:2,options:options)
   let params = URLComponents(url:endpoint,resolvingAgainstBaseURL:false)!.queryItems!
   precondition(params.first!.value == "a&b 中文 language:\"C++\"")
   precondition(params.contains { $0.name == "order" && $0.value == "asc" })
   let userEndpoint = RepositorySearchRules.endpoint(kind:.users,query:"name",page:1,options:options)
   precondition(!userEndpoint.absoluteString.contains("language") && !userEndpoint.absoluteString.contains("sort="))
   precondition(try DeviceOAuthRules.clientID(" abc_123 ") == "abc_123")
   for invalid in ["", "a b", "bad&client", "中文"] {
     do { _ = try DeviceOAuthRules.clientID(invalid); preconditionFailure() } catch {}
   }
   let form = String(decoding:DeviceOAuthRules.form(["code":"a+b&?中文"]),as:UTF8.self)
   precondition(form.contains("%2B") && form.contains("%26") && !form.contains("中文"))
   let code = DeviceAuthorization(device_code:"private",user_code:"AB-CD",verification_uri:"https://github.com/login/device",expires_in:900,interval:5)
   precondition(try DeviceOAuthRules.validate(code).host == "github.com")
   let phish = DeviceAuthorization(device_code:"private",user_code:"AB-CD",verification_uri:"https://example.com/login/device",expires_in:900,interval:5)
   do { _ = try DeviceOAuthRules.validate(phish); preconditionFailure() } catch {}
   let store = CommunityPageStore<Row>()
   var pages: [Int] = []
   store.load(api:api) { pages.append($0); return (0..<30).map { Row(id:$0) } }
   await drain(store); precondition(store.items.count == 30 && store.more)
   store.load(api:api) { pages.append($0); throw SampleError.offline }
   await drain(store); precondition(store.items.count == 30 && !store.error.isEmpty && store.more)
   store.load(api:api) { pages.append($0); return [Row(id:29),Row(id:30),Row(id:30)] }
   await drain(store); precondition(pages == [1,2,2] && store.items.count == 31 && !store.more && store.error.isEmpty)
   var continuation: CheckedContinuation<[Row], Never>?
   store.load(reset:true,api:api) { _ in await withCheckedContinuation { continuation = $0 } }
   while continuation == nil { await Task.yield() }
   store.cancel()
   store.load(reset:true,api:api) { _ in [Row(id:99)] }
   await drain(store); continuation!.resume(returning:[Row(id:1)])
   for _ in 0..<10 { await Task.yield() }
   precondition(store.items.map { $0.id } == [99])
   store.load(reset:true,api:api) { _ in api.isCurrentSession=false; return [Row(id:100)] }
   await drain(store); precondition(store.items.isEmpty)
   api.isCurrentSession=true
   for page in 1...10 {
     store.load(reset:page==1,api:api) { p in (0..<30).map { Row(id:p*100+$0) } }
     await drain(store)
   }
   precondition(store.items.count == 300 && store.limited && !store.more)
   let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[OAuthFixtureProtocol.self]
   let session=URLSession(configuration:config)
   defer { session.invalidateAndCancel() }
   let device=#"{"device_code":"fixture-device","user_code":"AA-BB","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
   OAuthFixtureProtocol.reset([device,#"{"error":"authorization_pending"}"#,#"{"error":"slow_down","interval":10}"#,#"{"access_token":"fixture-token","token_type":"bearer"}"#])
   let oauthAPI=GitHub(); var delays:[UInt64]=[]; var completions=0
   let controller=DeviceOAuthController(session:session,wait:{ delays.append($0) })
   controller.start(clientID:"testclient",privateRepositories:false,api:oauthAPI) { completions += 1 }
   await drainOAuth(controller)
   precondition(oauthAPI.added == ["fixture-token"] && completions == 1)
   precondition(delays == [5_000_000_000,5_000_000_000,10_000_000_000])
   precondition(controller.userCode.isEmpty && controller.verificationURL == nil)
   let requests=OAuthFixtureProtocol.requests()
   precondition(requests.map { $0.url!.path } == ["/login/device/code","/login/oauth/access_token","/login/oauth/access_token","/login/oauth/access_token"])
   precondition(requests.allSatisfy { $0.value(forHTTPHeaderField:"Authorization") == nil && $0.httpMethod == "POST" && $0.url!.host == "github.com" })
   OAuthFixtureProtocol.reset([device,#"{"error":"access_denied"}"#])
   controller.start(clientID:"testclient",privateRepositories:true,api:oauthAPI) { completions += 1 }
   await drainOAuth(controller)
   precondition(oauthAPI.added.count == 1 && completions == 1 && controller.message.contains("取消"))
   OAuthFixtureProtocol.reset([device,#"{"access_token":"must-not-save","token_type":"bearer"}"#])
   var resume:CheckedContinuation<Void,Error>?
   let cancelController=DeviceOAuthController(session:session,wait:{ _ in try await withCheckedThrowingContinuation { resume=$0 } })
   cancelController.start(clientID:"testclient",privateRepositories:false,api:oauthAPI) { completions += 1 }
   while resume == nil { await Task.yield() }
   cancelController.cancel(); resume!.resume()
   for _ in 0..<30 { await Task.yield() }
   precondition(oauthAPI.added.count == 1 && completions == 1 && !cancelController.busy && cancelController.userCode.isEmpty)
   precondition(OAuthFixtureProtocol.requests().count == 1)
   // Reproduce the video: browser succeeds while a polling connection is lost.
   let success = #"{"access_token":"recovered-token","token_type":"bearer"}"#
   let recoveryAPI = GitHub(); var recoveryDelays: [UInt64] = []; var recovered = 0
   let recovery = DeviceOAuthController(session:session,wait:{ recoveryDelays.append($0) })
   OAuthFixtureProtocol.reset([device,"-1005",success])
   recovery.start(clientID:"testclient",privateRepositories:false,api:recoveryAPI) { recovered += 1 }
   await drainOAuth(recovery)
   precondition(recoveryAPI.added == ["recovered-token"] && recovered == 1,
                "A temporary lost connection must not discard an authorized device flow")
   precondition(recoveryDelays == [5_000_000_000,10_000_000_000])
   precondition(OAuthFixtureProtocol.requests().count == 3)

   // Once a token arrives, retry account validation with the same token, never exchange it twice.
   let validationAPI = GitHub(); validationAPI.accountErrors = [URLError(.networkConnectionLost)]
   var validationDelays: [UInt64] = []; var validated = 0
   let validation = DeviceOAuthController(session:session,wait:{ validationDelays.append($0) })
   OAuthFixtureProtocol.reset([device,success])
   validation.start(clientID:"testclient",privateRepositories:false,api:validationAPI) { validated += 1 }
   await drainOAuth(validation)
   precondition(validationAPI.added == ["recovered-token"] && validated == 1)
   precondition(validationAPI.accountAttempts == 2 && OAuthFixtureProtocol.requests().count == 2)
   precondition(validationDelays == [5_000_000_000,2_000_000_000])

   // Bound recovery, and do not retry permanent login/permission failures.
   let boundedAPI = GitHub(); var boundedDelays: [UInt64] = []
   let bounded = DeviceOAuthController(session:session,wait:{ boundedDelays.append($0) })
   OAuthFixtureProtocol.reset([device,"-1005","-1005","-1005","-1005",success])
   bounded.start(clientID:"testclient",privateRepositories:false,api:boundedAPI) { preconditionFailure() }
   await drainOAuth(bounded)
   precondition(boundedAPI.added.isEmpty && OAuthFixtureProtocol.requests().count == 5)
   precondition(boundedDelays == [5_000_000_000,10_000_000_000,20_000_000_000,40_000_000_000])
   precondition(bounded.message.contains("网络") && bounded.userCode.isEmpty)
   let deniedAPI = GitHub(); deniedAPI.accountErrors = [AppError(text:"HTTP 401")]
   let denied = DeviceOAuthController(session:session,wait:{ _ in })
   OAuthFixtureProtocol.reset([device,success])
   denied.start(clientID:"testclient",privateRepositories:false,api:deniedAPI) { preconditionFailure() }
   await drainOAuth(denied)
   precondition(deniedAPI.accountAttempts == 1 && deniedAPI.added.isEmpty && denied.message == "HTTP 401")

   // Cancelling or changing accounts during recovery must prevent subsequent requests/saves.
   for switchAccount in [false,true] {
     let isolatedAPI = GitHub(); var pending: CheckedContinuation<Void,Error>?
     let isolated = DeviceOAuthController(session:session,wait:{ delay in
       if delay == 10_000_000_000 { try await withCheckedThrowingContinuation { pending = $0 } }
     })
     OAuthFixtureProtocol.reset([device,"-1005",success])
     isolated.start(clientID:"testclient",privateRepositories:false,api:isolatedAPI) { preconditionFailure() }
     while pending == nil && isolated.busy { await Task.yield() }
     precondition(pending != nil)
     if switchAccount { isolatedAPI.isCurrentSession = false } else { isolated.cancel() }
     pending!.resume()
     await drainOAuth(isolated)
     for _ in 0..<20 { await Task.yield() }
     precondition(isolatedAPI.added.isEmpty && OAuthFixtureProtocol.requests().count == 2)
   }
   print("PASS OAuth transient polling and account-validation recovery, bounded retry, cancellation and session isolation")
   print("PASS production community API routing, optional payloads, README limits, filter encoding, OAuth validation, pagination retry/dedup/cancel/account isolation/bounds")
   print("PASS production device OAuth via URLProtocol: pending, slow_down, success, denial, cancellation, no Authorization header or real GitHub traffic")
 }
}
'''
        # Throwing expressions cannot be evaluated by precondition's nonthrowing autoclosure.
        program = program.replace('@main struct Run {', (ROOT/'RepoPocket/SourceLexer.swift').read_text() + '\n@main struct Run {')
        program = program.replace('precondition(try CommunityRules.readmeText(readme) == "中文")', 'let read = try CommunityRules.readmeText(readme); precondition(read == "中文")')
        program = program.replace('precondition(try DeviceOAuthRules.clientID(" abc_123 ") == "abc_123")', 'let client = try DeviceOAuthRules.clientID(" abc_123 "); precondition(client == "abc_123")')
        program = program.replace('precondition(try DeviceOAuthRules.validate(code).host == "github.com")', 'let verification = try DeviceOAuthRules.validate(code); precondition(verification.host == "github.com")')
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'main.swift'
            path.write_text(program)
            executable = str(Path(folder)/'tests')
            subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', executable], check=True)
            subprocess.run([executable], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
