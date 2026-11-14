#if DEBUG
import SwiftUI

/// Real editor and inbox; every API request is intercepted, and all writes fail closed.
struct ReleaseEditorStylePreview: View {
    @State private var api: GitHub?
    @State private var attempted = false
    @State private var error = ""
    @State private var audit = ""
    private static let attachmentName = "release-editor-fixture.txt"

    var body: some View {
        Group {
            if let api {
                VStack(spacing: 0) {
                    ReleaseEditorView(api: api, repo: "fixture-owner/sample", original: nil, initialBranch: "main")
                    VStack(spacing: 4) {
                        Text(audit).font(.caption2).accessibilityIdentifier("release-fixture-audit")
                        HStack {
                            Button("收起键盘") {
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            }.accessibilityIdentifier("release-fixture-dismiss-keyboard")
                            Button("检查只读请求") { audit = ReleaseEditorPreviewProtocol.audit }
                                .accessibilityIdentifier("release-fixture-check")
                            Button("模拟账号切换") { AccountStore.activate("release-editor-other") }
                                .accessibilityIdentifier("release-fixture-switch")
                        }.font(.caption)
                    }.padding(4).background(.regularMaterial)
                }
            } else if !error.isEmpty {
                Text(error).accessibilityIdentifier("release-fixture-error")
            } else { ProgressView("准备发行表单测试…") }
        }.task {
            guard !attempted else { return }; attempted = true
            do {
                ReleaseEditorPreviewProtocol.reset()
                let account = "release-editor-preview"
                try CredentialStore.save("fixture-release-editor", account: account)
                try AccountStore.record(.init(id: account, login: "fixture-owner", avatarURL: nil))
                AccountStore.activate(account)
                let inbox = try ShareInboxStore.live()
                // Remove only our own old fixture, never unrelated inbox files.
                for item in try inbox.items() where item.name == Self.attachmentName { try inbox.remove(item) }
                let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try Data("Nonempty release editor attachment\n".utf8).write(to: source)
                defer { try? FileManager.default.removeItem(at: source) }
                _ = try inbox.importFile(source, name: Self.attachmentName)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [ReleaseEditorPreviewProtocol.self]
                let client = GitHub(configuration: configuration)
                client.login = "fixture-owner"
                audit = ReleaseEditorPreviewProtocol.audit
                api = client
            } catch { self.error = error.localizedDescription }
        }
    }
}

private final class ReleaseEditorPreviewProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var writes = 0
    private static var rejected = 0
    private static var reads = 0
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        writes = 0; rejected = 0; reads = 0
    }
    static var audit: String {
        lock.lock(); defer { lock.unlock() }
        return "writes=\(writes); rejected=\(rejected); reads=\(reads)"
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        var status = 403
        var payload = #"{"message":"Read-only release editor fixture rejected request"}"#
        let authenticated = url.scheme == "https" && url.host == "api.github.com"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-release-editor"
        if method == "GET", authenticated {
            switch url.path {
            case "/repos/fixture-owner/sample":
                let push = !ProcessInfo.processInfo.arguments.contains("-release-editor-denied")
                payload = #"{"id":1,"name":"sample","full_name":"fixture-owner/sample","html_url":"https://github.com/fixture-owner/sample","default_branch":"main","permissions":{"push":\#(push)}}"#
                status = 200
            case "/repos/fixture-owner/sample/branches":
                payload = #"[{"name":"main","commit":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},{"name":"test","commit":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}]"#
                status = 200
            case "/repos/fixture-owner/sample/git/ref/heads/main":
                payload = #"{"object":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}"#
                status = 200
            case "/repos/fixture-owner/sample/releases":
                payload = "[]"; status = 200
            default: break
            }
        }
        Self.lock.lock()
        if method != "GET" { Self.writes += 1 }
        if status != 200 { Self.rejected += 1 } else { Self.reads += 1 }
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
