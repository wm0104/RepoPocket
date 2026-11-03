#if DEBUG
import SwiftUI

/// Shipping PR merge UI with an in-process transport: no GitHub request can escape.
struct RemoteBranchMergeStylePreview: View {
    @State private var api: GitHub?
    @State private var failure = ""
    var body: some View {
        Group {
            if let api {
                BranchPickerView(api: api, repo: "fixture-owner/branch-merge", current: "source", canWrite: true) { _ in }
            } else if !failure.isEmpty { Text(failure) }
            else { ProgressView("准备分支合并测试…") }
        }.task {
            guard api == nil, failure.isEmpty else { return }
            do {
                let id = "branch-merge-preview"
                try CredentialStore.save("fixture-branch-merge", account: id)
                try AccountStore.record(.init(id: id, login: "fixture-owner", avatarURL: nil))
                AccountStore.activate(id)
                MergePreviewProtocol.reset()
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [MergePreviewProtocol.self]
                let value = GitHub(configuration: config); value.login = "fixture-owner"; api = value
            } catch { failure = error.localizedDescription }
        }
    }
}

private final class MergePreviewProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var merged = false
    private static var created = false
    private static let root = "/repos/fixture-owner/branch-merge"
    private static let repo = "fixture-owner/branch-merge"
    private static let sourceSHA = String(repeating: "a", count: 40)
    private static let targetSHA = String(repeating: "b", count: 40)
    private static let mergedSHA = String(repeating: "c", count: 40)
    static func reset() { lock.lock(); created = false; merged = false; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private static func branch(_ name: String) -> [String: Any] {
        ["name": name, "commit": ["sha": name == "source" ? sourceSHA : targetSHA], "protected": false]
    }
    private static func pull(merged: Bool) -> [String: Any] {
        ["number": 7, "title": "合并来源分支", "state": merged ? "closed" : "open", "draft": false,
         "merged": merged, "mergeable": true, "mergeable_state": "clean", "merge_commit_sha": merged ? mergedSHA : targetSHA,
         "head": ["ref": "source", "sha": sourceSHA, "repo": ["full_name": repo]],
         "base": ["ref": "target", "sha": targetSHA, "repo": ["full_name": repo]],
         "html_url": "https://github.com/" + repo + "/pull/7"]
    }
    override func startLoading() {
        Self.lock.lock(); let merged = Self.merged, created = Self.created; Self.lock.unlock()
        let path = request.url?.path ?? "", method = request.httpMethod ?? "GET"
        let allowed = request.url?.host == "api.github.com" && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-branch-merge"
        var code = 200
        var object: Any = ["message": "unexpected fixture endpoint"]
        if !allowed { code = 403 }
        else if method == "GET", path == Self.root {
            object = ["id": 70, "name": "branch-merge", "full_name": Self.repo,
                "html_url": "https://github.com/" + Self.repo, "permissions": ["push": true],
                "allow_squash_merge": true, "delete_branch_on_merge": false, "default_branch": "target"]
        } else if method == "GET", path == Self.root + "/branches" {
            object = [Self.branch("source"), Self.branch("target")]
        } else if method == "GET", path.hasPrefix(Self.root + "/branches/") {
            object = Self.branch(path.hasSuffix("/source") ? "source" : "target")
        } else if method == "GET", path.hasPrefix(Self.root + "/git/ref/heads/") {
            object = ["object": ["sha": path.hasSuffix("/source") ? Self.sourceSHA : Self.targetSHA]]
        } else if method == "GET", path.hasPrefix(Self.root + "/compare/") {
            object = ["status": "ahead", "ahead_by": 1, "behind_by": 0, "total_commits": 1,
                "base_commit": ["sha": Self.targetSHA], "merge_base_commit": ["sha": Self.targetSHA],
                "commits": [["sha": Self.sourceSHA, "commit": ["message": "新增合并示例", "author": ["name": "fixture-owner"]]]],
                "files": [["filename": "demo.txt", "status": "modified", "additions": 1, "deletions": 1,
                    "patch": "@@ -1 +1 @@\n-old\n+new\n"]]]
        } else if method == "GET", path == Self.root + "/pulls" {
            object = created ? [Self.pull(merged: false)] : []
        } else if method == "POST", path == Self.root + "/pulls" {
            Self.lock.lock(); Self.created = true; Self.lock.unlock()
            code = 201; object = Self.pull(merged: false)
        } else if method == "GET", path == Self.root + "/pulls/7" {
            object = Self.pull(merged: merged)
        } else if method == "GET", path.hasSuffix("/check-runs") {
            object = ["total_count": 1, "check_runs": [["id": 71, "head_sha": Self.sourceSHA, "name": "模拟检查", "status": "completed", "conclusion": "success"]]]
        } else if method == "GET", path.hasSuffix("/status") {
            object = ["sha": Self.sourceSHA, "state": "success", "total_count": 1, "statuses": [["context": "模拟状态", "state": "success"]]]
        } else if method == "PUT", path == Self.root + "/pulls/7/merge" {
            Self.lock.lock(); Self.merged = true; Self.lock.unlock()
            object = ["merged": true, "sha": Self.mergedSHA, "message": "fixture squash success"]
        } else { code = 404 }
        do {
            let bytes = try JSONSerialization.data(withJSONObject: object)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
#endif
