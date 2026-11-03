"""Same-repository PR squash safety; production transport runs against URLProtocol only."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RemoteBranchMergeTests(unittest.TestCase):
    def test_feature_and_native_regression_fixture_exist(self):
        self.assertTrue((ROOT / 'RepoPocket/RemoteBranchMerge.swift').is_file())
        self.assertTrue((ROOT / 'Tests/Fixtures/RemoteBranchMergeHarness.swift').is_file())

    def test_transport_and_ui_safety_contract(self):
        github = (ROOT / 'RepoPocket/GitHub.swift').read_text()
        transport = github.split('    // BEGIN RemoteBranchMerge transport\n', 1)[1].split('    // END RemoteBranchMerge transport', 1)[0]
        logic = (ROOT / 'RepoPocket/RemoteBranchMerge.swift').read_text()
        view = (ROOT / 'RepoPocket/RemoteBranchMergeView.swift').read_text()
        self.assertIn('session.download(for: r, delegate: RemoteBranchMergeBudget())', transport)
        self.assertIn('read(upToCount: RemoteBranchMergeBudget.limit + 1)', transport)
        self.assertGreaterEqual(transport.count('try ensureActiveAccount(); try Task.checkCancellation()'), 4)
        self.assertIn('try check(bytes, response', transport)
        self.assertIn('"merge_method": "squash"', logic)
        self.assertIn('"sha": confirmation.preview.sourceSHA', logic)
        self.assertIn('"commit_title": title', logic)
        self.assertIn('fresh.merge_commit_sha == sha', logic)
        self.assertIn('repo.delete_branch_on_merge == false', logic)
        self.assertIn('retainedSource == confirmation.preview.sourceSHA', logic)
        self.assertIn('method == "POST" ? 201 : 200', transport)
        self.assertIn('"filter", value: "latest"', logic)
        self.assertIn('statusComplete, runsComplete', logic)
        self.assertIn('没有配置检查，不代表成功', logic)
        for forbidden in ['LocalGitEngine', 'deleteBranch(', '/actions/', 'force:', 'merge_method": "merge"']:
            self.assertNotIn(forbidden, logic + view + transport)
        for identifier in ['target', 'preview', 'open-pr', 'refresh', 'confirm', 'result']:
            self.assertIn('accessibilityIdentifier("branch-merge-' + identifier + '")', view)
        self.assertIn('Button("确认压缩合并"', view)
        self.assertIn('LocalGitBranchPicker(api: api, repo: repo, current: target)', view)
        self.assertIn('CommitDetailView(api: api, repo: preview.repository, sha: commit.sha)', view)
        self.assertIn('CommitPatchDestination(file: file, pullRequest: true)', view)
        self.assertIn('不能锁定目标 SHA', view)

    def test_existing_gateway_remains_read_only(self):
        github = (ROOT / 'RepoPocket/GitHub.swift').read_text()
        gateway = github.split('    // Read-only gateway', 1)[1].split('    // Native collaboration transport:', 1)[0]
        # Markdown render is the pre-existing read-only POST; exclude it exactly.
        gateway = gateway.split('    /// Server-side GFM rendering', 1)[0]
        self.assertIn('try await data(path, query: query)', gateway)
        self.assertNotIn('method:', gateway)
        self.assertEqual(github.count('    // BEGIN RemoteBranchMerge transport'), 1)
        self.assertEqual(github.count('    // END RemoteBranchMerge transport'), 1)

    @unittest.skipUnless(shutil.which('swiftc'), 'swiftc unavailable: native URLProtocol/state tests require macOS')
    def test_production_transport_and_state(self):
        github = (ROOT / 'RepoPocket/GitHub.swift').read_text()
        transport = github.split('    // BEGIN RemoteBranchMerge transport\n', 1)[1].split('    // END RemoteBranchMerge transport', 1)[0]
        source = (ROOT / 'Tests/Fixtures/RemoteBranchMergeHarness.swift').read_text()
        source = source.replace('// PRODUCTION_TRANSPORT', transport)
        for marker, start, end in [
            ('// PRODUCTION_REQUEST', '    private func request(', '    // Public official update'),
            ('// PRODUCTION_URL', '    static func component(', '    private func request('),
            ('// PRODUCTION_ACCOUNT', '    private func ensureActiveAccount()', '    private func check('),
            ('// PRODUCTION_CHECK', '    private func check(', '    private func operation('),
        ]:
            source = source.replace(marker, github[github.index(start):github.index(end, github.index(start))])
        source = source.replace('// PRODUCTION_CODE', '\n'.join((ROOT / 'RepoPocket' / name).read_text() for name in [
            'RepositoryInput.swift', 'DesktopModels.swift', 'OfficialUpdateRedirectPolicy.swift', 'RemoteBranchMerge.swift']))
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'Harness.swift'
            path.write_text(source)
            binary = str(Path(folder) / 'harness')
            subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', binary], check=True)
            subprocess.run([binary], check=True, timeout=60)


if __name__ == '__main__':
    unittest.main()
