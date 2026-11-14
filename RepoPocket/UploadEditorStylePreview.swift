#if DEBUG
import SwiftUI

/// Real upload/editor screens and archive parsing; intercepted API writes fail closed.
struct UploadEditorStylePreview: View {
    @State private var api: GitHub?
    @State private var file: URL?
    @State private var attempted = false
    @State private var error = ""
    @State private var audit = ""

    var body: some View {
        Group {
            if let api, let file {
                VStack(spacing: 0) {
                    UploadView(api: api, initialRepo: "fixture-owner/sample", directory: "debs", initialBranch: "test", initialFile: file, openedFromFolder: true)
                    HStack {
                        Text(audit).accessibilityIdentifier("upload-fixture-audit")
                        Button("检查只读请求") { audit = UploadEditorPreviewProtocol.audit }
                            .accessibilityIdentifier("upload-fixture-check")
                        if ProcessInfo.processInfo.arguments.contains("-upload-picker-gated") {
                            Button("恢复响应") { UploadEditorPreviewProtocol.resume(); audit = UploadEditorPreviewProtocol.audit }
                                .accessibilityIdentifier("upload-fixture-resume")
                        }
                    }.font(.caption2).padding(4).background(.regularMaterial)
                }
            } else if !error.isEmpty { Text(error).accessibilityIdentifier("upload-fixture-error") }
            else { ProgressView("准备上传编辑测试…") }
        }.onReceive(NotificationCenter.default.publisher(for: .init("UploadFixtureHeld"))) { _ in
            audit = UploadEditorPreviewProtocol.audit
        }.task {
            guard !attempted else { return }; attempted = true
            do {
                UploadEditorPreviewProtocol.reset()
                let account = "upload-editor-preview"
                try CredentialStore.save("fixture-upload-editor", account: account)
                try AccountStore.record(.init(id: account, login: "fixture-owner", avatarURL: nil))
                AccountStore.activate(account)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let source = folder.appendingPathComponent("upload-editor-fixture.deb")
                try Data(base64Encoded: Self.archive)!.write(to: source)
                // Two ordinary files exercise the real multi-select inbox import path.
                let inbox = try ShareInboxStore.live()
                for item in try inbox.items() where ["upload-fixture-one.txt", "upload-fixture-two.txt"].contains(item.name) { try inbox.remove(item) }
                for name in ["upload-fixture-one.txt", "upload-fixture-two.txt"] {
                    let url = folder.appendingPathComponent(name)
                    try Data((name + "\n").utf8).write(to: url)
                    _ = try inbox.importFile(url, name: name)
                }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [UploadEditorPreviewProtocol.self]
                let client = GitHub(configuration: configuration); client.login = "fixture-owner"
                file = source; audit = UploadEditorPreviewProtocol.audit; api = client
            } catch { self.error = error.localizedDescription }
        }
    }
    // Hand-built ar: debian-binary 2.0, gzip USTAR control, empty gzip data tar.
    private static let archive = "ITxhcmNoPgpkZWJpYW4tYmluYXJ5LyAgMCAgICAgICAgICAgMCAgICAgMCAgICAgMTAwNjQ0ICA0ICAgICAgICAgYAoyLjAKY29udHJvbC50YXIuZ3ovIDAgICAgICAgICAgIDAgICAgIDAgICAgIDEwMDY0NCAgMjc0ICAgICAgIGAKH4sIAAAAAAAC/+3P30rDMBQG8F7nKfICa6t0E3I3GOKNY+Cf+5Ad17C2CSepzrc3S62K94rg94OQ5CTkyykr44bIrit+Tp2smibPyfe5bi6XH+upfrWsV4Wsi18whqg5RRb/006boz6Qksb1JZ107zsqR985vV882VMcmcRW9+nCQy7K6/fiI3GwblDyoqzFmk1rI5nziZLWt24gFxaae7GhYNj6mO9udbTPJKf3Je1tdCyZDkzh/JicE2+1HWIaxGoOlJ81sR5j674cTXtxlz6QY+5fSB+D2LF1bOOrki7n607cuJ587reN0QdVVXPPqf9qji8AAAAAAAAAAAAAAAAAAAAAAAD+vjc61H6VACgAAGRhdGEudGFyLmd6LyAgICAwICAgICAgICAgICAwICAgICAwICAgICAxMDA2NDQgIDI5ICAgICAgICBgCh+LCAAAAAAAAv9jYBgFo2AUjFQAAC6vte8ABAAACg=="
}

private final class UploadEditorPreviewProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var writes = 0
    private static var rejected = 0
    private static var reads = 0
    private static var headReads = 0
    private static var held: UploadEditorPreviewProtocol?
    private var delayed: (Int, String)?
    static func reset() { lock.lock(); defer { lock.unlock() }; writes = 0; rejected = 0; reads = 0; headReads = 0; held = nil }
    static func resume() {
        lock.lock(); let request = held; held = nil; lock.unlock()
        if let request, let (status, payload) = request.delayed { request.delayed = nil; request.deliver(status, payload) }
    }
    static var audit: String {
        lock.lock(); defer { lock.unlock() }
        return "writes=\(writes); rejected=\(rejected); reads=\(reads); pending=\(held == nil ? 0 : 1)"
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, method = request.httpMethod ?? "GET"
        var status = 403
        var payload = #"{"message":"Read-only upload fixture rejected request"}"#
        if method == "GET", url.scheme == "https", url.host == "api.github.com",
           request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-upload-editor" {
            switch url.path {
            case "/repos/fixture-owner/sample":
                payload = #"{"id":1,"name":"sample","full_name":"fixture-owner/sample","html_url":"https://github.com/fixture-owner/sample","default_branch":"main","permissions":{"push":true}}"#
                status = 200
            case "/repos/fixture-owner/sample/git/ref/heads/test", "/repos/fixture-owner/sample/git/ref/heads/main":
                payload = #"{"object":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}"#; status = 200
            case "/repos/fixture-owner/sample/git/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":
                payload = #"{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","tree":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}"#; status = 200
            case "/repos/fixture-owner/sample/git/trees/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb":
                let existing = ProcessInfo.processInfo.arguments.contains("-upload-editor-collision")
                    ? #",{"path":"debs/upload-editor-fixture.deb","mode":"100644","type":"blob","sha":"cccccccccccccccccccccccccccccccccccccccc","size":496}"# : ""
                payload = #"{"truncated":false,"tree":[{"path":"debs","mode":"040000","type":"tree","sha":"dddddddddddddddddddddddddddddddddddddddd"}\#(existing)]}"#
                status = 200
            case "/repos/fixture-owner/sample/contents/debs":
                payload = "[]"; status = 200
            case "/repos/fixture-owner/sample/contents":
                payload = #"[{"name":"debs","path":"debs","sha":"dddddddddddddddddddddddddddddddddddddddd","type":"dir","size":0}]"#; status = 200
            default: break
            }
        }
        Self.lock.lock()
        if url.path.contains("/git/ref/heads/") {
            Self.headReads += 1
            // Initial binding reads HEAD twice; picker open once; selection's check is fourth.
            if Self.headReads == 4 && ProcessInfo.processInfo.arguments.contains("-upload-picker-gated") {
                delayed = (status, payload); Self.held = self; Self.lock.unlock()
                DispatchQueue.main.async { NotificationCenter.default.post(name: .init("UploadFixtureHeld"), object: nil) }
                return
            }
        }
        Self.lock.unlock()
        deliver(status, payload)
    }
    private func deliver(_ status: Int, _ payload: String) {
        let url = request.url!, method = request.httpMethod ?? "GET"
        Self.lock.lock()
        if method != "GET" { Self.writes += 1 }
        if status == 200 { Self.reads += 1 } else { Self.rejected += 1 }
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
