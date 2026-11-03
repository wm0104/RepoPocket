"""Workflow dispatch: production transport/state, isolated URLProtocol; no live writes."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def production_method(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
        end += 1
    return source[start:end]


class WorkflowDispatchTests(unittest.TestCase):
    def test_push_choice_opens_selection_only_after_success_and_keeps_current_branch(self):
        view = (ROOT / 'RepoPocket/LocalProjectView.swift').read_text()
        self.assertIn('Button("仅推送")', view)
        self.assertIn('Button("推送后运行工作流…")', view)
        sync = production_method(view, '    private func sync(')
        self.assertLess(sync.index('try await LocalGitEngine.shared.run'), sync.index('.workflow('))
        self.assertIn('state.error.isEmpty', sync)
        self.assertIn('state.fresh', sync, 'Cancelled snapshot reads must not open a workflow sheet')
        self.assertIn('current.status.branch', sync)
        self.assertNotIn('dispatchWorkflow(', sync, 'Selection still requires an explicit confirmation')
        dispatch = (ROOT / 'RepoPocket/WorkflowViews.swift').read_text().split('struct WorkflowDispatchView:', 1)[1].split('struct WorkflowRunView:', 1)[0]
        self.assertIn('initialBranch', dispatch)
        self.assertIn('state.ref = initialBranch', dispatch)

    def test_entry_selection_confirmation_and_refresh(self):
        view = (ROOT / 'RepoPocket/WorkflowViews.swift').read_text()
        dispatch = view.split('struct WorkflowDispatchView: View {', 1)[1].split('struct WorkflowRunView:', 1)[0]
        self.assertIn('Button("运行工作流")', view)
        self.assertIn('WorkflowDispatchView(api: api, repo: repo)', view)
        self.assertIn('dispatchedBranch = ref', view)
        self.assertIn('currentBranchOnly = true', view)
        self.assertIn('failedOnly = false', view)
        self.assertIn('? displayedBranch : ""', view)
        for text in ['SoftGroupRows', 'Picker("工作流"', 'Picker("分支"', 'target.repo',
                     'target.workflow.path', 'target.ref', '.confirmationDialog', 'state.submit(target',
                     'state.loadWorkflows', 'state.loadBranches', '运行名称会作为 run_title']:
            self.assertIn(text, dispatch)
        self.assertIn('TextField("运行名称（选填）", text: $state.runTitle)', dispatch)
        self.assertNotIn('softGroupedRow', dispatch, 'Use the original SoftGroupRows component')
        source = (ROOT / 'RepoPocket/WorkflowDispatch.swift').read_text()
        self.assertIn('branches.contains(where: { $0.name == ref })', source)
        self.assertIn('confirmation = nil; busy = true; attempted = true', source)
        self.assertIn('batch.count == 100', source)
        github = (ROOT / 'RepoPocket/GitHub.swift').read_text()
        transport = github.split('    // Dispatch uses the account-bound session and refuses redirects, including reads.\n', 1)[1].split('    func searchUsers', 1)[0]
        self.assertIn('delegate: OfficialUpdateRedirectPolicy()', transport)
        self.assertIn('inputs.isEmpty ? ["ref": $0] : ["ref": $0, "inputs": inputs]', transport)
        self.assertIn('inputs: title.isEmpty ? [:] : ["run_title": title]', transport)
        # The only free-form input allowed is the optional run title.
        self.assertNotIn('"text"', transport)
        self.assertIn('"run_title": title', transport)
        self.assertNotIn('requireWriteAccess', transport, 'Actions write errors must not report Contents permission')

    @unittest.skipUnless(shutil.which('swiftc'), 'swiftc absent: native URLProtocol tests NOT executed')
    def test_native_production_network_and_state(self):
        github = (ROOT / 'RepoPocket/GitHub.swift').read_text()
        methods = '\n'.join(production_method(github, signature) for signature in [
            '    static func component(', '    static func repoPath(',
            '    private func url(', '    private func request(',
            '    var isCurrentSession:', '    private func ensureActiveAccount()'])
        transport = github.split('    // Dispatch uses the account-bound session and refuses redirects, including reads.\n', 1)[1].split('    func searchUsers', 1)[0]
        source = HARNESS.replace('// PRODUCTION_TRANSPORT', methods + '\n' + transport)
        source += '\n' + (ROOT / 'RepoPocket/RepositoryInput.swift').read_text()
        source += '\n' + (ROOT / 'RepoPocket/OfficialUpdateRedirectPolicy.swift').read_text()
        source += '\n' + (ROOT / 'RepoPocket/WorkflowDispatch.swift').read_text()
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / 'main.swift'
            main.write_text(source)
            executable = str(Path(folder) / 'workflow-dispatch')
            subprocess.run(['swiftc', '-parse-as-library', str(main), '-o', executable], check=True)
            subprocess.run([executable], check=True, timeout=60)


HARNESS = r'''
import Foundation
import Combine
struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
struct GitHubMessage: Decodable { let message: String }
struct DesktopBranch: Decodable, Identifiable { let name: String; var id: String { name } }
@MainActor enum AccountStore { static var activeID = "fixture"; static var generation = UUID() }
@MainActor enum CredentialStore { static func read(account: String) -> String { "fixture-only" } }
@MainActor final class GitHub {
    let accountID = AccountStore.activeID
    let accountGeneration = AccountStore.generation
    let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DispatchFixture.self]
        session = URLSession(configuration: config)
    }
    // PRODUCTION_TRANSPORT
}
final class DispatchFixture: URLProtocol {
    static var requests: [URLRequest] = []
    static var status = 204
    static var push = true
    static var workflowState = "active"
    static var failPOST = false
    static var onRequest: ((URLRequest) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            precondition(request.url?.host == "api.github.com", "Never allow live hosts")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
            Self.requests.append(request)
            Self.onRequest?(request)
            let path = request.url!.path
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "page" }?.value
            var code = 200
            var object: Any = [:]
            if request.httpMethod == "POST" {
                if Self.failPOST {
                    client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
                }
                code = Self.status; object = ["message": "fixture rejection"]
            } else if path.hasSuffix("/actions/workflows") {
                precondition(request.url!.query!.contains("per_page=100"))
                let ids = page == "1" ? Array(1...100) : [101]
                object = ["workflows": ids.map { ["id": $0, "name": "Workflow \($0)", "path": ".github/workflows/\($0).yml", "state": $0 == 2 ? "disabled_manually" : "active"] as [String: Any] }]
            } else if path.hasSuffix("/branches") {
                let names = page == "1" ? (0..<100).map { "branch-\($0)" } : ["feature/中文"]
                object = names.map { ["name": $0] }
            } else if path.contains("/actions/workflows/") {
                object = ["id": 101, "name": "Workflow 101", "path": ".github/workflows/101.yml", "state": Self.workflowState]
            } else if path.contains("/branches/") {
                object = ["name": "feature/中文"]
            } else { object = ["permissions": ["push": Self.push]] }
            let bytes = code == 204 ? Data() : try! JSONSerialization.data(withJSONObject: object)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}
'''

HARNESS += r'''
@main struct Run {
    @MainActor static func prepared(_ api: GitHub) async -> WorkflowDispatchState {
        let state = WorkflowDispatchState()
        await state.loadWorkflows("someone/any-repo", api: api)
        precondition(state.workflows.count == 100 && state.moreWorkflows)
        await state.loadWorkflows("someone/any-repo", api: api)
        precondition(state.workflows.count == 101 && !state.moreWorkflows)
        await state.loadBranches("someone/any-repo", api: api)
        precondition(state.branches.count == 100 && state.moreBranches)
        await state.loadBranches("someone/any-repo", api: api)
        precondition(state.branches.count == 101 && !state.moreBranches)
        state.workflowID = 101; state.ref = "feature/中文"
        return state
    }
    @MainActor static func main() async throws {
        let api = GitHub(); defer { api.session.invalidateAndCancel() }
        let state = await prepared(api)
        state.ref = "typed-not-loaded"
        precondition(state.target("someone/any-repo", api: api) == nil)
        state.ref = "feature/中文"; state.workflowID = 2
        precondition(state.target("someone/any-repo", api: api) == nil)
        state.workflowID = 101
        precondition(state.target("different/repository", api: api) == nil)
        let target = state.target("someone/any-repo", api: api)!
        var accepted = 0
        let first = Task { @MainActor in await state.submit(target, api: api) { _ in accepted += 1 } }
        let second = Task { @MainActor in await state.submit(target, api: api) { _ in accepted += 1 } }
        await first.value; await second.value
        precondition(accepted == 1 && !state.result.isEmpty && state.attempted)
        let posts = DispatchFixture.requests.filter { $0.httpMethod == "POST" }
        precondition(posts.count == 1)
        let post = posts[0]
        precondition(post.url!.absoluteString == "https://api.github.com/repos/someone/any-repo/actions/workflows/101/dispatches")
        let body = try JSONSerialization.jsonObject(with: DispatchFixture.body(post)) as! [String: String]
        precondition(body == ["ref": "feature/中文"])
        precondition(post.value(forHTTPHeaderField: "Content-Type") == "application/json")
        precondition(post.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        precondition(state.target("someone/any-repo", api: api) == nil)
        await state.submit(target, api: api) { _ in preconditionFailure("Consumed target") }
        precondition(DispatchFixture.requests.filter { $0.httpMethod == "POST" }.count == 1)

        for (code, help) in [(401, "重新登录"), (403, "Actions: write"), (404, "仓库"), (422, "workflow_dispatch"), (200, "204"), (202, "204"), (500, "未知")] {
            DispatchFixture.status = code
            let denied = await prepared(api)
            let confirmation = denied.target("someone/any-repo", api: api)!
            await denied.submit(confirmation, api: api) { _ in preconditionFailure("Only 204 is accepted") }
            precondition(denied.result.isEmpty && denied.error.contains(help), denied.error)
            precondition(denied.target("someone/any-repo", api: api) == nil)
        }
        DispatchFixture.status = 204; DispatchFixture.push = false
        let readonly = await prepared(api)
        let beforeDenied = DispatchFixture.requests.filter { $0.httpMethod == "POST" }.count
        await readonly.submit(readonly.target("someone/any-repo", api: api)!, api: api) { _ in preconditionFailure() }
        precondition(readonly.error.contains("Actions: write"))
        precondition(DispatchFixture.requests.filter { $0.httpMethod == "POST" }.count == beforeDenied)
        DispatchFixture.push = true; DispatchFixture.workflowState = "disabled_manually"
        let disabled = await prepared(api)
        await disabled.submit(disabled.target("someone/any-repo", api: api)!, api: api) { _ in preconditionFailure() }
        precondition(disabled.error.contains("停用"))
        precondition(DispatchFixture.requests.filter { $0.httpMethod == "POST" }.count == beforeDenied)
        DispatchFixture.workflowState = "active"; DispatchFixture.failPOST = true
        let uncertain = await prepared(api)
        await uncertain.submit(uncertain.target("someone/any-repo", api: api)!, api: api) { _ in preconditionFailure() }
        precondition(uncertain.error.contains("结果未知") && uncertain.result.isEmpty)
        precondition(uncertain.target("someone/any-repo", api: api) == nil)
        precondition(DispatchFixture.requests.filter { $0.httpMethod == "POST" }.count == beforeDenied + 1)
        DispatchFixture.failPOST = false

        // An in-flight page from the old generation must never populate a new account.
        let stale = WorkflowDispatchState()
        DispatchFixture.onRequest = { _ in AccountStore.generation = UUID() }
        await stale.loadWorkflows("someone/any-repo", api: api)
        DispatchFixture.onRequest = nil
        precondition(stale.workflows.isEmpty && stale.target("someone/any-repo", api: api) == nil)
        let requestsAfterSwitch = DispatchFixture.requests.count
        do { try await api.dispatchWorkflow(target); preconditionFailure() } catch {}
        precondition(DispatchFixture.requests.count == requestsAfterSwitch)

        let nextAPI = GitHub(); defer { nextAPI.session.invalidateAndCancel() }
        let nextState = await prepared(nextAPI)
        let oldTarget = nextState.target("someone/any-repo", api: nextAPI)!
        // Revocation between fresh permission lookup and POST prevents any write.
        DispatchFixture.onRequest = { request in
            if request.url!.path == "/repos/someone/any-repo" { AccountStore.activeID = "other-account" }
        }
        let before = DispatchFixture.requests.filter { $0.httpMethod == "POST" }.count
        await nextState.submit(oldTarget, api: nextAPI) { _ in preconditionFailure() }
        precondition(DispatchFixture.requests.filter { $0.httpMethod == "POST" }.count == before)
        precondition(nextState.result.isEmpty)
        DispatchFixture.onRequest = nil
        // Production redirect policy refuses even a same-origin POST replay.
        let redirectPolicy = OfficialUpdateRedirectPolicy()
        let location = URL(string: "https://evil.invalid/dispatches")!
        let response = HTTPURLResponse(url: post.url!, statusCode: 307, httpVersion: nil, headerFields: ["Location": location.absoluteString])!
        let dummy = nextAPI.session.dataTask(with: post)
        var refused = false
        redirectPolicy.urlSession(nextAPI.session, task: dummy, willPerformHTTPRedirection: response,
                                  newRequest: URLRequest(url: location)) { refused = $0 == nil }
        precondition(refused)
        dummy.cancel()
        // An optional run title travels with the confirmed target; it is trimmed.
        let titled = await WorkflowDispatchState.prepared(api)
        titled.runTitle = "  测试标题  "
        let titledTarget: WorkflowDispatchTarget? = titled.target("someone/any-repo", api: api)
        precondition(titledTarget?.runTitle == "测试标题")
        titled.runTitle = ""
        let untitled: WorkflowDispatchTarget? = titled.target("someone/any-repo", api: api)
        precondition(untitled?.runTitle == "")
        print("PASS production dispatch POST shape, paginated selection, permission failures, only-204 acknowledgement, account isolation, duplicate taps and no unknown-send retry; URLProtocol only")
    }
}
'''

if __name__ == '__main__':
    unittest.main()
