"""Exact-SHA historical previews and first-parent evidence for media diffs."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
def source(name): return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')


class CommitFileTests(unittest.TestCase):
    def test_navigation_uses_resolved_sha_and_shared_read_only_surface(self):
        desktop = source('DesktopViews.swift')
        self.assertIn('commitSHA: d.sha, parents: d.parents', desktop)
        self.assertIn('sha: detail?.sha ?? sha', desktop)
        patch = source('CommitPatchView.swift')
        self.assertIn('NavigationLink("完整文件")', patch)
        self.assertIn('NavigationLink("源码差异")', patch)
        self.assertIn('CommitPatchView(file: file, pullRequest: pullRequest)', patch)
        for literal in ('Toggle("原始 patch"', 'CommitPatchParser.parse(patch)', '"commit-full-file"'):
            self.assertIn(literal, patch)
        view = source('CommitFileView.swift')
        self.assertIn('CommitFileRules.validate(commitSHA: commitSHA, status: file.status)', view)
        self.assertIn('api.repositoryFilePreview(repo, path: version.path, ref: version.sha, allowEditing: false)', view)
        self.assertIn('RepositoryFilePreviewBody(preview: preview, path: version.path)', view)
        for literal in ('api.isCurrentSession', 'response.status == 404', 'githubAccountChanged', 'Task.checkCancellation()', '.task(id: attempt)', '"commit-full-file-content"'):
            self.assertIn(literal, view)
        for unwanted in ('resolvedBranch(', 'api.commit(', 'api.file(', 'previous_filename', 'download_url'):
            self.assertNotIn(unwanted, view)

    def test_media_preview_switches_content_identity_and_uses_comparison_only_for_merges(self):
        patch = source('CommitPatchView.swift')
        self.assertIn('RepositoryFilePreviewRules.media(for: file.filename)', patch)
        diff = source('CommitMediaDiffView.swift')
        for literal in ('CommitFileRules.mergeParent(', 'api.commitMediaComparison(', '第一父比较基准',
                        '修改前', '修改后', '.id(side)', 'githubAccountChanged', 'Task.checkCancellation()'):
            self.assertIn(literal, diff)
        self.assertLess(diff.index('CommitFileRules.mergeParent('), diff.index('api.commitMediaComparison('))
        for unwanted in ('api.file(', 'resolvedBranch(', 'download_url'):
            self.assertNotIn(unwanted, diff)

    @unittest.skipUnless(shutil.which('swiftc'), 'Native Swift compiler unavailable')
    def test_production_rules_require_evidence_for_each_version(self):
        harness = r'''
let sha = String(repeating: "a", count: 40)
let parent = String(repeating: "b", count: 40)
let other = String(repeating: "c", count: 40)
let now = "目录/new.png", old = "旧目录/old.png", comparedOld = "第一父/other.png"
let one = [DesktopCommit.Parent(sha: parent)]
let merge = one + [.init(sha: other)]
func rejects(_ operation: () throws -> Void) {
    do { try operation(); fatalError("unexpected acceptance") } catch {}
}
func file(_ status: String, _ previous: String? = nil, path: String = now) -> DesktopCommit.File {
    .init(filename: path, previous_filename: previous, status: status, additions: 0, deletions: 0, patch: nil)
}
func comparison(_ files: [DesktopCommit.File]?, base: String = parent, mergeBase: String = parent) -> CommitMediaComparison {
    .init(base_commit: .init(sha: base), merge_base_commit: .init(sha: mergeBase), files: files)
}
for status in ["modified", "added", "renamed", "copied"] {
    try CommitFileRules.validate(commitSHA: sha, status: status)
}
for invalid in ["", "main", "abc1234", String(repeating: "z", count: 40), sha + "a"] {
    rejects { try CommitFileRules.validate(commitSHA: invalid, status: "modified") }
    let invalidVersions = CommitFileRules.versions(commitSHA: invalid, parents: one, file: file("modified"))
    precondition(invalidVersions.after == nil && invalidVersions.before == nil)
}
for removed in ["removed", "deleted"] {
    rejects { try CommitFileRules.validate(commitSHA: sha, status: removed) }
}
func versions(_ f: DesktopCommit.File, _ parents: [DesktopCommit.Parent]?, _ compare: CommitMediaComparison? = nil) -> CommitFileRules.Versions {
    CommitFileRules.versions(commitSHA: sha, parents: parents, file: f, comparison: compare)
}
func matches(_ result: CommitFileRules.Versions, before: String?, after: String?, missingEvidence: Bool = false) {
    precondition(result.before?.path == before && result.after?.path == after)
    precondition(result.before?.sha == before.map { _ in parent } && result.after?.sha == after.map { _ in sha })
    precondition((result.notice != nil) == missingEvidence)
}
matches(versions(file("modified"), one), before: now, after: now)
matches(versions(file("renamed", old), one), before: old, after: now)
matches(versions(file("renamed"), one), before: nil, after: now, missingEvidence: true)
matches(versions(file("renamed", now), one), before: nil, after: now, missingEvidence: true)
matches(versions(file("added"), one), before: nil, after: now)
matches(versions(file("copied", old), one), before: nil, after: now)
matches(versions(file("added"), []), before: nil, after: now)
matches(versions(file("removed"), one), before: now, after: nil)
matches(versions(file("deleted"), one), before: now, after: nil)
matches(versions(file("modified"), nil), before: nil, after: now, missingEvidence: true)
matches(versions(file("removed"), nil), before: nil, after: nil, missingEvidence: true)
matches(versions(file("modified"), [.init(sha: "b123")]), before: nil, after: now, missingEvidence: true)
precondition(CommitFileRules.mergeParent(commitSHA: sha, parents: merge) == parent)
precondition(CommitFileRules.mergeParent(commitSHA: sha, parents: one) == nil)
precondition(CommitFileRules.mergeParent(commitSHA: sha, parents: [.init(sha: sha), .init(sha: other)]) == nil)
matches(versions(file("renamed", old), merge, comparison([file("renamed", comparedOld)])), before: comparedOld, after: now)
matches(versions(file("modified"), merge, comparison([file("added")])), before: nil, after: now)
matches(versions(file("removed"), merge, comparison([file("removed")])), before: now, after: nil)
for unproven in [nil, comparison(nil), comparison([]), comparison([file("modified", path: old)]),
                 comparison([file("modified")], base: other), comparison([file("modified")], mergeBase: other),
                 comparison([file("modified"), file("modified")]), comparison([file("removed")]),
                 comparison([file("renamed")]), comparison(Array(repeating: file("modified", path: old), count: 299) + [file("modified")])] {
    matches(versions(file("modified"), merge, unproven), before: nil, after: now, missingEvidence: true)
}
let decomposed = "e\u{301}.png"
let composed = "\u{E9}.png"
matches(versions(file("modified", path: decomposed), merge, comparison([file("modified", path: composed)])),
        before: nil, after: decomposed, missingEvidence: true)
let decoded = try JSONDecoder().decode(DesktopCommit.self, from: Data("""
{"sha":"x","commit":{"message":"fixture"},"parents":[{"sha":"b"},{"sha":"c"}]}
""".utf8))
precondition(decoded.parents?.map(\.sha) == ["b", "c"])
let fixture = DesktopCommit(sha: sha, commit: .init(message: "fixture", author: nil, committer: nil), files: nil, stats: nil)
precondition(fixture.parents == nil)
print("PASS exact commit rules: immutable SHA, one-sided edits, first-parent compare, missing evidence and byte-exact paths")
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'main.swift'
            path.write_text(source('DesktopModels.swift') + '\n' + source('CommitFileRules.swift') + '\n' + harness, encoding='utf-8')
            binary = str(Path(directory) / 'commit-file')
            subprocess.run(['swiftc', str(path), '-o', binary], check=True)
            subprocess.run([binary], check=True)


if __name__ == '__main__': unittest.main()
