#if DEBUG
import SwiftUI

/// Real Actions UI and mutation transport, restricted to an in-process fixture.
struct WorkflowSelectionStylePreview: View {
    @State private var api: GitHub?
    @State private var error = ""
    var body: some View {
        Group {
            if let api {
                AppNavigationStack {
                    WorkflowRunsView(api: api, repo: "fixture-owner/sample", branch: "main")
                        .safeAreaInset(edge: .bottom) {
                            if ProcessInfo.processInfo.arguments.contains("-workflow-refresh-preview") {
                                HStack {
                                    Button("模拟运行中") { WorkflowSelectionPreviewProtocol.setPhase("in_progress") }
                                    Button("模拟完成") { WorkflowSelectionPreviewProtocol.setPhase("completed") }
                                    Button("模拟刷新失败") { WorkflowSelectionPreviewProtocol.failNextRefresh() }
                                }.font(.caption).frame(minHeight: 44).buttonStyle(.borderless)
                                    .background(Color(uiColor: .secondarySystemBackground))
                            }
                        }
                }
            }
            else if !error.isEmpty { Text(error) }
            else { ProgressView("准备工作流测试") }
        }.task {
            guard api == nil, error.isEmpty else { return }
            do {
                let id = "workflow-selection-preview"
                try CredentialStore.save("fixture-workflow", account: id)
                try AccountStore.record(.init(id: id, login: "fixture-owner", avatarURL: nil)); AccountStore.activate(id)
                WorkflowSelectionPreviewProtocol.reset()
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [WorkflowSelectionPreviewProtocol.self]
                let value = GitHub(configuration: config); value.login = "fixture-owner"; api = value
            } catch { self.error = error.localizedDescription }
        }
    }
}

private final class WorkflowSelectionPreviewProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var deleted = Set<Int>()
    private static var rejected = false
    private static var phase = "queued"
    private static var failNext = false
    static func reset() { lock.lock(); defer { lock.unlock() }; deleted = []; rejected = false; phase = "queued"; failNext = false }
    static func setPhase(_ value: String) { lock.lock(); defer { lock.unlock() }; phase = value }
    static func failNextRefresh() { lock.lock(); defer { lock.unlock() }; failNext = true }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private static var runs: [[String: Any]] {
        lock.lock(); let phase = Self.phase; lock.unlock()
        let paginated = ProcessInfo.processInfo.arguments.contains("-workflow-pagination-preview")
        return (1...(paginated ? 30 : 4)).map { id in
            var row: [String: Any] = ["id": id, "name": "Build IPA", "run_number": id, "head_sha": "fixture-sha",
                "created_at": "2026-10-20T00:00:00Z", "run_started_at": "2026-10-20T00:00:00Z",
                "updated_at": "2026-10-20T00:08:00Z", "event": "workflow_dispatch"]
            row["display_title"] = ["失败运行一", "失败运行二", "进行中的运行", "另一分支成功运行"][(id-1) % 4]
            row["head_branch"] = id == 4 ? "feature" : "main"
            row["status"] = id == 3 ? "in_progress" : "completed"
            if id != 3 { row["conclusion"] = id == 4 ? "success" : "failure" }
            if id == 3, ProcessInfo.processInfo.arguments.contains("-workflow-refresh-preview") {
                row["display_title"] = "刷新回归运行"; row["status"] = phase
                row["conclusion"] = phase == "completed" ? "success" : nil
            }
            return row
        }
    }
    private static let inputsYAML = """
    name: Build IPA
    on:
      workflow_dispatch:
        inputs:
          run_title: {type: string, description: Preview title, required: true, default: Preview run}
          channel: {type: choice, options: [stable, beta], default: stable}
          dry_run: {type: boolean, default: true}
          count: {type: number, default: 3}
          environment: {type: environment, default: preview}
    jobs:
      preview:
        runs-on: ubuntu-latest
        env: {MODE: preview}
        steps:
          - run: |
              echo 'This workflow exists only inside URLProtocol fixtures'
    """
    override func startLoading() {
        let path = request.url?.path ?? "", root = "/repos/fixture-owner/sample"
        let allowed = request.url?.host == "api.github.com" && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-workflow"
        var code = 200
        var payload: Any = [String: Any]()
        let cornerFixture = ProcessInfo.processInfo.arguments.contains("-workflow-filter-corners-preview")
        let workflow: [String: Any] = ["id": 41, "name": "Build IPA", "path": ".github/workflows/build.yml", "state": "active"]
        if allowed, cornerFixture, request.httpMethod == "GET", path == root + "/actions/workflows" {
            payload = ["workflows": [workflow]]
        } else if allowed, cornerFixture, request.httpMethod == "GET", path == root + "/actions/workflows/41" {
            payload = workflow
        } else if allowed, cornerFixture, request.httpMethod == "GET", path == root + "/branches" {
            payload = [["name": "main", "commit": ["sha": String(repeating: "a", count: 40)]]]
        } else if allowed, cornerFixture, request.httpMethod == "GET", path == root + "/branches/main" {
            payload = ["name": "main", "commit": ["sha": String(repeating: "a", count: 40)]]
        } else if allowed, cornerFixture, request.httpMethod == "GET", path == root + "/contents/.github/workflows/build.yml" {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.first(where: { $0.name == "ref" })?.value == "main" {
                payload = ["type": "file", "encoding": "base64", "content": Data(Self.inputsYAML.utf8).base64EncodedString(),
                           "sha": "fixture-workflow-schema", "size": Self.inputsYAML.utf8.count]
            } else { code = 404 }
        } else if allowed, cornerFixture, request.httpMethod == "GET", path == root + "/environments" {
            payload = ["total_count": 1, "environments": [["name": "preview"]]]
        } else if allowed, cornerFixture, request.httpMethod == "POST", path == root + "/actions/workflows/41/dispatches" {
            // URLProtocol can receive a streamed body instead of httpBody on iOS; the
            // dispatch payload is checked separately by WorkflowDispatchRules tests.
            code = 204
        } else if allowed, request.httpMethod == "GET", path == root {
            payload = ["id": 1, "name": "sample", "full_name": "fixture-owner/sample", "html_url": "https://github.com/fixture-owner/sample", "permissions": ["push": true]]
        } else if allowed, request.httpMethod == "GET", path == root + "/actions/runs" {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let branch = query.first { $0.name == "branch" }?.value, status = query.first { $0.name == "status" }?.value
            Self.lock.lock(); let deleted = Self.deleted; let fail = Self.failNext; Self.failNext = false; Self.lock.unlock()
            let rows = Self.runs.filter {
                !deleted.contains($0["id"] as! Int) && (branch == nil || $0["head_branch"] as? String == branch) && (status == nil || $0["conclusion"] as? String == status)
                    && (!ProcessInfo.processInfo.arguments.contains("-workflow-refresh-preview") || $0["id"] as? Int == 3)
            }
            payload = ["workflow_runs": query.first { $0.name == "page" }?.value == "1" ? rows : []]
            if fail { code = 500; payload = ["message": "模拟刷新失败"] }
        } else if allowed, path.hasPrefix(root + "/actions/runs/"), let id = Int(path.split(separator: "/").last ?? ""), (1...4).contains(id) {
            if request.httpMethod == "GET" { payload = Self.runs[id-1] }
            else if request.httpMethod == "DELETE" {
                Self.lock.lock()
                if id == 2 && !Self.rejected { Self.rejected = true; code = 403; payload = ["message": "测试拒绝删除，请重试"] }
                else { Self.deleted.insert(id); code = 204 }
                Self.lock.unlock()
            } else { code = 403 }
        } else { code = 403 }
        let bytes = code == 204 ? Data() : try! JSONSerialization.data(withJSONObject: payload)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
