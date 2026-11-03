"""Mobile editor integration contracts and production UTF-16 edit fixtures."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MobileEditorTests(unittest.TestCase):
    def source(self, name):
        return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')

    def test_shared_editor_uses_native_find_and_guarded_edit_commands(self):
        view = self.source('SourceCodeView.swift')
        surface = self.source('SourceTextSurface.swift')
        self.assertIn('findRequest', view)
        self.assertIn('isFindInteractionEnabled = true', surface)
        self.assertIn('presentFindNavigator(showingReplace: textView.isEditable)', surface)
        self.assertIn('textView.markedTextRange == nil', surface)
        self.assertIn('SourceEditRules.newline', surface)
        self.assertIn('SourceEditRules.indent', surface)
        self.assertIn('undoManager?.undo()', surface)
        self.assertIn('undoManager?.redo()', surface)

    def test_local_save_stays_open_and_dirty_close_requires_a_choice(self):
        source = self.source('LocalProjectEditor.swift')
        self.assertIn('interactiveDismissDisabled(busy || dirty)', source)
        self.assertIn('保存后关闭', source)
        self.assertIn('放弃修改', source)
        self.assertIn('继续编辑', source)
        self.assertIn('originalText = value', source)
        self.assertIn('LocalGitFileAccess.fingerprint(Data(value.utf8))', source)
        self.assertNotIn('changed(); dismiss()', source)
        self.assertIn('新建文件', source)
        self.assertIn('新建文件夹', source)
        self.assertIn('LocalGitFileAccess.create', source)

    def test_name_search_does_not_download_workspace_or_accept_partial_tree(self):
        source = self.source('RepositoryFileSearch.swift')
        self.assertIn('DirectoryBrowserDestination', source)
        self.assertIn('FileView(', source)
        self.assertIn('!tree.truncated', source)
        self.assertIn('tree.tree.count <= 20000', source)
        self.assertIn('recursive', source)
        self.assertNotIn('fetchWorkspace(', source)
        self.assertIn('RepositoryFileSearchView', self.source('RepoPocketApp.swift'))

    def test_search_commit_decoder_accepts_github_iso8601_dates(self):
        source = self.source('RepositoryFileSearch.swift')
        self.assertIn('decoder.dateDecodingStrategy = .iso8601', source)
        self.assertIn('decoder.decode(GitCommitInfo.self, from: commitBytes)', source)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production remote search fixture runs on macOS')
    def test_remote_search_real_api_shapes_and_limits(self):
        # Reduced verbatim fields from GitHub REST docs: git/commits vs commits.
        # The live octocat/Hello-World master read was also checked via read-only MCP.
        source = self.source('RepositoryFileSearch.swift').split('extension GitHub {', 1)[1]
        models = self.source('WorkspaceRemote.swift').split('struct GitObject:', 1)[1].split('extension LocalStore {', 1)[0]
        github = self.source('GitHub.swift')
        component = github.split('    static func component(', 1)[1].split('    private func url(', 1)[0]
        head = github.split('    func workspaceHead(', 1)[1].split('    func associateWorkspace(', 1)[0]
        fixture = r'''
import Foundation
struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
struct Entry { let name: String; let path: String; let type: String; let sha: String; let size: Int?; let download_url: String?; let content: String?; let encoding: String? }
enum RepositoryInput { static func parse(_ value: String) throws -> String {
 guard value == "octocat/Hello-World" else { throw AppError(text: "invalid repo") }; return value
} }
final class GitHub {
 var isCurrentSession = true
 var requests: [String] = []
 var responses: [String: Data] = [:]
 var resolved: [String] = []
 func resolvedBranch(_ repo: String, branch: String) async throws -> String {
  resolved.append(branch); return branch.isEmpty ? "master" : branch
 }
 func communityRead(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
  try Task.checkCancellation()
  guard isCurrentSession else { throw CancellationError() }
  requests.append(path)
  if path.contains("/git/trees/") { precondition(query == [URLQueryItem(name: "recursive", value: "1")]) }
  guard let bytes = responses[path] else { throw AppError(text: "missing fixture: " + path) }; return bytes
 }
 func decoded<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
  let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
  return try decoder.decode(type, from: await communityRead(path))
 }
 COMPONENT
 HEAD
}
MODELS
extension GitHub { SEARCH
@main struct Fixture {
 static func main() async throws {
  let gitCommit = Data(#"{"sha":"7638417db6d59f3c431d3e1f261cc637155684cd","author":{"date":"2014-11-07T22:01:45Z","name":"Monalisa Octocat"},"committer":{"date":"2014-11-07T22:01:45Z"},"tree":{"sha":"691272480426f78a0138979dd3ce63b77f706feb"}}"#.utf8)
  let restCommit = Data(#"{"sha":"6dcb09b5b57875f334f61aebed695e2e4193db5e","commit":{"author":{"date":"2011-04-14T16:00:49Z"},"tree":{"sha":"6dcb09b5b57875f334f61aebed695e2e4193db5e"}},"author":{"login":"octocat","id":1}}"#.utf8)
  do { _ = try JSONDecoder().decode(GitCommitInfo.self, from: gitCommit); preconditionFailure("default Date decoder should reproduce production failure") } catch is DecodingError {}
  let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
  let valid = try decoder.decode(GitCommitInfo.self, from: gitCommit)
  precondition(valid.tree.sha == "691272480426f78a0138979dd3ce63b77f706feb" && valid.author?.date != nil)
  do { _ = try decoder.decode(GitCommitInfo.self, from: restCommit); preconditionFailure("REST commits is NOT git/commits shape") } catch is DecodingError {}
  let api = GitHub(), base = "/repos/octocat/Hello-World"
  let treePath = base + "/git/trees/691272480426f78a0138979dd3ce63b77f706feb"
  api.responses[base + "/git/ref/heads/feature/search"] = Data(#"{"object":{"sha":"7638417db6d59f3c431d3e1f261cc637155684cd"}}"#.utf8)
  api.responses[base + "/git/ref/heads/master"] = api.responses[base + "/git/ref/heads/feature/search"]
  api.responses[base + "/git/commits/7638417db6d59f3c431d3e1f261cc637155684cd"] = gitCommit
  api.responses[treePath] = Data(#"{"tree":[{"path":"src","type":"tree","mode":"040000","sha":"a"},{"path":"src/main.swift","type":"blob","mode":"100644","sha":"b","size":1},{"path":"run","type":"blob","mode":"100755","sha":"c"},{"path":"link","type":"blob","mode":"120000","sha":"d"},{"path":"module","type":"commit","mode":"160000","sha":"e"}],"truncated":false}"#.utf8)
  let entries = try await api.repositoryEntries("octocat/Hello-World", branch: "feature/search")
  precondition(entries.map(\.path) == ["src", "run", "src/main.swift"])
  precondition(api.requests == [base + "/git/ref/heads/feature/search", base + "/git/commits/7638417db6d59f3c431d3e1f261cc637155684cd", treePath])
  api.responses[treePath] = Data(#"{"tree":[],"truncated":false}"#.utf8)
  let empty = try await api.repositoryEntries("octocat/Hello-World", branch: "")
  precondition(empty.isEmpty && api.resolved.last == "")
  api.responses[treePath] = Data(#"{"tree":[],"truncated":true}"#.utf8)
  do { _ = try await api.repositoryEntries("octocat/Hello-World", branch: "master"); preconditionFailure("accepted truncated tree") } catch is AppError {}
  let tooMany = (0...20000).map { ["path":"file\($0)", "type":"blob", "mode":"100644", "sha":"b"] }
  api.responses[treePath] = try JSONSerialization.data(withJSONObject: ["tree":tooMany,"truncated":false])
  do { _ = try await api.repositoryEntries("octocat/Hello-World", branch: "master"); preconditionFailure("accepted oversized tree") } catch is AppError {}
  api.responses[treePath] = Data(#"{"tree":[{"path":"../escape","type":"tree","mode":"040000","sha":"a"}],"truncated":false}"#.utf8)
  do { _ = try await api.repositoryEntries("octocat/Hello-World", branch: "master"); preconditionFailure("accepted unsafe tree path") } catch is AppError {}
  api.isCurrentSession = false
  do { _ = try await api.repositoryEntries("octocat/Hello-World", branch: "master"); preconditionFailure("used old account") } catch is CancellationError {}
  api.isCurrentSession = true
  do { _ = try await api.repositoryEntries("", branch: "master"); preconditionFailure("accepted empty repository") } catch is AppError {}
  api.responses.removeValue(forKey: base + "/git/ref/heads/master")
  do { _ = try await api.repositoryEntries("octocat/Hello-World", branch: ""); preconditionFailure("empty repository or missing branch became a success") } catch is AppError {}
  let cancelled = Task {
   withUnsafeCurrentTask { $0?.cancel() }
   return try await api.repositoryEntries("octocat/Hello-World", branch: "master")
  }
  do { _ = try await cancelled.value; preconditionFailure("ignored cancellation") } catch is CancellationError {}
 }
}
'''
        fixture = fixture.replace('COMPONENT', 'static func component(' + component).replace('HEAD', 'func workspaceHead(' + head)
        fixture = fixture.replace('MODELS', 'struct GitObject:' + models).replace('SEARCH', source)
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory) / 'Fixture.swift'
            main.write_text(fixture, encoding='utf-8')
            output = str(Path(directory) / 'check')
            subprocess.run(['swiftc', '-parse-as-library', str(main), '-o', output], check=True)
            subprocess.run([output], check=True, timeout=30)

    def test_post_push_navigation_is_pinned_to_branch_and_sha(self):
        project = self.source('LocalProjectView.swift')
        self.assertIn('查看本次构建', project)
        self.assertIn('headSHA: build.sha', project)
        self.assertIn('sha: current.status.head', project)
        api = self.source('NativeRepositoryAPI.swift')
        self.assertIn('name: "head_sha", value: headSHA', api)
        runs = self.source('WorkflowViews.swift')
        self.assertIn('currentBranchOnly || !headSHA.isEmpty', runs)
        self.assertIn('headSHA: headSHA', runs)
        self.assertIn('尚未发现本次提交的运行', runs)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production Swift edit fixtures execute on macOS')
    def test_utf16_indentation_selection_and_line_endings(self):
        fixture = r'''
import Foundation
@main struct Fixture {
 static func main() {
  func apply(_ text: String, _ edit: SourceTextEdit) -> String {
   (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
  }
  let unicode = "    中文😀"
  let caret = NSRange(location: (unicode as NSString).length, length: 0)
  let newline = SourceEditRules.newline(unicode, selection: caret)!
  precondition(apply(unicode, newline) == "    中文😀\n    ")
  precondition(newline.selection.location == caret.location + 5)
  let crlf = "  a\r\n  b"
  let crlfEdit = SourceEditRules.newline(crlf, selection: NSRange(location: 8, length: 0))!
  precondition(apply(crlf, crlfEdit) == "  a\r\n  b\r\n  ")
  let tabs = SourceEditRules.newline("\tlet x", selection: NSRange(location: 6, length: 0))!
  precondition(tabs.replacement == "\n\t")
  let plain = "中文😀\nnext"
  let selection = NSRange(location: 0, length: 5)
  let indented = SourceEditRules.indent(plain, selection: selection, unindent: false)!
  precondition(apply(plain, indented) == "    中文😀\nnext")
  precondition(indented.selection == NSRange(location: 4, length: 5))
  let reduced = SourceEditRules.indent("  a\r\n\tb\r\nc", selection: NSRange(location: 1, length: 8), unindent: true)!
  precondition(apply("  a\r\n\tb\r\nc", reduced) == "a\r\nb\r\nc")
  precondition(reduced.selection == NSRange(location: 0, length: 6))
  let end = SourceEditRules.indent("x\n", selection: NSRange(location: 2, length: 0), unindent: false)!
  precondition(apply("x\n", end) == "x\n    ")
  precondition(SourceEditRules.indent("x", selection: NSRange(location: 0, length: 0), unindent: true) == nil)
  precondition(SourceEditRules.newline("😀", selection: NSRange(location: 1, length: 0)) == nil)
  precondition(SourceEditRules.indent("😀", selection: NSRange(location: 0, length: 1), unindent: false) == nil)
  precondition(SourceEditRules.newline("x", selection: NSRange(location: NSNotFound, length: 1)) == nil)
  precondition(SourceEditRules.indent("x", selection: NSRange(location: 9, length: 0), unindent: false) == nil)
  print("PASS UTF-16 selections, emoji, CRLF, tabs, multiline indentation and bounds")
 }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory) / 'Fixture.swift'
            main.write_text(fixture, encoding='utf-8')
            output = str(Path(directory) / 'check')
            subprocess.run(['swiftc', '-parse-as-library', str(ROOT / 'RepoPocket/SourceEditRules.swift'), str(main), '-o', output], check=True)
            subprocess.run([output], check=True, timeout=20)


if __name__ == '__main__':
    unittest.main()
