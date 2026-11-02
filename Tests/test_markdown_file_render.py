"""File-page Markdown rendering: server GFM HTML first, local MarkdownUI fallback (static)."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import unittest

api = (REPO_ROOT / 'RepoPocket/GitHub.swift').read_text()
views = (REPO_ROOT / 'RepoPocket/ReadingViews.swift').read_text()


class MarkdownFileRenderTests(unittest.TestCase):
    def test_request_is_post_markdown_with_gfm_context(self):
        self.assertIn('func renderedMarkdownHTML(_ source: String, repo: String) async throws -> String', api)
        body = api.split('func renderedMarkdownHTML(', 1)[1].split('\n    }\n', 1)[0]
        self.assertIn('url("/markdown")', body)
        self.assertIn('method: "POST"', body)
        self.assertIn('"mode": "gfm"', body)
        self.assertIn('"context": canonical', body)
        self.assertIn('"text": String(decoding: source.utf8.prefix(CommunityRules.markdownByteLimit)', body)
        self.assertIn('let canonical = try RepositoryInput.parse(repo)', body)
        # Read-only: no extra permission gate, no write access requirement.
        self.assertNotIn('requireWriteAccess', body)
        self.assertNotIn('ensureWrite', body)
        # Bounded response (2 MiB) and a timeout so the page can fall back.
        self.assertIn('try ReadmeDocumentRules.renderedHTML(bytes)', body)
        self.assertIn('r.timeoutInterval = 20', body)
        self.assertIn('GitHubAPIRedirectPolicy()', body)

    def test_file_page_prefers_html_then_falls_back(self):
        page = views.split('struct FileReadingView: View {', 1)[1]
        self.assertIn('if !isMarkdown { SourceCodeView(text: text, filename: path) }', page)
        self.assertNotIn('Toggle(', page)
        self.assertIn('@State private var renderedHTML: String?', page)
        self.assertIn('else if let renderedHTML, renderedKey == requestKey {', page)
        self.assertIn('ReadmeHTMLView(html: renderedHTML, baseURL: baseURL, mediaBaseURL: mediaBaseURL', page)
        self.assertIn('guard renderedKey == requestKey else { return }', page)
        self.assertIn('self.renderedHTML = nil', page)
        self.assertIn('.task(id: requestKey)', page)
        self.assertIn('let html = try? await api.renderedMarkdownHTML(text, repo: repo)', page)
        # Offline and signed-out states keep the local MarkdownUI rendering.
        self.assertIn('guard isMarkdown, let api, api.isCurrentSession,', page)
        self.assertIn('defer { if !Task.isCancelled { htmlAttempted = true } }', page)
        self.assertIn('guard !Task.isCancelled, api.isCurrentSession, !html.isEmpty', page)
        self.assertIn('CommunityMarkdown(text: text, baseURL: baseURL, imageBaseURL: mediaBaseURL, api: api)', page)
        self.assertLess(page.index('else if let renderedHTML'), page.index('CommunityMarkdown(text: text'))
        # Links use the blob base, images the raw base, exactly like the README section.
        self.assertIn('CommunityRules.readingBase(repo, branch: branch, file: path, raw: false)', page)
        self.assertIn('CommunityRules.readingBase(repo, branch: branch, file: path, raw: true)', page)

    def test_source_toggle_and_dependencies_unchanged(self):
        project = (REPO_ROOT / 'project.yml').read_text()
        for package in ('MarkdownUI', 'NetworkImage', 'swift-cmark', 'SnapshotTesting', 'ZIPFoundation'):
            self.assertIn(package + ':', project)
        self.assertNotIn('marked', project.lower())
        # Non-Markdown files retain their source view; only the file Markdown toggle is removed.
        self.assertIn('SourceCodeView(text: text, filename: path)', views)


if __name__ == '__main__':
    unittest.main()
