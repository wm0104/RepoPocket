#if DEBUG
import SwiftUI

/// Real Actions UI and mutation transport, restricted to an in-process fixture.
struct WorkflowSelectionStylePreview: View {
    @State private var api: GitHub?
    @State private var error = ""
    var body: some View {
        Group {
            if let api { NavigationStack { WorkflowRunsView(api: api, repo: "fixture-owner/sample", branch: "main") } }
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
    static func reset() { lock.lock(); defer { lock.unlock() }; deleted = []; rejected = false }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private static var runs: [[String: Any]] {
        (1...4).map { id in
            var row: [String: Any] = ["id": id, "name": "Build IPA", "run_number": id, "head_sha": "fixture-sha",
                "created_at": "2026-10-20T00:00:00Z", "run_started_at": "2026-10-20T00:00:00Z",
                "updated_at": "2026-10-20T00:08:00Z", "event": "workflow_dispatch"]
            row["display_title"] = ["失败运行一", "失败运行二", "进行中的运行", "另一分支成功运行"][id-1]
            row["head_branch"] = id == 4 ? "feature" : "main"
            row["status"] = id == 3 ? "in_progress" : "completed"
            if id != 3 { row["conclusion"] = id == 4 ? "success" : "failure" }
            return row
        }
    }
    override func startLoading() {
        let path = request.url?.path ?? "", root = "/repos/fixture-owner/sample"
        let allowed = request.url?.host == "api.github.com" && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-workflow"
        var code = 200, payload: [String: Any] = [:]
        if allowed, request.httpMethod == "GET", path == root {
            payload = ["id": 1, "name": "sample", "full_name": "fixture-owner/sample", "html_url": "https://github.com/fixture-owner/sample", "permissions": ["push": true]]
        } else if allowed, request.httpMethod == "GET", path == root + "/actions/runs" {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let branch = query.first { $0.name == "branch" }?.value, status = query.first { $0.name == "status" }?.value
            Self.lock.lock(); let deleted = Self.deleted; Self.lock.unlock()
            let rows = Self.runs.filter { !deleted.contains($0["id"] as! Int) && (branch == nil || $0["head_branch"] as? String == branch) && (status == nil || $0["conclusion"] as? String == status) }
            payload = ["workflow_runs": query.first { $0.name == "page" }?.value == "1" ? rows : []]
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
