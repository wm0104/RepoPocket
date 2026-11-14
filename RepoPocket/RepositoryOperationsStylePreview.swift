#if DEBUG
import SwiftUI

/// Shipping history/PR views with an isolated official-host fixture; no live writes.
struct RepositoryOperationsStylePreview: View {
    @State private var api: GitHub?
    @State private var error = ""
    @State private var writes = 0
    var body: some View {
        Group {
            if let api {
                AppNavigationStack {
                    List {
                        NavigationLink("远端提交整理") { RemoteHistoryView(api: api, repo: "fixture-owner/sample", branch: "main") }
                            .accessibilityIdentifier("fixture-open-history")
                        NavigationLink("PR合并方式") { PullRequestMergeView(api: api, repo: "fixture-owner/sample", number: 7) }
                            .accessibilityIdentifier("fixture-open-pr-merge")
                    }.navigationTitle("仓库操作回归")
                }.safeAreaInset(edge: .bottom) {
                    Text("写入请求：\(writes)").font(.caption).frame(maxWidth: .infinity, minHeight: 32)
                        .background(Color(uiColor: .secondarySystemBackground)).accessibilityIdentifier("fixture-repository-writes")
                }
            } else if !error.isEmpty { Text(error) }
            else { ProgressView("准备仓库操作预览…") }
        }.preferredColorScheme(.light)
        .onReceive(NotificationCenter.default.publisher(for: .init("RepositoryOperationsFixture.write"))) { _ in writes += 1 }
        .task {
            guard api == nil, error.isEmpty else { return }
            do {
                let id = "repository-operations-preview"
                try CredentialStore.save("fixture-repository-operations", account: id)
                try AccountStore.record(.init(id: id, login: "fixture-owner", avatarURL: nil)); AccountStore.activate(id)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [RepositoryOperationsPreviewProtocol.self]; configuration.urlCache = nil
                api = GitHub(configuration: configuration)
            } catch { self.error = error.localizedDescription }
        }
    }
}

private final class RepositoryOperationsPreviewProtocol: URLProtocol {
    static let head = String(repeating: "c", count: 40), base = String(repeating: "a", count: 40)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? "", method = request.httpMethod ?? "GET"
        let body: [String: Any]
        var status = 200
        if request.url?.host != "api.github.com" { body = ["message": "Fixture refuses external hosts"]; status = 403 }
        else if method == "GET", path == "/repos/fixture-owner/sample" {
            body = ["node_id": "R_fixture", "full_name": "fixture-owner/sample", "default_branch": "main",
                "permissions": ["push": true], "allow_merge_commit": true, "allow_squash_merge": true,
                "allow_rebase_merge": !ProcessInfo.processInfo.arguments.contains("-pr-disable-rebase-preview")]
        } else if method == "GET", path == "/repos/fixture-owner/sample/git/ref/heads/main" {
            body = ["object": ["sha": Self.head]]
        } else if method == "GET", path == "/repos/fixture-owner/sample/commits" {
            let author = ["name": "Fixture", "email": "fixture@example.test", "date": "2026-11-13T00:00:00Z"]
            let values = [("c", "b", "完成最终修复"), ("b", "a", "撤销实验并保留功能"), ("a", "", "保留的上游基线")]
            let commits: [[String: Any]] = values.map { value, parent, message in
                ["sha": String(repeating: value, count: 40), "commit": ["message": message, "tree": ["sha": String(repeating: "f", count: 40)], "author": author, "committer": author],
                    "parents": parent.isEmpty ? [] : [["sha": String(repeating: parent, count: 40)]]]
            }
            respond(commits); return
        } else if method == "GET", path == "/repos/fixture-owner/sample/pulls/7" {
            body = ["number": 7, "state": "open", "draft": false, "merged": false, "mergeable": true, "rebaseable": true,
                "mergeable_state": "clean", "head": ["ref": "feature", "sha": Self.head, "repo": ["full_name": "fixture-owner/sample"]],
                "base": ["ref": "main", "sha": Self.base, "repo": ["full_name": "fixture-owner/sample"]]]
        } else if method == "POST", path == "/graphql", query()?.hasPrefix("query") == true {
            body = ["data": ["repository": ["pullRequest": ["mergeStateStatus": ProcessInfo.processInfo.arguments.contains("-pr-merge-blocked-preview") ? "BLOCKED" : "CLEAN",
                "reviewDecision": NSNull(), "headRefOid": Self.head, "baseRefOid": Self.base]]]]
        } else {
            if method != "GET" { NotificationCenter.default.post(name: .init("RepositoryOperationsFixture.write"), object: nil) }
            body = ["message": "Preview does not perform this operation"]; status = 403
        }
        respond(body, status: status)
    }
    private func query() -> String? {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0, bytes.count + count <= 1_048_576 else { return nil }
                if count == 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["query"] as? String
    }
    private func respond(_ object: Any, status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let data = try! JSONSerialization.data(withJSONObject: object)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
