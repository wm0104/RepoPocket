"""Every github.com link opens a native screen; the pure rules execute on macOS via swiftc.

Xcode is not available on the development machine, so the classification rules are compiled
from production sources by the macOS runner; the wiring is checked statically everywhere.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RULES = (ROOT / 'RepoPocket/GitHubLinkTarget.swift').read_text(encoding='utf-8')
DESTINATION = (ROOT / 'RepoPocket/NativeLinkDestination.swift').read_text(encoding='utf-8')


class NativeLinkWiringTests(unittest.TestCase):
    def test_github_links_never_reach_the_web_view(self):
        self.assertNotIn('private var nativeDestination', DESTINATION)
        self.assertIn('if let api, GitHubLinkRules.isGitHub(url) {', DESTINATION)
        self.assertIn('ContainedWebPage(url: url, onClose: onClose).ignoresSafeArea()', DESTINATION)
        self.assertEqual(DESTINATION.count('ContainedWebPage('), 3)
        self.assertIn('NavigationStack {', DESTINATION)
        self.assertIn('ToolbarItem(placement: .cancellationAction) { Button("完成", action: onClose) }', DESTINATION)

    def test_native_screens_are_reused_without_new_destinations(self):
        for token in ('BrowserView(api: api, repo: repo, path: "", branch: "")',
                      'BrowserView(api: api, repo: repo, path: path, branch: ref)',
                      'CollaborationDetailView(api: api, repo: repo, kind: .issues, number: number)',
                      'CollaborationDetailView(api: api, repo: repo, kind: .pulls, number: number)',
                      'CommitDetailView(api: api, repo: repo, sha: sha)',
                      'ReleaseListView(api: api, repo: repo)',
                      'WorkflowRunsView(api: api, repo: repo, branch: "")'):
            self.assertIn(token, DESTINATION)
        self.assertIn('FileView(api: api, repo: repo, entry: entry, branch: ref)', DESTINATION)
        self.assertIn('let loaded = try await api.file(repo, path: path, branch: ref)', DESTINATION)
        # Branch names are read once per sheet, capped, and tolerate API failure.
        self.assertIn('guard branches == nil, api.isCurrentSession', DESTINATION)
        self.assertIn('for page in 1...3 {', DESTINATION)
        self.assertIn('guard let list = try? await api.branches(repo, page: page) else { break }', DESTINATION)
        self.assertIn('if list.count < 100 { break }', DESTINATION)

    def test_web_page_is_only_the_last_resort_for_a_load_failure(self):
        loader = DESTINATION.split('private struct NativeLinkFileView: View {', 1)[1].split('struct ContainedWebPage:', 1)[0]
        self.assertIn('Button("在 GitHub 网页打开") { web = true }', loader)
        self.assertNotIn('SFSafariViewController', loader)


SWIFT_FIXTURE = r'''
import Foundation

@main struct Run {
    static func check(_ text: String, _ expected: GitHubLinkTarget?, branches: [String] = []) {
        guard let url = URL(string: text) else { preconditionFailure("bad fixture URL " + text) }
        let actual = GitHubLinkRules.target(url, branches: branches)
        precondition(actual == expected, "unexpected target for " + text + ": " + String(describing: actual))
    }

    static func rejects(_ text: String) {
        guard let url = URL(string: text), let target = GitHubLinkRules.target(url, branches: ["main"]) else { return }
        switch target {
        case let .file(_, _, _, path): precondition(!path.contains(".."), "traversal leaked: " + text)
        case let .directory(_, _, _, path): precondition(!path.contains(".."), "traversal leaked: " + text)
        default: break
        }
    }

    static func main() {
        let repo = GitHubLinkTarget.repository(owner: "a", repo: "b")
        // 1) repository root, trailing slash, query/fragment, .git suffix, www host
        check("https://github.com/a/b", repo)
        check("https://github.com/a/b/", repo)
        check("https://www.github.com/a/b", repo)
        check("https://github.com/a/b?tab=readme-ov-file#install", repo)
        check("https://github.com/a/b.git", repo)
        // 2) blob -> native file, 3) tree -> native directory
        check("https://github.com/a/b/blob/main/src/x.swift",
              GitHubLinkTarget.file(owner: "a", repo: "b", ref: "main", path: "src/x.swift"))
        check("https://github.com/a/b/blob/main/x.md?plain=1#L3",
              GitHubLinkTarget.file(owner: "a", repo: "b", ref: "main", path: "x.md"))
        check("https://github.com/a/b/blob/main/x%20y.md",
              GitHubLinkTarget.file(owner: "a", repo: "b", ref: "main", path: "x y.md"))
        check("https://github.com/a/b/blob/main/", repo)
        check("https://github.com/a/b/blob/main", repo)
        check("https://github.com/a/b/tree/main/src",
              GitHubLinkTarget.directory(owner: "a", repo: "b", ref: "main", path: "src"))
        check("https://github.com/a/b/tree/main/src/",
              GitHubLinkTarget.directory(owner: "a", repo: "b", ref: "main", path: "src"))
        check("https://github.com/a/b/tree/main", GitHubLinkTarget.directory(owner: "a", repo: "b", ref: "main", path: ""))
        check("https://github.com/a/b/tree/", repo)
        // branch names containing slashes use the longest known prefix, then the first segment
        check("https://github.com/a/b/blob/feature/x/docs/a.md",
              GitHubLinkTarget.file(owner: "a", repo: "b", ref: "feature/x", path: "docs/a.md"), branches: ["main", "feature/x"])
        check("https://github.com/a/b/tree/feature/x/y/src",
              GitHubLinkTarget.directory(owner: "a", repo: "b", ref: "feature/x/y", path: "src"),
              branches: ["main", "feature/x", "feature/x/y"])
        check("https://github.com/a/b/blob/feature/x/docs/a.md",
              GitHubLinkTarget.file(owner: "a", repo: "b", ref: "feature", path: "x/docs/a.md"))
        check("https://github.com/a/b/blob/x/y/z.md",
              GitHubLinkTarget.file(owner: "a", repo: "b", ref: "x", path: "y/z.md"), branches: ["main"])
        // 4) releases keep the native releases screen
        check("https://github.com/a/b/releases", GitHubLinkTarget.releases(owner: "a", repo: "b"))
        check("https://github.com/a/b/releases/tag/v1.1.6", GitHubLinkTarget.releases(owner: "a", repo: "b"))
        check("https://github.com/a/b/releases/latest", GitHubLinkTarget.releases(owner: "a", repo: "b"))
        // 5) actions -> native runs list / run detail
        check("https://github.com/a/b/actions", GitHubLinkTarget.runs(owner: "a", repo: "b"))
        check("https://github.com/a/b/actions/runs/123", GitHubLinkTarget.runs(owner: "a", repo: "b"))
        check("https://github.com/a/b/actions/runs/123/jobs", GitHubLinkTarget.runs(owner: "a", repo: "b"))
        check("https://github.com/a/b/actions/workflows/build.yml", GitHubLinkTarget.runs(owner: "a", repo: "b"))
        // 6) issues, pull requests (with trailing sub-paths) and commits stay native
        check("https://github.com/a/b/issues/7", GitHubLinkTarget.issue(owner: "a", repo: "b", number: 7))
        check("https://github.com/a/b/issues/7#issuecomment-1", GitHubLinkTarget.issue(owner: "a", repo: "b", number: 7))
        check("https://github.com/a/b/pull/9", GitHubLinkTarget.pull(owner: "a", repo: "b", number: 9))
        check("https://github.com/a/b/pull/9/files", GitHubLinkTarget.pull(owner: "a", repo: "b", number: 9))
        check("https://github.com/a/b/pull/9/commits", GitHubLinkTarget.pull(owner: "a", repo: "b", number: 9))
        check("https://github.com/a/b/issues/0", repo)
        check("https://github.com/a/b/issues/abc", repo)
        let sha = "5c4fee5a1b2c3d4e5f60718293a4b5c6d7e8f901"
        check("https://github.com/a/b/commit/" + sha, GitHubLinkTarget.commit(owner: "a", repo: "b", sha: sha))
        check("https://github.com/a/b/commit/5c4fee5", GitHubLinkTarget.commit(owner: "a", repo: "b", sha: "5c4fee5"))
        check("https://github.com/a/b/commit/xyz", repo)
        // 7) any other repository path stays on the native repository page
        for text in ["https://github.com/a/b/settings", "https://github.com/a/b/wiki",
                     "https://github.com/a/b/issues", "https://github.com/a/b/pulls",
                     "https://github.com/a/b/tree", "https://github.com/a/b/discussions/1",
                     "https://github.com/a/b/unknown/deep/path"] {
            check(text, repo)
        }
        // 8) non-GitHub hosts and unusable URLs have no native target
        precondition(GitHubLinkRules.target(URL(string: "https://gitlab.com/a/b")!) == nil)
        precondition(GitHubLinkRules.target(URL(string: "https://gist.github.com/a/b")!) == nil)
        precondition(GitHubLinkRules.target(URL(string: "https://github.com.evil.example/a/b")!) == nil)
        precondition(!GitHubLinkRules.isGitHub(URL(string: "https://gist.github.com/a")!))
        precondition(GitHubLinkRules.isGitHub(URL(string: "https://GITHUB.com/a/b")!))
        // 9) URL sanity: https only, no credentials, no traversal
        precondition(GitHubLinkRules.target(URL(string: "http://github.com/a/b")!) == nil)
        precondition(GitHubLinkRules.target(URL(string: "https://user:pass@github.com/a/b")!) == nil)
        precondition(GitHubLinkRules.target(URL(string: "https://github.com/a/b/blob/main/x%2Fy.md")!) == nil)
        precondition(GitHubLinkRules.target(URL(string: "https://github.com/a/b/tree/main/..%2F..%2Fx")!) == nil)
        precondition(GitHubLinkRules.target(URL(string: "https://github.com/a/b/tree/main/%2E%2E%2Fsecret")!) == nil)
        precondition(GitHubLinkRules.target(URL(string: "https://github.com/a")!) == nil)
        precondition(GitHubLinkRules.target(URL(string: "https://github.com/")!) == nil)
        precondition(GitHubLinkRules.repositoryName(URL(string: "https://github.com/a/b/tree/main")!) == "a/b")
        // Dot segments are either rejected or collapsed by URL, never escaping the repository.
        rejects("https://github.com/a/b/blob/main/../x")
        rejects("https://github.com/a/b/blob/main/%2e%2e/x")
        print("PASS github link classification, branch resolution and URL sanity")
    }
}
'''


class NativeLinkRulesTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Production link rules execute on macOS')
    def test_classification_runs_on_production_sources(self):
        model = ('import Foundation\n'
                 + (ROOT / 'RepoPocket/RepositoryInput.swift').read_text(encoding='utf-8')
                 + '\n' + RULES + '\n' + SWIFT_FIXTURE)
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'Fixture.swift'
            source.write_text(model, encoding='utf-8')
            binary = str(Path(folder) / 'fixture')
            subprocess.run(['swiftc', '-parse-as-library', str(source), '-o', binary], check=True)
            result = subprocess.run([binary], check=True, capture_output=True, text=True)
            self.assertIn('PASS github link classification', result.stdout)


if __name__ == '__main__':
    unittest.main()
