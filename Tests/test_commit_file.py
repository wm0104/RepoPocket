"""Historical full-file rules and exact-SHA read-only navigation."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
def source(name): return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')


class CommitFileTests(unittest.TestCase):
    def test_navigation_uses_resolved_sha_and_shared_read_only_surface(self):
        self.assertIn('CommitPatchDestination(file: f, api: api, repo: repo, commitSHA: d.sha)', source('DesktopViews.swift'))
        self.assertIn('sha: detail?.sha ?? sha', source('DesktopViews.swift'))
        self.assertIn('NavigationLink("完整文件")', source('CommitPatchView.swift'))
        view = source('CommitFileView.swift')
        self.assertIn('api.file(repo, path: file.filename, branch: commitSHA)', view)
        self.assertIn('SourceCodeView(text: text, filename: file.filename)', view)
        self.assertIn('generation == AccountStore.generation', view)
        self.assertIn('response.status == 404', view)
        self.assertIn('text = nil', view)
        self.assertLess(view.index('CommitFileRules.validate('), view.index('api.file('))
        for unwanted in ('resolvedBranch(', 'api.commit(', 'FileView(', 'previous_filename', 'download_url'):
            self.assertNotIn(unwanted, view)

    @unittest.skipUnless(shutil.which('swiftc'), 'Native Swift compiler unavailable')
    def test_production_rules_accept_empty_utf8_and_reject_unavailable_versions(self):
        harness = r'''
let sha = String(repeating: "a", count: 40)
func rejects(_ operation: () throws -> Void) {
    do { try operation(); fatalError("unexpected acceptance") } catch {}
}
for status in ["modified", "added", "renamed", "copied"] {
    try CommitFileRules.validate(commitSHA: sha, status: status)
}
for invalid in ["", "main", "abc1234", String(repeating: "z", count: 40), sha + "a"] {
    rejects { try CommitFileRules.validate(commitSHA: invalid, status: "modified") }
}
for removed in ["removed", "deleted"] {
    rejects { try CommitFileRules.validate(commitSHA: sha, status: removed) }
}
func read(_ data: Data, size: Int? = nil) throws -> String {
    try CommitFileRules.decode(size: size ?? data.count, encoding: "base64", content: data.base64EncodedString())
}
let empty = try read(Data()); precondition(empty == "")
let unicode = "历史完整内容\n中文😀\n"
let value = try read(Data(unicode.utf8)); precondition(value == unicode)
let limit = SourceTextRules.byteLimit
let maximum = try read(Data(repeating: 65, count: limit)); precondition(maximum.utf8.count == limit)
rejects { _ = try read(Data(repeating: 65, count: limit + 1)) }
rejects { _ = try read(Data([0, 1, 2])) }
rejects { _ = try read(Data([0xff])) }
rejects { _ = try CommitFileRules.decode(size: -1, encoding: "base64", content: "") }
rejects { _ = try CommitFileRules.decode(size: 0, encoding: "none", content: "") }
rejects { _ = try CommitFileRules.decode(size: 0, encoding: "base64", content: nil) }
rejects { _ = try CommitFileRules.decode(size: 0, encoding: "base64", content: String(repeating: "A", count: limit * 2 + 1)) }
print("PASS exact commit rules: immutable SHA, deleted paths, empty/Unicode, binary, size and encoding")
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'main.swift'
            path.write_text(source('SourceLexer.swift') + '\n' + source('CommitFileRules.swift') + '\n' + harness, encoding='utf-8')
            binary = str(Path(directory) / 'commit-file')
            subprocess.run(['swiftc', str(path), '-o', binary], check=True)
            subprocess.run([binary], check=True)


if __name__ == '__main__': unittest.main()
