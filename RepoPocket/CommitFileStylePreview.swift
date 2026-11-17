#if DEBUG
import SwiftUI

/// Exact-SHA read fixture; every unexpected URL or write is rejected.
struct CommitFileStylePreview: View {
    @State private var api: GitHub?
    @State private var error = ""
    @State private var audit = ""
    @State private var attempted = false
    var body: some View {
        VStack(spacing: 0) {
            if let api {
                AppNavigationStack {
                    CommitDetailView(api: api, repo: "fixture-owner/history", sha: "abc1234")
                }
                HStack {
                    Text(audit).accessibilityIdentifier("commit-file-audit")
                    Button("检查请求") { audit = CommitFilePreviewProtocol.audit }
                    Button("切换账号") { AccountStore.activate("legacy") }
                }.font(.caption2).padding(4)
            } else if !error.isEmpty { Text(error) }
            else { ProgressView() }
        }.task {
            guard !attempted else { return }; attempted = true
            do {
                CommitFilePreviewProtocol.reset()
                let account = "commit-file-preview"
                try CredentialStore.save("fixture-commit-file", account: account)
                try AccountStore.record(.init(id: account, login: "fixture-owner", avatarURL: nil))
                AccountStore.activate(account)
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [CommitFilePreviewProtocol.self]
                api = GitHub(configuration: config)
            } catch { self.error = error.localizedDescription }
        }
    }
}

private final class CommitFilePreviewProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var fileReads = 0
    private static var rejected = 0
    private static let sha = "abc1234" + String(repeating: "a", count: 33)
    private static var mode: String {
        for mode in ["removed", "empty", "missing", "binary", "large"] where ProcessInfo.processInfo.arguments.contains("-commit-file-" + mode) { return mode }
        return "renamed"
    }
    static func reset() { lock.lock(); defer { lock.unlock() }; fileReads = 0; rejected = 0 }
    static var audit: String {
        lock.lock(); defer { lock.unlock() }
        return "fileReads=\(fileReads); rejected=\(rejected)"
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let filename = "目录/历史.swift"
        var status = 403
        var payload: [String: Any] = ["message": "Unexpected historical-file request"]
        if request.httpMethod == "GET", url.scheme == "https", url.host == "api.github.com",
           request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-commit-file" {
            if url.path == "/repos/fixture-owner/history/commits/abc1234" {
                status = 200
                payload = ["sha": Self.sha, "commit": ["message": "历史文件测试", "author": ["name": "Fixture"]],
                           "files": [["filename": filename, "previous_filename": "旧目录/old.swift",
                                      "status": Self.mode == "removed" ? "removed" : "renamed", "additions": 1, "deletions": 1,
                                      "patch": "@@ -1 +1 @@\n-old\n+let value = 1"]]]
            } else if url.path == "/repos/fixture-owner/history/contents/" + filename,
                      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ref" })?.value == Self.sha {
                Self.lock.lock(); Self.fileReads += 1; Self.lock.unlock()
                status = Self.mode == "missing" ? 404 : 200
                let bytes = Self.mode == "empty" ? Data() : (Self.mode == "binary" ? Data([0, 255]) : Data("let value = \"历史完整内容\"\n// 不只是差异片段\n".utf8))
                payload = status == 404 ? ["message": "Not Found"] : ["name": "历史.swift", "path": filename, "type": "file", "sha": String(repeating: "b", count: 40), "size": Self.mode == "large" ? SourceTextRules.byteLimit + 1 : bytes.count, "encoding": "base64", "content": bytes.base64EncodedString()]
            }
        }
        if status == 403 { Self.lock.lock(); Self.rejected += 1; Self.lock.unlock() }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
