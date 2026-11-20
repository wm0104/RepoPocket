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
    private static var beforeReads = 0
    private static var blobReads = 0
    private static var compareReads = 0
    private static var rejected = 0
    private static let sha = "abc1234" + String(repeating: "a", count: 33)
    private static let parent = String(repeating: "b", count: 40)
    private static let otherParent = String(repeating: "c", count: 40)
    private static let blob = String(repeating: "d", count: 40)
    private static let afterPNG = "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGN4n+GEFTEMLQkAH2BmQRdeMT8AAAAASUVORK5CYII="
    private static let beforePNG = "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGNwyniPFTEMLQkAyNFmQZ3qgaUAAAAASUVORK5CYII="
    private static var mode: String {
        for mode in ["removed", "empty", "missing", "binary", "large", "media-renamed", "media-added",
                     "media-removed", "media-merge", "media-merge-unproven"]
            where ProcessInfo.processInfo.arguments.contains("-commit-file-" + mode) { return mode }
        return "renamed"
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        fileReads = 0; beforeReads = 0; blobReads = 0; compareReads = 0; rejected = 0
    }
    static var audit: String {
        lock.lock(); defer { lock.unlock() }
        return "fileReads=\(fileReads); beforeReads=\(beforeReads); blobReads=\(blobReads); compareReads=\(compareReads); rejected=\(rejected)"
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let mode = Self.mode, media = mode.hasPrefix("media-")
        let merge = mode.hasPrefix("media-merge")
        let filename = media ? "目录/历史.png" : "目录/历史.swift"
        let statusName = mode.hasSuffix("removed") ? "removed" : (mode.hasSuffix("added") ? "added" : "renamed")
        let previousFilename = media ? "旧目录/old.png" : "旧目录/old.swift"
        let firstParentFilename = merge ? "第一父/base.png" : previousFilename
        let base = "/repos/fixture-owner/history"
        let contents = base + "/contents/"
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let accept = request.value(forHTTPHeaderField: "Accept")
        let limit = SourceTextRules.byteLimit
        let largeSize = limit + 1024
        var status = 403
        var payload: [String: Any] = ["message": "Unexpected historical-file request"]
        var raw: Data?
        var headers = ["Content-Type": "application/json"]
        if request.httpMethod == "GET", url.scheme == "https", url.host == "api.github.com",
           request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-commit-file" {
            if url.path == base + "/commits/abc1234" {
                status = 200
                var row: [String: Any] = ["filename": filename, "status": statusName, "additions": 1, "deletions": 1]
                if statusName == "renamed" { row["previous_filename"] = previousFilename }
                if !media { row["patch"] = "@@ -1 +1 @@\n-old\n+let value = 1" }
                let parents: [[String: String]] = merge ? [["sha": Self.parent], ["sha": Self.otherParent]] : [["sha": Self.parent]]
                payload = ["sha": Self.sha, "commit": ["message": "历史文件测试", "author": ["name": "Fixture"]],
                           "parents": parents, "files": [row]]
            } else if merge, url.path == base + "/compare/" + Self.parent + "..." + Self.sha,
                      accept == "application/vnd.github+json",
                      query.count == 2, query.contains(URLQueryItem(name: "per_page", value: "1")),
                      query.contains(URLQueryItem(name: "page", value: "1")) {
                Self.lock.lock(); Self.compareReads += 1; Self.lock.unlock()
                status = 200
                payload = ["base_commit": ["sha": Self.parent],
                           "merge_base_commit": ["sha": mode.hasSuffix("unproven") ? Self.otherParent : Self.parent],
                           "files": [["filename": filename, "previous_filename": firstParentFilename,
                                      "status": "renamed", "additions": 0, "deletions": 0]]]
            } else if accept == "application/vnd.github.object+json", query.count == 1 {
                let isBefore = media && !mode.hasSuffix("unproven") && statusName != "added" &&
                    url.path == contents + (statusName == "removed" ? filename : firstParentFilename) &&
                    query[0] == URLQueryItem(name: "ref", value: Self.parent)
                let isAfter = statusName != "removed" && url.path == contents + filename &&
                    query[0] == URLQueryItem(name: "ref", value: Self.sha)
                if isBefore || isAfter {
                    Self.lock.lock(); Self.fileReads += 1; if isBefore { Self.beforeReads += 1 }; Self.lock.unlock()
                    status = mode == "missing" ? 404 : 200
                    var bytes = Data("let value = \"历史完整内容\"\n// 不只是差异片段\n".utf8)
                    if media { bytes = Data(base64Encoded: isBefore ? Self.beforePNG : Self.afterPNG)! }
                    if mode == "empty" { bytes = Data() }
                    if mode == "binary" { bytes = Data([0, 255]) }
                    let responsePath = String(url.path.dropFirst(contents.count))
                    payload = ["name": (responsePath as NSString).lastPathComponent, "path": responsePath,
                               "type": "file", "sha": Self.blob, "size": mode == "large" ? largeSize : bytes.count,
                               "encoding": mode == "large" ? "none" : "base64",
                               "content": mode == "large" ? "" : bytes.base64EncodedString()]
                    if status == 404 { payload = ["message": "Not Found"] }
                }
            } else if mode == "large", url.path == base + "/git/blobs/" + Self.blob, query.isEmpty,
                      accept == "application/vnd.github.raw+json", request.value(forHTTPHeaderField: "Range") == "bytes=0-\(limit)" {
                Self.lock.lock(); Self.blobReads += 1; Self.lock.unlock()
                status = 206
                headers = ["Content-Type": "application/octet-stream", "Content-Range": "bytes 0-\(limit)/\(largeSize)"]
                var bytes = Data("let value = \"历史超大文件开头\"\n".utf8)
                // ASCII lines keep this range valid UTF-8 even when the last one is cut short.
                let filler = Data(("// " + String(repeating: "a", count: 60) + "\n").utf8)
                while bytes.count < limit + 1 { bytes.append(filler) }
                raw = Data(bytes.prefix(limit + 1))
            }
        }
        if status == 403 { Self.lock.lock(); Self.rejected += 1; Self.lock.unlock() }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: raw ?? (try! JSONSerialization.data(withJSONObject: payload)))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
