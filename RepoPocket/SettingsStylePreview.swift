#if DEBUG
import SwiftUI

/// Uses the shipping settings view with an isolated account and no credential/network.
struct SettingsStylePreview: View {
    @State private var api: GitHub?
    @StateObject private var checker = UpdateChecker()
    @AppStorage("appearance.mode") private var appearance = "system"
    @State private var showingAuthorizationSheet = false
    var body: some View {
        Group {
            if let api {
                VStack(spacing: 0) {
                    SettingsView(api: api, updateChecker: checker)
                    Text(appearance).accessibilityIdentifier("settings-theme-probe").font(.caption2)
                    if ProcessInfo.processInfo.arguments.contains("-settings-folder-sheet-preview") {
                        Button("打开模态授权回归") { showingAuthorizationSheet = true }
                            .accessibilityIdentifier("settings-open-modal-authorization")
                    }
                }
                .sheet(isPresented: $showingAuthorizationSheet) { SettingsFolderAuthorizationPreview() }
            } else { ProgressView("准备设置测试…") }
        }.task {
            guard api == nil else { return }
            if ProcessInfo.processInfo.arguments.contains("-settings-folder-sheet-preview") {
                let defaults = UserDefaults.standard
                var overrides = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
                overrides["RepoPocket.download.folder.v1"] = false
                defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
            }
            let account = "settings-style-preview"
            CredentialStore.clear(account: account)
            try? AccountStore.record(.init(id: account, login: "fixture-settings", avatarURL: nil))
            AccountStore.activate(account)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SettingsPreviewProtocol.self]
            let client = GitHub(configuration: configuration)
            client.login = "fixture-settings"
            client.profile = User(id: nil, login: "fixture-settings", avatar_url: nil, name: "设置测试账号", followers: 7, following: 6)
            api = client
        }
    }
}

private struct SettingsFolderAuthorizationPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var authorization: Task<Void, Never>?
    @State private var state = "尚未请求"
    var body: some View {
        AppNavigationStack {
            VStack(spacing: 20) {
                Text("模态下载授权").accessibilityIdentifier("settings-modal-parent")
                Text(state).accessibilityIdentifier("settings-modal-authorization-state")
                Button("请求下载目录") {
                    authorization = Task { @MainActor in
                        state = "等待目录授权"
                        defer { authorization = nil }
                        do { try await DownloadStore.shared.requireAuthorization(); state = "授权完成" }
                        catch { state = RefreshFailure.isCancellation(error) ? "已取消" : error.localizedDescription }
                    }
                }.disabled(authorization != nil).accessibilityIdentifier("settings-modal-request-folder")
                Button("关闭父模态") { dismiss() }
            }.navigationTitle("真实模态授权回归")
        }.onDisappear { authorization?.cancel(); authorization = nil }
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
