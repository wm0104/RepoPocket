"""Run the shipping homepage transport against scripted GitHub replies (WSL/macOS)."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SRC = Path(__file__).resolve().parents[1] / 'RepoPocket'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc')

HARNESS = r'''
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
// MODELS
@MainActor enum AccountStore { static var activeID = "A", generation = UUID() }
@MainActor enum CredentialStore { static func read(account: String) -> String { "token-" + account } }
@MainActor final class Session {
    var code = 200, headers = [String: String](), body = #"{"workflow_runs":[]}"#
    var requests = 0, afterRequest: (() -> Void)?
    func data(for r: URLRequest, delegate: URLSessionTaskDelegate?) async throws -> (Data, URLResponse) {
        requests += 1
        let u = r.url!
        precondition(u.absoluteString == "https://api.github.com/repos/o/r/actions/runs?per_page=1")
        precondition(r.httpMethod == "GET" && r.cachePolicy == .reloadIgnoringLocalCacheData)
        precondition(delegate is GitHubAPIRedirectPolicy)
        precondition(r.value(forHTTPHeaderField: "Authorization") == "Bearer token-" + AccountStore.activeID)
        let reply = HTTPURLResponse(url: u, statusCode: code, httpVersion: nil, headerFields: headers)!
        afterRequest?()
        return (Data(body.utf8), reply)
    }
}
@MainActor final class GitHub {
    let accountID = AccountStore.activeID, accountGeneration = AccountStore.generation
    let session = Session()
    // TRANSPORT
    var deadline: Date? { Self.workflowPollDeadlines[accountID] }
}
@main struct Fixture {
    @MainActor static func main() async throws {
        let repo = "o/r", empty = #"{"workflow_runs":[]}"#
        let api = GitHub()
        api.session.body = #"{"workflow_runs":[{"id":2,"run_number":1,"head_sha":"a","status":"queued","created_at":"t"},{"id":9,"run_number":2,"head_sha":"b","status":"completed","created_at":"t"}]}"#
        let first = try await api.latestRepositoryWorkflowRun(repo); precondition(first?.id == 2)
        api.session.body = empty
        let none = try await api.latestRepositoryWorkflowRun(repo); precondition(none == nil)
        api.session.body = "{}"
        do { _ = try await api.latestRepositoryWorkflowRun(repo); fatalError("malformed response accepted") }
        catch is DecodingError {}

        // Use absolute deadlines and bracket relative ones, rather than timing CI to the millisecond.
        enum Delay { case none, seconds(Double), until(Date) }
        let epoch = Int(Date().timeIntervalSince1970) + 3600, reset = Date(timeIntervalSince1970: Double(epoch))
        for (code, headers, reason, expected) in [
            (403, [:], "Resource not accessible by integration", .none),
            (429, [:], "", .seconds(60)), (403, [:], "You have exceeded a secondary rate limit", .seconds(60)),
            (429, ["Retry-After":"4"], "", .seconds(4)),
            (429, ["Retry-After":"Fri, 01 Jan 2100 00:00:00 GMT"], "", .until(Date(timeIntervalSince1970: 4102444800))),
            (429, ["Retry-After":"3", "X-RateLimit-Remaining":"0", "X-RateLimit-Reset":String(epoch)], "", .until(reset)),
            (200, ["X-RateLimit-Remaining":"0", "X-RateLimit-Reset":String(epoch)], "", .until(reset)),
            (200, ["X-RateLimit-Remaining":"1", "X-RateLimit-Reset":String(epoch)], "", .none)
        ] as [(Int, [String:String], String, Delay)] {
            AccountStore.activeID = UUID().uuidString
            let current = GitHub()
            current.session.code = code; current.session.headers = headers
            current.session.body = code == 200 ? empty : #"{"message":""# + reason + #""}"#
            let before = Date()
            do {
                let value = try await current.latestRepositoryWorkflowRun(repo)
                precondition(code == 200 && value == nil)
            } catch let error as GitHubAPIError { precondition(error.status == code && error.reason == reason) }
            switch expected {
            case .none: precondition(current.deadline == nil)
            case .until(let date): precondition(current.deadline == date)
            case .seconds(let seconds):
                precondition((before.addingTimeInterval(seconds)...Date().addingTimeInterval(seconds)).contains(current.deadline!))
            }
            if case .seconds(60) = expected {
                let original = current.deadline
                let reopened = GitHub()
                let task = Task { try await reopened.latestRepositoryWorkflowRun(repo) }
                try await Task.sleep(nanoseconds: 20_000_000)
                task.cancel()
                do { _ = try await task.value; fatalError("wait was not cancelled") } catch is CancellationError {}
                precondition(reopened.session.requests == 0 && reopened.deadline == original)
            }
        }
        AccountStore.activeID = "expiry"
        let exhausted = GitHub()
        exhausted.session.code = 429; exhausted.session.headers = ["Retry-After":"1"]
        do { _ = try await exhausted.latestRepositoryWorkflowRun(repo); fatalError() } catch is GitHubAPIError {}
        let reopened = GitHub(), deadline = exhausted.deadline!
        _ = try await reopened.latestRepositoryWorkflowRun(repo)
        precondition(Date() >= deadline && reopened.session.requests == 1)
        reopened.session.afterRequest = { AccountStore.generation = UUID() }
        do { _ = try await reopened.latestRepositoryWorkflowRun(repo); fatalError("old response accepted") } catch is AppError {}
        do { _ = try await reopened.latestRepositoryWorkflowRun(repo); fatalError("old session sent") } catch is AppError {}
        precondition(reopened.session.requests == 2)
    }
}
'''


class WorkflowPollTransportTests(unittest.TestCase):
    @unittest.skipUnless(SWIFTC, 'requires swiftc')
    def test_single_run_errors_account_backoff_and_cancellation(self):
        github = (SRC / 'GitHub.swift').read_text(encoding='utf-8')
        self.assertTrue('func latestRepositoryWorkflowRun(' in github, 'missing single-run transport')
        def method(signature):
            start = github.index('    ' + signature)
            return github[start:github.index('\n    }\n', start) + 7]
        transport = '\n'.join(method(sig) for sig in ['static func component(', 'static func repoPath(',
            'private func url(', 'private func request(', 'private func ensureActiveAccount(', 'private func check('])
        transport += github[github.index('    private static var workflowPollDeadlines'):github.index('    func repositoryPathCommits(')]
        models = (SRC / 'NativeRepositoryModels.swift').read_text(encoding='utf-8')
        models = (github[github.index('struct AppError:'):github.index('enum CredentialStore')] +
                  'struct GitHubMessage: Decodable { let message: String }\n' +
                  models[models.index('struct WorkflowRuns:'):models.index('struct WorkflowCancellationState')] +
                  models[models.index('struct WorkflowRun:'):models.index('struct WorkflowJobs:')])
        with tempfile.TemporaryDirectory() as tmp:
            harness, binary = Path(tmp) / 'Fixture.swift', Path(tmp) / 'fixture'
            redirect = (SRC / 'OfficialUpdateRedirectPolicy.swift').read_text(encoding='utf-8')
            harness.write_text(HARNESS.replace('// MODELS', redirect + models).replace('// TRANSPORT', transport), encoding='utf-8')
            subprocess.run([SWIFTC, '-swift-version', '5', '-parse-as-library', str(harness),
                            str(SRC / 'RepositoryInput.swift'), '-o', str(binary)], check=True, timeout=120)
            subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == '__main__':
    unittest.main()
