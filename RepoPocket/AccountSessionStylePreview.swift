#if DEBUG
import SwiftUI

/// Isolated simulator fixture: exercises the application's real account sheet.
struct AccountSessionStylePreview: View {
    static var configuration: URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral
        value.protocolClasses = [AccountPreviewProtocol.self]
        return value
    }
    @EnvironmentObject private var presentation: AccountPresentation
    @State private var prepared = false
    @State private var active = ""
    var body: some View {
        VStack {
            Text(active).accessibilityIdentifier("fixture-active-account")
            Button("打开账号管理") { presentation.showing = true }
        }.task {
            guard !prepared else { return }; prepared = true
            UserDefaults.standard.removeObject(forKey: AccountStore.accountsKey)
            for id in ["301", "302", "303"] { CredentialStore.clear(account: id) }
            try? AccountStore.record(GitHubAccount(id: "301", login: "fixture-alice", avatarURL: nil))
            try? AccountStore.record(GitHubAccount(id: "302", login: "fixture-bob", avatarURL: nil))
            AccountStore.activate("301")
            active = AccountStore.activeID
        }.onReceive(NotificationCenter.default.publisher(for: .githubAccountChanged)) { _ in active = AccountStore.activeID }
    }
}

/// Intercept every request in this fixture; no live GitHub traffic or credentials.
private final class AccountPreviewProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let user = request.url?.host == "api.github.com" && request.url?.path == "/user"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-charlie"
        let bytes = Data((user ? #"{"id":303,"login":"fixture-charlie","avatar_url":null}"# : #"{"message":"Fixture request rejected"}"#).utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: user ? 200 : 401, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
