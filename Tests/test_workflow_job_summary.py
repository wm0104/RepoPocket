from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def production_program():
    fixture = (ROOT / 'Tests/Fixtures/workflow-job-summary.html').read_text(encoding='utf-8')
    source = '\n'.join((ROOT / path).read_text(encoding='utf-8') for path in [
        'RepoPocket/RepositoryInput.swift', 'RepoPocket/OfficialUpdateRedirectPolicy.swift', 'RepoPocket/WorkflowJobSummary.swift'])
    return '''import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
@MainActor final class GitHub { var isCurrentSession = true }
''' + source + '\n' + r'''
final class SummaryProtocol: URLProtocol {
    static var body = Data()
    static var code = 200
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.code, httpVersion: nil,
            headerFields: ["Content-Type":"text/html"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct Run {
    static func reject(_ data: Data) {
        do { _ = try WorkflowJobSummaryRules.html(data); preconditionFailure("Invalid summary was accepted") } catch {}
    }
    @MainActor static func main() async throws {
        let fixture = #"""
FIXTURE
"""#
        let html = try WorkflowJobSummaryRules.html(Data(fixture.utf8))
        precondition(html.contains("插件管理：查看清单") && html.contains("<table>") && html.contains("<div>Assembler</div>"))
        precondition(html.contains("https://github.com/wm0104/Apelin") && !html.contains("Unrelated page content"))
        precondition(!html.contains("查看日志") && !html.contains("<details>"))
        let two = try WorkflowJobSummaryRules.html(Data((fixture + fixture.replacingOccurrences(of: "137111420225", with: "137111420226")).utf8))
        precondition(two.components(separatedBy: "插件管理：查看清单").count == 3)
        reject(Data("<html>Sign in to view logs</html>".utf8))
        reject(Data("<div class='markdown-body'>Not a job summary</div>".utf8))
        reject(Data(fixture.replacingOccurrences(of: "</job-summary>", with: "").utf8))
        reject(Data(repeating: 65, count: WorkflowJobSummaryRules.byteLimit + 1))
        for repo in ["../secret", "https://evil.invalid/owner/repo", "owner/repo/actions"] {
            do { _ = try WorkflowJobSummaryRules.url(repo, run: 1); preconditionFailure() } catch {}
        }
        do { _ = try WorkflowJobSummaryRules.url("owner/repo", run: 0); preconditionFailure() } catch {}
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SummaryProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = GitHub()
        SummaryProtocol.body = Data(fixture.utf8)
        let fetched = try await api.workflowJobSummary("owner/repo", run: 7, publicSession: session)
        precondition(fetched == html)
        precondition(SummaryProtocol.requests.last?.url?.absoluteString == "https://github.com/owner/repo/actions/runs/7")
        precondition(SummaryProtocol.requests.last?.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(SummaryProtocol.requests.last?.httpShouldHandleCookies == false)
        SummaryProtocol.code = 403
        do { _ = try await api.workflowJobSummary("owner/repo", run: 7, publicSession: session); preconditionFailure() } catch {}
        let before = SummaryProtocol.requests.count
        api.isCurrentSession = false
        do { _ = try await api.workflowJobSummary("owner/repo", run: 7, publicSession: session); preconditionFailure() } catch {}
        precondition(SummaryProtocol.requests.count == before)
        print("PASS real job-summary structure, nested HTML/tables/links, no page-content substitution, bounds, no API token/cookies, HTTP failure and stale account")
    }
}
'''.replace('FIXTURE', fixture)


class WorkflowJobSummaryTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'native summary transport/HTML fixture runs on CI or explicit Linux probe')
    def test_real_job_summary_content_and_fallback_conditions(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'summary.swift'
            source.write_text(production_program(), encoding='utf-8')
            binary = Path(folder) / 'summary'
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=30)

    def test_login_result_returns_to_the_existing_reader_and_drops_on_account_change(self):
        source = (ROOT / 'RepoPocket/WorkflowJobSummaryView.swift').read_text(encoding='utf-8')
        self.assertIn('WorkflowSummaryLoginView(', source)
        self.assertIn('登录并读取摘要', source)
        self.assertIn('authenticatedSummary', source)
        self.assertIn('context == summaryContext && api.isCurrentSession', source)
        self.assertIn('onReceive(NotificationCenter.default.publisher(for: .githubAccountChanged))', source)
        self.assertIn('authenticatedSummary = nil; showingLogin = false', source)
        self.assertIn('ReadmeHTMLView(html: html', source)
        self.assertIn('ContentZoomControls(scale:', source)

    def test_reader_reuses_existing_zoom_and_browser_instead_of_an_image(self):
        source = (ROOT / 'RepoPocket/WorkflowJobSummaryView.swift').read_text(encoding='utf-8')
        for component in ['ReadmeHTMLView(', 'ContentZoomControls(scale:', 'scrolling: true', 'ReadingLinkDestination(', 'InAppLinkButton(', 'api.isCurrentSession']:
            self.assertIn(component, source)
        for custom in ['MagnificationGesture(', 'UIPinchGestureRecognizer(', 'UIImage(', '.rotationEffect(']:
            self.assertNotIn(custom, source)


if __name__ == '__main__':
    unittest.main()
