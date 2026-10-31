"""Upstream sync: request shapes, 409 conflict, fast-forward apply, preview safety."""
from pathlib import Path
import shutil, subprocess, tempfile, unittest

ROOT = Path(__file__).resolve().parents[1]
FEATURE = (ROOT / 'RepoPocket/UpstreamSync.swift').read_text()
API = (ROOT / 'RepoPocket/GitHub.swift').read_text()
APP = (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text()


def block(text, start, end):
    assert start in text, start
    return text.split(start, 1)[1].split(end, 1)[0]


class UpstreamSyncSourceTests(unittest.TestCase):
    def test_compare_path_keeps_cross_repository_head(self):
        path = block(FEATURE, 'static func comparePath(', '\n    static func mergesPath(')
        self.assertIn('"/compare/" + refPath(base)', path)
        self.assertIn('"..." + segment(upstream.owner) + ":" + refPath(upstream.branch)', path)
        self.assertIn('repositoryPath(RepositoryInput.parse(repo))', path)
        self.assertIn('DesktopRules.validBranch(base)', path)
        compare = block(API, 'func upstreamCompare(', '\n    func upstreamBranchHead(')
        self.assertIn('decoded(UpstreamCompare.self', compare)
        for write in ['method: "POST"', 'method: "PATCH"', '/merges', '/git/refs']:
            self.assertNotIn(write, compare)

    def test_merges_body_and_conflict_mapping(self):
        body = block(FEATURE, 'static func mergeObject(', '\n    static func applyObject(')
        self.assertIn('"base": base', body)
        self.assertIn('"head": upstream.owner + ":" + upstream.branch', body)
        self.assertIn('"commit_message": message', body)
        self.assertNotIn('force', body)
        outcome = block(FEATURE, 'static func mergeOutcome(', '\n    enum ApplyOutcome:')
        self.assertIn('if status == 409 { return .conflict }', outcome)
        self.assertIn('if status == 204 { return .upToDate }', outcome)
        merge = block(API, 'func mergeUpstream(', '\n    /// Fast-forward only')
        self.assertIn('UpstreamSyncRules.mergesPath(repo: repo)', merge)
        self.assertIn('method: "POST"', merge)
        flow = block(FEATURE, 'func merge(api: GitHub', 'func apply(api: GitHub')
        self.assertIn('api.mergeUpstream(', flow)
        self.assertIn('base: current.tempBranch', flow)
        self.assertIn('upstream: target', flow)
        # The target branch is never the merge base, so a merge cannot move it.
        self.assertIn('repo: repo, base: current.tempBranch', flow)
        self.assertIn('stage = .conflict', flow)

    def test_apply_is_fast_forward_only(self):
        obj = block(FEATURE, 'static func applyObject', '\n    // MARK: - Names')
        self.assertIn('"force": false', obj)
        apply = block(API, 'func applyUpstreamFastForward(', '\n}\n')
        self.assertIn('UpstreamSyncRules.branchRefPath(repo: repo, branch: branch)', apply)
        self.assertIn('method: "PATCH"', apply)
        outcome = block(FEATURE, 'static func applyOutcome', '\n    // MARK: - Permissions')
        self.assertIn('.rejected(', outcome)
        self.assertIn('不会改写历史', outcome)
        self.assertNotIn('force: true', FEATURE)
        self.assertNotIn('"force": true', FEATURE)

    def test_preview_issues_no_writes(self):
        preview = block(FEATURE, 'func loadPreview(', 'func propose(')
        self.assertEqual(preview.count('await api.'), 1)
        self.assertIn('api.upstreamCompare(', preview)
        for write in ['mergeUpstream(', 'createUpstreamRef(', 'applyUpstreamFastForward(']:
            self.assertNotIn(write, preview)
        view = FEATURE.split('struct UpstreamSyncView: View {', 1)[1]
        self.assertEqual(view.count('.confirmationDialog('), 2)
        self.assertEqual(view.count('.alert('), 0)
        self.assertIn('titleVisibility: .visible', view)
        self.assertIn('SoftGroupRow(', view)
        self.assertIn('softGroupedRow', view)
        self.assertNotIn('LinearGradient', FEATURE)
        self.assertNotIn('.font(.system', FEATURE)
        self.assertNotIn('Color.red', FEATURE)
        self.assertNotIn('.orange', FEATURE)

    def test_entry_point_and_no_hardcoded_projects(self):
        self.assertIn('SoftGroupRow("upstream-sync")', APP)
        self.assertIn('UpstreamSyncView(api: api, repo: repo, branch: activeBranch, canWrite: canWrite, repository: repositoryInfo)', APP)
        self.assertGreater(APP.index('SoftGroupRow("upstream-sync")'), APP.index('SoftGroupRow("history")'))
        for name in ['roothide', 'w2599', 'Dopamine', '3.x_roothide']:
            self.assertNotIn(name, FEATURE)
            self.assertNotIn(name, APP)
        # No preselected upstream: both fields start empty and are user driven.
        self.assertIn('@Published var upstreamRepository = ""', FEATURE)
        self.assertIn('@Published var upstreamBranch = ""', FEATURE)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production rules run on macOS CI')
    def test_request_shapes_and_answers_network_free(self):
        rules = FEATURE.split('@MainActor final class UpstreamSyncState', 1)[0]
        rules = rules.replace('import SwiftUI', 'import Foundation', 1)
        source = rules
        source += (ROOT / 'RepoPocket/RepositoryInput.swift').read_text()
        source += (ROOT / 'RepoPocket/DesktopModels.swift').read_text()
        source += r'''
import Foundation

@main struct Harness {
    static func main() throws {
        let sha = String(repeating: "a", count: 40)
        let upstream = try UpstreamSyncRules.target(repository: " upstream-owner/upstream-repo ", branch: "main")
        precondition(upstream.repository == "upstream-owner/upstream-repo" && upstream.branch == "main")
        precondition(try UpstreamSyncRules.target(repository: "https://github.com/upstream-owner/upstream-repo", branch: "main").repository == "upstream-owner/upstream-repo")
        precondition(try UpstreamSyncRules.target(repository: "upstream-owner/upstream-repo.git", branch: "main").repository == "upstream-owner/upstream-repo")
        let same = try UpstreamSyncRules.comparePath(repo: "target-owner/target-repo", base: "main", upstream: upstream)
        precondition(same == "/repos/target-owner/target-repo/compare/main...upstream-owner:main", same)
        let nested = try UpstreamSyncRules.comparePath(repo: "target-owner/target-repo", base: "feature/topic",
            upstream: UpstreamSyncRules.Target(repository: "upstream-owner/upstream-repo", branch: "fix/deep"))
        precondition(nested == "/repos/target-owner/target-repo/compare/feature/topic...upstream-owner:fix/deep", nested)
        let merge = UpstreamSyncRules.mergeObject(base: "sync/upstream-stamp", upstream: upstream, message: "m")
        precondition(Set(merge.keys) == ["base", "head", "commit_message"], "\(merge.keys)")
        precondition(merge["base"] as? String == "sync/upstream-stamp")
        precondition(merge["head"] as? String == "upstream-owner:main")
        precondition(UpstreamSyncRules.mergeOutcome(status: 409, body: Data(#"{"message":"Merge conflict"}"#.utf8)) == .conflict)
        precondition(UpstreamSyncRules.mergeOutcome(status: 204, body: Data()) == .upToDate)
        precondition(UpstreamSyncRules.mergeOutcome(status: 201, body: Data("{\"sha\":\"\(sha)\"}".utf8)) == .merged(sha: sha))
        guard case .rejected(let mergeText) = UpstreamSyncRules.mergeOutcome(status: 422, body: Data(#"{"message":"not mergeable"}"#.utf8)) else {
            preconditionFailure("422 must not look merged")
        }
        precondition(mergeText == "not mergeable")
        let apply = UpstreamSyncRules.applyObject(sha: sha)
        precondition(Set(apply.keys) == ["sha", "force"])
        precondition((apply["force"] as? Bool) == false)
        precondition(UpstreamSyncRules.applyOutcome(status: 200,
            body: Data("{\"ref\":\"refs/heads/main\",\"object\":{\"sha\":\"\(sha)\"}}".utf8)) == .updated(sha: sha))
        guard case .rejected(let applyText) = UpstreamSyncRules.applyOutcome(status: 422,
            body: Data(#"{"message":"Update is not a fast forward"}"#.utf8)) else {
            preconditionFailure("422 must be rejected")
        }
        precondition(applyText.contains("not a fast forward") && applyText.contains("不会改写历史"))
        let timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = 2026; components.month = 1; components.day = 2
        components.hour = 3; components.minute = 4; components.second = 5
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let stamp = UpstreamSyncRules.stamp(calendar.date(from: components)!, timeZone: timeZone)
        precondition(stamp == "20260102-030405", stamp)
        precondition(DesktopRules.validBranch(UpstreamSyncRules.backupTag(stamp)))
        precondition(DesktopRules.validBranch(UpstreamSyncRules.tempBranch(stamp)))
        let memory = UpstreamSyncRules.encodeMemory(repository: upstream.repository, branch: upstream.branch)
        precondition(UpstreamSyncRules.decodeMemory(memory)?.repository == upstream.repository)
        precondition(UpstreamSyncRules.decodeMemory(nil) == nil)
        precondition(UpstreamSyncRules.candidates(parent: "upstream-owner/upstream-repo",
            source: "upstream-owner/upstream-repo", current: "target-owner/target-repo") == ["upstream-owner/upstream-repo"])
        precondition(UpstreamSyncRules.candidates(parent: "target-owner/target-repo",
            source: nil, current: "TARGET-owner/target-repo").isEmpty)
        precondition(UpstreamSyncRules.permissionFailure(status: 403, operation: "合并", reason: "Forbidden")?.contains("Contents: write") == true)
        precondition(UpstreamSyncRules.permissionFailure(status: 500, operation: "合并", reason: "boom") == nil)
        print("PASS upstream sync rules: compare path, merges body, 409 conflict, fast-forward apply")
    }
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'Harness.swift'
            path.write_text(source)
            binary = str(Path(folder) / 'harness')
            subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', binary], check=True)
            subprocess.run([binary], check=True)


if __name__ == '__main__':
    unittest.main()
