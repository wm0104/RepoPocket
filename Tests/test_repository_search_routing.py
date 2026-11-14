from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]

class SearchRoutingTests(unittest.TestCase):
    def test_code_search_preserves_account_request_and_file_routes(self):
        ui = (ROOT/'RepoPocket/RepositorySearchView.swift').read_text()
        rules = (ROOT/'RepoPocket/RepositorySearchRules.swift').read_text()
        api = (ROOT/'RepoPocket/GitHub.swift').read_text()
        self.assertIn('case repositories, users, code', rules)
        self.assertIn('Text("代码").tag(RepositorySearchKind.code)', ui)
        self.assertIn('if selected != .code, let target = RepositorySearchRouting.repository(clean)', ui)
        self.assertIn('RepositorySearchRouting.isLink(clean) ? .code : selected', ui)
        self.assertIn('api.searchCode(requested, page: requestedPage)', ui)
        self.assertIn('ReadingLinkDestination(url: $0.url, api: api)', ui)
        self.assertIn('codeResults.isEmpty', ui)
        self.assertIn('incomplete_results', ui)
        method = api.split('func searchCode(', 1)[1].split('    // Read-only gateway', 1)[0]
        for token in ['request(endpoint)', 'application/vnd.github.text-match+json',
                      'GitHubAPIRedirectPolicy()', 'try check(bytes, response)',
                      '8 * 1024 * 1024', 'Task.detached', 'worker.cancel()',
                      'try Task.checkCancellation(); try ensureActiveAccount()']:
            self.assertIn(token, method)
        self.assertNotIn('RepositoryInput.parse', method)

    def test_code_results_use_pinned_file_links_not_blob_sha_as_ref(self):
        rules = (ROOT/'RepoPocket/RepositorySearchRules.swift').read_text()
        ui = (ROOT/'RepoPocket/RepositorySearchView.swift').read_text()
        for token in ['struct CodeSearchResponse', 'struct CodeSearchResult', 'struct CodeSearchMatch',
                      'let incomplete_results: Bool', 'var fileURL: URL?', 'let html_url: String',
                      'repository.id', 'text_matches']:
            self.assertIn(token, rules)
        self.assertIn('ReadingLink(url: url)', ui)
        self.assertIn('CodeSearchResultRow(item: item)', ui)
        self.assertIn('仅搜索 GitHub 已索引的默认分支内容', ui)
        self.assertNotIn('branch: item.sha', ui)
        self.assertNotIn('ref: item.sha', ui)

    @unittest.skipUnless(shutil.which('swiftc'), 'Native Swift runs on macOS')
    def test_production_code_search_models_and_safe_links(self):
        api = (ROOT/'RepoPocket/GitHub.swift').read_text()
        models = api[api.index('struct User:'):api.index('struct Entry:')]
        source = 'import Foundation\n' + models + (ROOT/'RepoPocket/RepositorySearchRules.swift').read_text() + r'''
let query = "https://wm0104.github.io/repo/#中文?a=1&b=2"
let endpoint = RepositorySearchRules.endpoint(kind: .code, query: query, page: 2,
    options: RepositorySearchOptions(language: "Swift", sort: .stars, ascending: true))
let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
precondition(endpoint.path == "/search/code")
precondition(parts.queryItems!.first { $0.name == "q" }!.value == query)
precondition(!parts.queryItems!.contains { ["sort", "order"].contains($0.name) })
precondition(parts.queryItems!.first { $0.name == "page" }!.value == "2")
let raw = #"""
{"total_count":1,"incomplete_results":true,"items":[
 {"name":"文档.md","path":"docs/文档.md","sha":"blob-not-commit",
  "html_url":"https://github.com/wm0104/repo/blob/0123456789abcdef/docs/%E6%96%87%E6%A1%A3.md",
  "repository":{"id":7,"full_name":"wm0104/repo","name":"repo","html_url":"https://github.com/wm0104/repo"},
  "text_matches":[{"property":"content","fragment":"😀 中文 https://wm0104.github.io/repo/",
   "matches":[{"text":"https://wm0104.github.io/repo/","indices":[5,34]}]}]}]}
"""#
let result = try JSONDecoder().decode(CodeSearchResponse.self, from: Data(raw.utf8))
precondition(result.incomplete_results && result.items.count == 1)
let item = result.items[0]
precondition(item.fileURL!.absoluteString.contains("/blob/0123456789abcdef/"))
precondition(item.text_matches![0].fragment.hasPrefix("😀 中文"))
let changed = raw.replacingOccurrences(of: "blob-not-commit", with: "other-blob")
let updated = try JSONDecoder().decode(CodeSearchResponse.self, from: Data(changed.utf8))
precondition(updated.items[0].id == item.id)
let suffix = "/wm0104/repo/blob/main/docs/%E6%96%87%E6%A1%A3.md"
let badLinks = ["http://github.com", "https://evil.example", "https://github.com.evil",
    "https://user@github.com", "https://github.com:444"].map { $0 + suffix }
    + ["https://github.com/other/repo/blob/main/docs/%E6%96%87%E6%A1%A3.md",
       "https://github.com/wm0104/repo/tree/main/docs/%E6%96%87%E6%A1%A3.md",
       "https://github.com" + suffix + "?token=x", "https://github.com/wm0104/repo/blob/main/wrong.txt"]
for bad in badLinks {
 var json = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
 var rows = json["items"] as! [[String: Any]]; rows[0]["html_url"] = bad; json["items"] = rows
 let decoded = try JSONDecoder().decode(CodeSearchResponse.self, from: JSONSerialization.data(withJSONObject: json))
 precondition(decoded.items[0].fileURL == nil, bad)
}
print("PASS: production code query encoding, incomplete results, Unicode snippets, stable IDs and safe pinned file URLs")
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'main.swift'; path.write_text(source)
            subprocess.run(['swiftc',str(path),'-o',folder+'/test'],check=True)
            subprocess.run([folder+'/test'],check=True)

    def test_search_submission_and_owner_destination(self):
        ui = (ROOT/'RepoPocket/RepositorySearchView.swift').read_text()
        self.assertIn('RepositorySearchRouting.repository(clean)', ui)
        self.assertIn('.onSubmit(of: .search) { begin(kind) }', ui)
        self.assertIn('Picker("搜索类型"', ui)
        self.assertIn('directRepository = target', ui)
        app = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
        self.assertIn('openOwner: { showingRepositoryOwner = true }', app)
        self.assertIn('UserRepositoriesView(api: api, user:', app)
        self.assertIn('repositoryInfo.owner?.login', app)
        cards = (ROOT/'RepoPocket/RepositoryUI.swift').read_text()
        self.assertIn('openOwner ?? { showOwnerProfile = true }', cards)
        self.assertIn('UserRepositoriesView(api: api, user: ownerProfile)', cards)
        issues = (ROOT/'RepoPocket/CollaborationViews.swift').read_text()
        self.assertIn('CommunityAuthorLink(api: api, user: item.user, opensInSheet: true)', issues)
        self.assertIn('issue-list-author-', issues)
        social = (ROOT/'RepoPocket/RepositorySocial.swift').read_text()
        self.assertIn('CommunityAuthorLink(api: api, user: forkUser(fork), opensInSheet: true)', social)

    @unittest.skipUnless(shutil.which('swiftc'), 'Native Swift runs on macOS')
    def test_production_route_validation(self):
        source = '\n'.join((ROOT/'RepoPocket'/n).read_text() for n in ['RepositoryInput.swift','RepositorySearchRouting.swift'])
        source += r'''
precondition(RepositorySearchRouting.repository(" https://github.com/Jond-ie/triggr-beta ") == "Jond-ie/triggr-beta")
precondition(RepositorySearchRouting.repository("github.com/opa334/Dopamine.git/") == "opa334/Dopamine")
precondition(RepositorySearchRouting.repository("opa334/Dopamine") == "opa334/Dopamine")
for bad in ["opa334", "Dopamine language:Swift", "https://evil.example/opa334/Dopamine", "https://github.com.evil/opa334/Dopamine", "https://user@github.com/opa334/Dopamine", "https://github.com/opa334/Dopamine/tree/main", "https://github.com/opa334/Dopamine?token=secret"] {
 precondition(RepositorySearchRouting.repository(bad) == nil)
}
precondition(RepositorySearchRouting.isLink("https://github.com/opa334/Dopamine/tree/main"))
precondition(!RepositorySearchRouting.isLink("opa334"))
print("PASS production direct repository routing and strict URL boundaries")
'''
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'main.swift'; path.write_text(source)
            subprocess.run(['swiftc',str(path),'-o',folder+'/test'],check=True)
            subprocess.run([folder+'/test'],check=True)

if __name__ == '__main__': unittest.main()
