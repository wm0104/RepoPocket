"""Run the actual production Swift parser and API wrapper, without HTTP."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import shutil, subprocess, tempfile, unittest

class RepositoryInputTests(unittest.TestCase):
    def test_shared_callsite_contracts(self):
        api = Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text()
        wrapper = api.split('static func repoPath', 1)[1].split('static func filePath', 1)[0]
        self.assertIn('RepositoryInput.parse(fullName)', wrapper)
        for name in ['fetchWorkspace', 'associateWorkspace', 'commitQueue', 'trollPublish', 'metadataSnapshot', 'downloadZIP']:
            method = api.split('func ' + name, 1)[1].split('\n    func ', 1)[0]
            self.assertIn('let repo = try RepositoryInput.parse(repo)', method)
        self.assertIn('let owner = try RepositoryInput.parse(repo)', api)
        for file in ['RepoPocketApp.swift', 'UploadView.swift', 'WorkspaceView.swift']:
            ui = Path(REPO_ROOT, 'RepoPocket/' + file).read_text()
            self.assertNotIn('TextField("用户名/仓库名"', ui)
            self.assertNotIn('TextField("已有仓库：', ui)
            self.assertIn('TextField("仓库链接"', ui)
        self.assertIn('repo: snapshot.binding.repo', Path(REPO_ROOT, 'RepoPocket/TrollMetadataView.swift').read_text())

    @unittest.skipUnless(shutil.which('swiftc'), 'Production Swift execution on macOS Actions')
    def test_production_parser_and_api_path(self):
        api = Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text()
        methods = api.split('    static func component', 1)[1].split('    static func filePath', 1)[0]
        source = Path(REPO_ROOT, 'RepoPocket/RepositoryInput.swift').read_text() + '\nenum GitHub { static func component' + methods + '\n}\n' + r'''
let valid: [(String, String)] = [
    ("owner/repo", "owner/repo"), (" Owner/Repo-1_2.3 \n", "Owner/Repo-1_2.3"),
    ("owner/repo.git", "owner/repo"), ("owner/repo/", "owner/repo"),
    ("https://github.com/owner/repo", "owner/repo"),
    ("https://github.com/Owner/Repo.git/", "Owner/Repo"),
    ("https://GITHUB.COM/owner/repo/", "owner/repo")]
for (input, expected) in valid {
    precondition(try RepositoryInput.parse(input) == expected)
    precondition(try GitHub.repoPath(input) == "/repos/" + expected)
}
let invalid = ["", "owner", "owner/", "/owner/repo", "owner//repo", "owner/repo//",
    "owner/repo/tree/main", "https://github.com/owner/repo/tree/main",
    "https://github.com/owner/repo/blob/main/file", "http://github.com/owner/repo",
    "https://example.com/owner/repo", "https://github.com.evil.test/owner/repo",
    "https://github.com@evil.test/owner/repo", "https://alice:secret@github.com/owner/repo",
    "https://alice@github.com/owner/repo", "https://github.com:443/owner/repo",
    "https://github.com/owner/repo?x=1", "https://github.com/owner/repo?",
    "https://github.com/owner/repo#readme", "https://github.com/owner/repo#",
    "owner/repo?x", "owner/repo#x", "owner/..", "../repo", "owner/.",
    "owner/.git", "owner/repo%2Ftree", "https://github.com/owner/%2e%2e",
    "https://github.com/owner/repo/../other", "owner/re\\po", "owner/re\u{0}po",
    "owner/re\npo", "own er/repo", "-owner/repo", "owner-/repo", "owner/re:po",
    "git@github.com:owner/repo.git", "//github.com/owner/repo"]
for input in invalid {
    do { _ = try RepositoryInput.parse(input); fatalError("accepted invalid input: " + input) } catch {}
    do { _ = try GitHub.repoPath(input); fatalError("API accepted invalid input: " + input) } catch {}
}
print("PASS production repository parser and API wrapper: \(valid.count) valid, \(invalid.count) invalid; zero HTTP")
'''
        # Swift precondition's autoclosure cannot throw.
        source = source.replace('precondition(try RepositoryInput.parse(input) == expected)', 'let parsed = try RepositoryInput.parse(input); precondition(parsed == expected)').replace('precondition(try GitHub.repoPath(input) == "/repos/" + expected)', 'let endpoint = try GitHub.repoPath(input); precondition(endpoint == "/repos/" + expected)')
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'main.swift'; path.write_text(source)
            subprocess.run(['swiftc', str(path), '-o', folder + '/test'], check=True)
            subprocess.run([folder + '/test'], check=True)

if __name__ == '__main__': unittest.main()
