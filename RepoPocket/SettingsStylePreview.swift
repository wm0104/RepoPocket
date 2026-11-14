#if DEBUG
import SwiftUI

/// Uses the shipping settings view with an isolated account and no credential/network.
struct SettingsStylePreview: View {
    @State private var api: GitHub?
    @StateObject private var checker = UpdateChecker()
    @AppStorage("appearance.mode") private var appearance = "system"
    var body: some View {
        Group {
            if let api {
                VStack(spacing: 0) {
                    SettingsView(api: api, updateChecker: checker)
                    Text(appearance).accessibilityIdentifier("settings-theme-probe").font(.caption2)
                }
            } else { ProgressView("准备设置测试…") }
        }.task {
            guard api == nil else { return }
            let account = "settings-style-preview"
            CredentialStore.clear(account: account)
            try? AccountStore.record(.init(id: account, login: "fixture-settings", avatarURL: nil))
            AccountStore.activate(account)
            if !ProcessInfo.processInfo.arguments.contains("-preserve-settings-theme-preview") { appearance = "system" }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SettingsPreviewProtocol.self]
            let client = GitHub(configuration: configuration)
            client.login = "fixture-settings"
            client.profile = User(id: nil, login: "fixture-settings", avatar_url: nil, name: "设置测试账号", followers: 7, following: 6)
            api = client
        }
    }
}

private final class SettingsPreviewProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"message":"Settings fixture denies network"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
