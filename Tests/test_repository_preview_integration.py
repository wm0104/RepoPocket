import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')


class RepositoryPreviewIntegrationTests(unittest.TestCase):
    def test_file_detail_uses_preview_separately_from_explicit_download(self):
        view = source('RepoPocketApp.swift').split('struct FileView: View {', 1)[1].split('struct SettingsView:', 1)[0]
        read = view.split('private func read(', 1)[1].split('private func save(', 1)[0]
        self.assertIn('api.repositoryFilePreview(repo, path: entry.path, ref: branch, allowEditing: true)', read)
        self.assertIn('RepositoryFilePreviewBody(preview: preview, path: entry.path)', view)
        self.assertIn('RepositoryFilePreviewRules.canPreview(path: entry.path)', view)
        self.assertNotIn('requireAuthorization', read)
        self.assertIn('try await downloads.requireAuthorization()', view.split('private func download()', 1)[1])
        self.assertIn('guard writable, !busy, editable', view)
        self.assertIn('if case let .text(content, _, sha?) = loaded', read)
        self.assertIn('.task(id: previewReload)', view)

    def test_raw_read_is_bounded_and_pinned_to_the_metadata_blob(self):
        api = source('GitHub.swift').split('func repositoryFilePreview(', 1)[1].split('func commit(_ repo:', 1)[0]
        for required in ('application/vnd.github.object+json', 'application/vnd.github.raw+json',
                         'entry.path.utf8.elementsEqual(path.utf8)', 'entry.type == "file"',
                         '/git/blobs/', 'bytes=0-', 'for try await byte in bytes',
                         'defer { bytes.task.cancel() }', 'Content-Range', 'Task.checkCancellation()',
                         'GitHubAPIRedirectPolicy()', 'cachePolicy = .reloadIgnoringLocalCacheData'):
            self.assertIn(required, api)
        self.assertNotIn('download_url', api)
        self.assertNotIn('DownloadStore', api)


if __name__ == '__main__':
    unittest.main()
