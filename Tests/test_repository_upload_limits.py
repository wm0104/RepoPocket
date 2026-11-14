"""Production Swift rules plus wiring checks; no GitHub writes or large allocations."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / 'RepoPocket' / name).read_text()


def function(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class RepositoryUploadLimits(unittest.TestCase):
    def test_shared_strict_limits_and_safe_aggregation(self):
        queue = source('RepoQueue.swift')
        self.assertIn('static let maximumFileBytes: Int64 = 100 * 1024 * 1024 - 1', queue)
        self.assertIn('static let maximumTotalUploadBytes: Int64 = maximumFileBytes', queue)
        self.assertIn('static func addingUploadBytes(', queue)
        self.assertGreaterEqual(queue.count('try addingUploadBytes(item.size, to: totalBytes)'), 2)

    def test_all_ordinary_entry_points_use_shared_rules(self):
        for name in ['RepoQueue.swift', 'GitHub.swift', 'UploadView.swift', 'WorkspaceRemote.swift']:
            text = source(name)
            self.assertNotRegex(text, r'10 \* 1024 \* 1024|10 MiB|50 MiB')
            self.assertIn('RepoQueue' if name != 'RepoQueue.swift' else '小于 100 MiB', text)
        ui = source('UploadView.swift')
        self.assertNotRegex(ui, r'if bytes >[^\n]+\{ mode = 1 \}')
        self.assertIn('RepoQueue.addingUploadBytes', ui)
        api = source('GitHub.swift')
        for name, end in [('func commitQueue(', 'func identify('), ('func commitWorkspace(', 'func commitQueue(')]:
            body = function(api, name, end)
            self.assertIn('RepoQueue.addingUploadBytes', body)
            self.assertIn('uploadGitBlobFile(', body)
            self.assertIn('"force": false', body)
            self.assertNotIn('.base64EncodedString()', body)
        direct = function(api, 'func commit(_ repo:', 'func delete(')
        small, large = direct.split('        let repo = try RepositoryInput.parse(repo)', 1)
        self.assertIn('if bytes.count <= 1024 * 1024 {', small)
        self.assertIn('method: "PUT", object:', small)
        self.assertIn('return', small)
        self.assertIn('commitQueue(', large)
        self.assertNotIn('.base64EncodedString()', large)

    def test_workspace_file_stays_on_disk_and_hash_is_rechecked(self):
        remote = source('WorkspaceRemote.swift')
        prepare = function(remote, 'static func prepare(', 'static func finish(')
        self.assertNotIn('Data(contentsOf:', prepare)
        self.assertIn('RepoQueue.addingUploadBytes', prepare)
        self.assertIn('snapshotFileSHA256', prepare)
        api = source('GitHub.swift')
        helper = function(api, 'private func uploadGitBlobFile(', 'func history(')
        self.assertIn('192 * 1024', helper)
        self.assertIn('session.upload(for: uploadRequest, fromFile: bodyFile)', helper)
        self.assertIn('expectedSHA256', helper)
        self.assertNotIn('Data(contentsOf:', helper)

    def test_preflight_is_transactional_and_precedes_blob_writes(self):
        ui = source('UploadView.swift')
        select = function(ui, 'private func select(_ result:', '@MainActor private func preflightCommit()')
        self.assertNotIn('queue.append(PendingRepoItem', select)
        self.assertLess(select.index('RepoQueue.addingUploadBytes(actual'), select.index('queue.append(contentsOf: pending)'))
        self.assertIn('if !accepted', select)
        self.assertIn('removeItem(at: file.deletingLastPathComponent())', select)
        replacement = function(ui, 'private func adoptGeneratedDeb(', 'private func queuedUploadBytes(')
        self.assertLess(replacement.index('queuedUploadBytes(excluding: id)'), replacement.index('queue[index].replaceLocal('))
        self.assertLess(replacement.index('queuedUploadBytes(excluding: id)'), replacement.index('queue.append(PendingRepoItem'))
        api = source('GitHub.swift')
        batch = function(api, 'func commitQueue(', 'func identify(')
        self.assertLess(batch.index('RepoQueue.addingUploadBytes(size, to: totalBytes)'), batch.index('for (item, file, size) in preparedItems'))
        self.assertLess(batch.index('for (item, file, size) in preparedItems'), batch.index('uploadGitBlobFile('))
        remote_deb = function(api, 'func saveRemoteDeb(', 'func downloadFile(')
        self.assertIn('commitQueue(', remote_deb)
        self.assertNotIn('Data(contentsOf:', remote_deb)
        self.assertNotIn('base64', remote_deb)
        direct = function(api, 'func commit(_ repo:', 'func delete(')
        self.assertIn('sha: sha, head: head', direct)
        self.assertIn('"auto_init": true', function(api, 'func createRepository(', 'func createRelease('))

    def test_workspace_requires_push_permission_before_encoding_or_upload(self):
        body = function(source('GitHub.swift'), 'func commitWorkspace(', 'func commitQueue(')
        gate = body.index('try await requireWriteAccess(binding.repo)')
        self.assertLess(gate, body.index('FileManager.default.createDirectory'))
        self.assertLess(gate, body.index('uploadGitBlobFile('))
        small = function(source('GitHub.swift'), 'func commit(_ repo:', 'let repo = try RepositoryInput.parse(repo)')
        self.assertNotIn('workspaceHead(', small)
        self.assertNotIn('commitQueue(', small)
        self.assertIn('o["sha"] = sha', small)
        self.assertIn('o["branch"] = branch', small)

    def test_release_and_download_limits_are_preserved_without_troll_mode(self):
        queue = source('RepoQueue.swift')
        self.assertNotIn('maximumTrollPluginBytes', queue)
        api = source('GitHub.swift')
        self.assertIn('超过下载单文件 100 MiB', api)
        self.assertNotIn('func trollPublish(', api)
        self.assertIn('2 * 1024 * 1024 * 1024', source('ReleaseManagement.swift'))

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler unavailable; fixture runs on macOS CI')
    def test_production_swift_boundaries(self):
        queue = source('RepoQueue.swift').split('struct StreamingBlobHash', 1)[0].replace('import CryptoKit', '')
        fixture = (ROOT / 'tests/RepositoryUploadLimitsFixture.swift').read_text()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            main = root / 'main.swift'
            metadata = function(source('UploadView.swift'), '    private func queuedUploadBytes(', '    @MainActor private func openTargetPicker(')
            metadata = 'struct UploadQueueMetadataFixture {\n var queue: [PendingRepoItem]\n func queuedUploadBytes(' + metadata + '}\n'
            main.write_text(queue + metadata + fixture)
            subprocess.run(['swiftc', str(main), '-o', str(root / 'limits')], check=True)
            subprocess.run([str(root / 'limits')], check=True)


if __name__ == '__main__':
    unittest.main()
