"""Owned-only metadata editing. Native fixtures never contact GitHub."""
from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]

class DescriptionTests(unittest.TestCase):
    def test_only_explicit_save_mutates_without_reloading_page_sections(self):
        ui = (ROOT/'RepoPocket/RepositoryDescriptionView.swift').read_text()
        app = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
        browser = app.split('struct BrowserView: View {', 1)[1].split('struct FileView:', 1)[0]
        self.assertIn('RepositoryDescriptionRules.canEdit(repositoryInfo, login: api.login, sessionMatches: api.isCurrentSession)', browser)
        callback = browser.split('.sheet(item: $repositoryDescriptionTarget)', 1)[1].split('.sheet(item: $repositoryDeletionTarget)', 1)[0]
        self.assertIn('repositoryInfo = updated', callback)
        for forbidden in ['load()', 'readmeState', 'homeRelease', 'homeRuns', '.task', '.onAppear', '.onChange']:
            self.assertNotIn(forbidden, callback + ui)
        self.assertEqual(ui.count('api.updateRepositoryDescription('), 1)
        self.assertIn('guard canSave else { return }', ui)
        self.assertIn('interactiveDismissDisabled(busy)', ui)
        self.assertIn('saveTask?.cancel()', ui)
        self.assertIn('errorMessage = error.localizedDescription', ui)
        self.assertIn('State(initialValue: target.repository.description ?? "")', ui)
        self.assertIn('Button("保存") { save() }', ui)

    def test_description_patch_is_isolated_from_file_write_gate_and_global_refresh(self):
        api = (ROOT/'RepoPocket/GitHub.swift').read_text()
        body = api.split('    func updateRepositoryDescription(', 1)[1].split('    func deletionContext(', 1)[0]
        self.assertIn('["description": value]', body)
        self.assertIn('method: "PATCH"', body)
        self.assertIn('statusCode == 200', body)
        self.assertIn('RepositoryDescriptionRules.execute', body)
        self.assertIn('try self.ensureActiveAccount()', body)
        for forbidden in ['requireWriteAccess', 'starRevision', 'object:', 'FileManager']:
            self.assertNotIn(forbidden, body)
        project = (ROOT/'project.yml').read_text()
        self.assertIn('MARKETING_VERSION: "1.0.6"', project)
        workflow = (ROOT/'.github/workflows/build.yml').read_text()
        self.assertIn('zip -qry RepoPocket.ipa Payload', workflow)
        self.assertNotIn('RepoPocket-1.1.1', workflow)

    @unittest.skipUnless(shutil.which('swiftc'), 'native permission/race fixtures run on macOS')
    def test_permission_and_account_races_with_production_rules(self):
        api = (ROOT/'RepoPocket/GitHub.swift').read_text()
        models = api[api.index('struct User:'):api.index('struct Entry:')]
        error = api[api.index('struct AppError:'):api.index('struct GitHubAPIError:')]
        core = (ROOT/'RepoPocket/RepositoryDescription.swift').read_text()
        source = 'import Foundation\n' + error + models + core + r'''
struct FixtureError: Error {}
@main struct Run {
 static func main() async throws {
  func repo(_ id: Int = 7, _ name: String = "alice/tool", _ owner: String? = "alice", _ admin: Bool? = true, _ text: String? = "old") throws -> Repository {
   var object: [String:Any] = ["id":id,"full_name":name,"name":"tool","html_url":"https://github.com/"+name]
   if let owner {object["owner"] = ["login":owner]}
   if let admin {object["permissions"] = ["admin":admin,"push":false]}
   if let text {object["description"] = text}
   return try JSONDecoder().decode(Repository.self, from: JSONSerialization.data(withJSONObject:object))
  }
  let fresh = try repo()
  precondition(RepositoryDescriptionRules.canEdit(fresh,login:"alice",sessionMatches:true))
  precondition(RepositoryDescriptionRules.canEdit(fresh,login:"ALICE",sessionMatches:true))
  for login in ["", "bob"] {precondition(!RepositoryDescriptionRules.canEdit(fresh,login:login,sessionMatches:true))}
  precondition(!RepositoryDescriptionRules.canEdit(fresh,login:"alice",sessionMatches:false))
  for bad in [try repo(7,"bob/tool","bob"),try repo(7,"alice/tool",nil),try repo(7,"alice/tool","alice",false),try repo(7,"alice/tool","alice",nil),try repo(7,"bob/tool","alice")] {
   precondition(!RepositoryDescriptionRules.canEdit(bad,login:"alice",sessionMatches:true))
  }
  let context = RepositoryDescriptionContext(accountID:"A",generation:UUID(),login:"alice",repositoryID:7,fullName:"alice/tool")
  var current = context
  let switched = RepositoryDescriptionContext(accountID:"B",generation:UUID(),login:"bob",repositoryID:7,fullName:"alice/tool")
  var reads = 0, writes = 0
  current = switched
  do {
   _ = try await RepositoryDescriptionRules.execute(context:context,description:"new",current:{current},fetch:{reads+=1;return fresh},update:{_ in writes+=1;return fresh})
   preconditionFailure("stale session mutated")
  } catch {precondition(reads==0 && writes==0)}
  current = context
  for bad in [try repo(8),try repo(7,"alice/renamed"),try repo(7,"bob/tool","bob"),try repo(7,"alice/tool","alice",false),try repo(7,"alice/tool","alice",nil)] {
   do {
    _ = try await RepositoryDescriptionRules.execute(context:context,description:"new",current:{current},fetch:{bad},update:{_ in writes+=1;return fresh})
    preconditionFailure("changed target/permission mutated")
   } catch {precondition(writes==0)}
  }
  do {
   _ = try await RepositoryDescriptionRules.execute(context:context,description:"new",current:{current},fetch:{current=switched;return fresh},update:{_ in writes+=1;return fresh})
   preconditionFailure("switch during permission read mutated")
  } catch {precondition(writes==0)}
  current = context
  // Description alone changes; empty text explicitly clears, including old nil.
  for text in ["new 描述", "", "  whitespace  "] {
   let expected = try repo(7,"alice/tool","alice",true,text)
   let result = try await RepositoryDescriptionRules.execute(context:context,description:text,current:{current},fetch:{fresh},update:{value in precondition(value==text);writes+=1;return expected})
   precondition(result.description==text)
  }
  precondition(writes==3)
  do {
   _ = try await RepositoryDescriptionRules.execute(context:context,description:"new",current:{current},fetch:{fresh},update:{_ in current=switched;return fresh})
   preconditionFailure("stale response published")
  } catch {}
  current = context
  do {
   _ = try await RepositoryDescriptionRules.execute(context:context,description:"new",current:{current},fetch:{fresh},update:{_ in try repo(9)})
   preconditionFailure("wrong response published")
  } catch {}
  do {
   _ = try await RepositoryDescriptionRules.execute(context:context,description:"new",current:{current},fetch:{fresh},update:{_ in throw FixtureError()})
   preconditionFailure("HTTP error swallowed")
  } catch {}
  let cancellation = Task {
   try await RepositoryDescriptionRules.execute(context:context,description:"new",current:{context},fetch:{withUnsafeCurrentTask{$0?.cancel()};return fresh},update:{_ in preconditionFailure("cancelled request mutated")})
  }
  do { _ = try await cancellation.value; preconditionFailure("cancel bypass") } catch is CancellationError {} catch {preconditionFailure("unexpected error")}
  print("PASS owner/admin gates, account and permission races, exact mutation, clearing, errors, cancellation, stale responses")
 }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'fixture.swift'
            path.write_text(source, encoding='utf-8')
            binary = Path(directory)/'fixture'
            subprocess.run(['swiftc','-parse-as-library',str(path),'-o',str(binary)],check=True)
            subprocess.run([str(binary)],check=True)

if __name__ == '__main__': unittest.main()
