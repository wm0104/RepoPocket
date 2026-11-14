"""Network-free tests: production Swift rules for file/folder/raw links, no pasteboard access."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import shutil
import subprocess
import tempfile
import unittest

ROOT = REPO_ROOT


class ContentLinkMenuTests(unittest.TestCase):
    def test_browser_rows_offer_copy_links_without_write_permission(self):
        app = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
        browser = app.split('struct BrowserView:', 1)[1].split('struct FileView:', 1)[0]
        rows = browser.split('@ViewBuilder private var directoryRows:', 1)[1].split('var body: some View {', 1)[0]
        folder = rows.split('if e.type == "dir"', 1)[1].split('} else if e.type == "file"', 1)[0]
        files = rows.split('} else if e.type == "file"', 1)[1]
        self.assertEqual(folder.count('.contextMenu {'), 1)
        self.assertIn('Label("复制文件夹链接", systemImage: "doc.on.doc")', folder)
        self.assertIn('RepositoryLinkRules.contentURL(repo, branch: activeBranch, path: e.path, folder: true)', folder)
        self.assertNotIn('canWrite', folder)
        self.assertEqual(folder.count('Button {'), 1)
        menu = files.split('.contextMenu {', 1)[1]
        self.assertIn('Label("复制文件链接", systemImage: "doc.on.doc")', menu)
        self.assertIn('RepositoryLinkRules.contentURL(repo, branch: activeBranch, path: e.path)', menu)
        self.assertIn('Label("复制 raw 链接", systemImage: "link")', menu)
        self.assertIn('RepositoryLinkRules.contentURL(repo, branch: activeBranch, path: e.path, raw: true)', menu)
        self.assertNotIn('canWrite', menu.split('if canWrite', 1)[0])
        self.assertIn('if canWrite { Button("删除", role: .destructive)', menu)
        self.assertEqual(browser.count('.contextMenu {'), 2)
        self.assertIn('.repositoryCopyNotice(copyFeedback)', browser)
        self.assertNotIn('raw.githubusercontent.com', browser)
        self.assertNotIn('github.com/', browser)
        self.assertIn('CopyRepositoryLinkButton(repository: repo, feedback: copyFeedback)', browser)

    def test_copy_feedback_accepts_only_rule_urls_on_trusted_hosts(self):
        ui = (ROOT/'RepoPocket/RepositoryCopyUI.swift').read_text()
        self.assertEqual(ui.count('UIPasteboard.general.string ='), 1)
        self.assertIn('func copy(url: URL?)', ui)
        self.assertIn('host == "github.com" || host == "raw.githubusercontent.com"', ui)
        self.assertIn('url.scheme == "https"', ui)
        for forbidden in ['api.message', 'URLSession', 'GitHub()', 'canWrite']:
            self.assertNotIn(forbidden, ui)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production Swift rules run on macOS CI')
    def test_production_content_urls(self):
        source = (ROOT/'RepoPocket/RepositoryInput.swift').read_text()
        source += (ROOT/'RepoPocket/RepositoryLinkRules.swift').read_text()
        source += r'''
func url(_ repo: String, _ branch: String, _ path: String, folder: Bool = false, raw: Bool = false) -> String? {
    RepositoryLinkRules.contentURL(repo, branch: branch, path: path, folder: folder, raw: raw)?.absoluteString
}
// (a) file blob link, (b) raw link, (c) folder tree link.
precondition(url("owner/repo", "main", "README.md") == "https://github.com/owner/repo/blob/main/README.md")
precondition(url("owner/repo", "main", "README.md", raw: true) == "https://raw.githubusercontent.com/owner/repo/main/README.md")
precondition(url("owner/repo", "main", "src", folder: true) == "https://github.com/owner/repo/tree/main/src")
// The repository root is not reachable from a content row.
precondition(url("owner/repo", "main", "") == nil && url("owner/repo", "main", "", folder: true) == nil)
// (d) nested multi-level path and a slash branch keep their shape.
precondition(url("owner/repo", "feature/x", "docs/a/b/c.md") == "https://github.com/owner/repo/blob/feature/x/docs/a/b/c.md")
precondition(url("owner/repo", "feature/x", "docs/a/b/c.md", raw: true) == "https://raw.githubusercontent.com/owner/repo/feature/x/docs/a/b/c.md")
precondition(url("owner/repo", "feature/x", "docs/a/b", folder: true) == "https://github.com/owner/repo/tree/feature/x/docs/a/b")
// (e) spaces and unicode are percent-encoded per component.
precondition(url("owner/repo", "dev 分支", "文 档/README 说明.md") == "https://github.com/owner/repo/blob/dev%20%E5%88%86%E6%94%AF/%E6%96%87%20%E6%A1%A3/README%20%E8%AF%B4%E6%98%8E.md")
precondition(url("owner/repo", "main", "文 档/README 说明.md", raw: true) == "https://raw.githubusercontent.com/owner/repo/main/%E6%96%87%20%E6%A1%A3/README%20%E8%AF%B4%E6%98%8E.md")
precondition(url("owner/repo", "main", "文 档", folder: true) == "https://github.com/owner/repo/tree/main/%E6%96%87%20%E6%A1%A3")
// (f) traversal, empty and URL-breaking input is rejected.
precondition(url("owner/repo", "", "README.md") == nil && url("owner/repo", "main", "") == nil)
for bad in [".", "..", "a/../b", "a/./b", "../x", "a//b", "/a", "a/", "a?b", "a#b", "a%b", "a\\b", "a\nb", "a\u{7}b"] {
    precondition(url("owner/repo", "main", bad) == nil && url("owner/repo", "main", bad, folder: true) == nil,
                 "accepted path " + bad)
    precondition(url("owner/repo", bad, "README.md") == nil && url("owner/repo", "main", bad, raw: true) == nil,
                 "accepted branch " + bad)
}
precondition(url("owner/..", "main", "README.md") == nil)
precondition(url("owner/repo?x", "main", "README.md") == nil)
precondition(url("https://evil.test/a/b", "main", "README.md") == nil)
precondition(url("https://github.com.evil.test/a/b", "main", "README.md") == nil)
// (g) folders never get a raw link.
precondition(url("owner/repo", "main", "src", folder: true, raw: true) == nil)
for (link, host, prefix) in [(url("owner/repo", "main", "README.md")!, "github.com", "/owner/repo/blob/main/"),
                             (url("owner/repo", "main", "README.md", raw: true)!, "raw.githubusercontent.com", "/owner/repo/main/"),
                             (url("owner/repo", "main", "src", folder: true)!, "github.com", "/owner/repo/tree/main/")] {
    let parsed = URLComponents(string: link)!
    precondition(parsed.scheme == "https" && parsed.host == host && parsed.user == nil && parsed.password == nil && parsed.port == nil)
    precondition(parsed.percentEncodedPath.hasPrefix(prefix) && parsed.query == nil && parsed.fragment == nil)
}
print("PASS production blob/raw/tree links: branch-scoped, nested, encoded, traversal-free; zero HTTP/pasteboard writes")
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'main.swift'
            path.write_text(source)
            subprocess.run(['swiftc', str(path), '-o', folder+'/test'], check=True)
            subprocess.run([folder+'/test'], check=True)


if __name__ == '__main__': unittest.main()
