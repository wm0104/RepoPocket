import SwiftUI

@MainActor final class AccountPresentation: ObservableObject {
    @Published var showing = false
}

struct AccountManagementView: View {
    @EnvironmentObject private var presentation: AccountPresentation
    @Environment(\.dismiss) private var dismiss
    @StateObject private var api = GitHub()
    @State private var accounts = AccountStore.accounts
    @State private var pendingRemoval: GitHubAccount?
    @State private var token = ""
    @State private var busy = false
    @State private var verification: Task<Void, Never>?
    @State private var error = ""
    private func close() {
        verification?.cancel(); verification = nil; token = ""
        presentation.showing = false; dismiss()
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("账号") {
                    if accounts.isEmpty { Text("尚无已验证账号").softGroupedRow(top: true, bottom: true) }
                    ForEach(accounts) { account in
                        HStack(spacing: 12) {
                            GitHubAvatar(url: account.avatarURL, size: 32)
                            Text(account.login); Spacer()
                            if account.id == AccountStore.activeID { Image(systemName: "checkmark") }
                            else { Button("切换") { AccountStore.activate(account.id) }.buttonStyle(.borderless).disabled(busy) }
                            Button(role: .destructive) { pendingRemoval = account } label: { Image(systemName: "trash").frame(width: 44, height: 44) }.buttonStyle(.borderless).disabled(busy)
                        }.softGroupedRow(top: account.id == accounts.first?.id, bottom: account.id == accounts.last?.id)
                    }
                }
                Section {
                    NavigationLink("使用 GitHub 浏览器授权") { DeviceOAuthView(api: api) }.softGroupedRow(top: true)
                    NavigationLink("添加 / 更新 GitHub 账号") {
                        Form {
                            SecureField("粘贴你自己的 Token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow(top: true)
                            Button("验证并安全保存") {
                                guard !busy else { return }
                                let credential = token
                                busy = true
                                verification = Task { @MainActor in
                                    defer { busy = false }
                                    do {
                                        try await TokenVerification.submit(credential) { try await api.addAccount(token: $0) }
                                        token = ""
                                        accounts = AccountStore.accounts
                                        close()
                                    } catch {
                                        // Keep the pasted Token so a retry needs no re-typing.
                                        if !Task.isCancelled { self.error = error.localizedDescription }
                                    }
                                }
                            }.disabled(busy || token.isEmpty).softGroupedRow()
                            if busy { ProgressView().softGroupedRow() }
                            Link("在 GitHub 创建 Token", destination: URL(string: "https://github.com/settings/tokens")!).softGroupedRow(bottom: true)
                        }.navigationTitle("添加 / 更新账号").onDisappear { token = "" }
                    }.softGroupedRow()
                    Text("仅移除本机凭据，不会删除 GitHub 账号、远端仓库或本地工作区。").font(.caption).softGroupedRow(bottom: error.isEmpty)
                    if !error.isEmpty { Text(error).font(.caption).softGroupedRow(bottom: true) }
                }
            }.navigationTitle("账号管理")
            .toolbar { Button("完成") { close() } }
            .confirmationDialog("移除此账号及本机 Token？", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
                Button("移除本机账号", role: .destructive) {
                    guard let account = pendingRemoval, !busy else { return }
                    let active = account.id == AccountStore.activeID
                    pendingRemoval = nil
                    if active { close() }
                    AccountStore.remove(account.id)
                    accounts = AccountStore.accounts
                }
                Button("取消", role: .cancel) { pendingRemoval = nil }
            } message: { Text("仅移除本机账号，不会删除 GitHub 账号、远端仓库或本地工作区。") }
        }.onDisappear { verification?.cancel(); token = "" }
        .onReceive(NotificationCenter.default.publisher(for: .githubAccountChanged)) { _ in
            accounts = AccountStore.accounts
        }
    }
}
