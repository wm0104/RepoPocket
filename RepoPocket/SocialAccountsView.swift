import SwiftUI

@MainActor
final class SocialAccountsState: ObservableObject {
    @Published private(set) var accounts: [CommunitySocialAccount] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var editingURL: String?
    @Published var draft = ""
    @Published private(set) var error = ""
    @Published private(set) var message = ""
    private var reading: Task<Void, Never>?
    private var readID: UUID?

    @discardableResult
    func load(api: GitHub) -> Task<Void, Never>? {
        guard !busy, api.isCurrentSession else { return nil }
        cancelReading()
        let request = UUID()
        readID = request; loading = true; error = ""
        let task = Task { @MainActor in
            defer {
                if readID == request { loading = false; reading = nil; readID = nil }
            }
            do {
                try Task.checkCancellation()
                let result = try await api.ownSocialAccounts()
                guard !Task.isCancelled, api.isCurrentSession, readID == request else { return }
                accounts = result; loaded = true
            } catch {
                guard !Task.isCancelled, api.isCurrentSession, readID == request else { return }
                self.error = error.localizedDescription
            }
        }
        reading = task
        return task
    }

    func cancelReading() {
        reading?.cancel(); reading = nil; readID = nil; loading = false
    }

    func accountChanged() {
        cancelReading()
        accounts = []; loaded = false; draft = ""; editingURL = nil; error = ""; message = ""
    }

    func beginEditing(_ account: CommunitySocialAccount) {
        guard !busy, !loading, accounts.contains(where: { $0.url == account.url }) else { return }
        editingURL = account.url; draft = account.url; error = ""; message = ""
    }

    func cancelEditing() {
        guard !busy else { return }
        editingURL = nil; draft = ""
    }

    func save(api: GitHub) async {
        guard !busy, !loading, loaded, !Task.isCancelled, api.isCurrentSession else { return }
        error = ""; message = ""
        guard draft.utf8.count <= 2048, let next = CommunityRules.profileWebsiteURL(draft)?.absoluteString else {
            error = "请填写有效的社交账号网页链接，例如 https://t.me/用户名。"; return
        }
        let previous = editingURL
        guard previous != next else { message = "链接没有变化。"; return }
        guard !accounts.contains(where: { $0.url == next }) else { error = "这个链接已在列表中。"; return }
        busy = true; error = ""; message = ""; cancelReading()
        defer { busy = false }
        do {
            try Task.checkCancellation()
            guard api.isCurrentSession else { return }
            try await api.addSocialAccount(next)
            guard !Task.isCancelled, api.isCurrentSession else { return }
            accounts.append(CommunitySocialAccount(provider: "generic", url: next))
            if let previous {
                do {
                    try Task.checkCancellation()
                    guard api.isCurrentSession else { return }
                    try await api.deleteSocialAccount(previous)
                    guard !Task.isCancelled, api.isCurrentSession else { return }
                    accounts.removeAll { $0.url == previous }
                } catch {
                    guard !Task.isCancelled, api.isCurrentSession else { return }
                    self.error = "新链接已添加，但旧链接删除未获确认。请核对列表，仍在时可手动删除旧链接。\n" + error.localizedDescription
                }
            }
            editingURL = nil; draft = ""
            if error.isEmpty { message = previous == nil ? "已添加社交链接。" : "已更新社交链接。" }
        } catch {
            guard !Task.isCancelled, api.isCurrentSession else { return }
            self.error = error.localizedDescription
            if previous != nil { self.error += "\n原链接没有删除。" }
        }
        await refreshAfterWrite(api: api)
    }

    func delete(_ target: String, api: GitHub) async {
        guard !busy, !loading, loaded, !Task.isCancelled, api.isCurrentSession,
              accounts.contains(where: { $0.url == target }) else { return }
        busy = true; error = ""; message = ""; cancelReading()
        defer { busy = false }
        do {
            try Task.checkCancellation()
            guard api.isCurrentSession else { return }
            try await api.deleteSocialAccount(target)
            guard !Task.isCancelled, api.isCurrentSession else { return }
            accounts.removeAll { $0.url == target }
            if editingURL == target { editingURL = nil; draft = "" }
            message = "已删除社交链接。"
        } catch {
            guard !Task.isCancelled, api.isCurrentSession else { return }
            self.error = error.localizedDescription
        }
        await refreshAfterWrite(api: api)
    }

    private func refreshAfterWrite(api: GitHub) async {
        guard !Task.isCancelled, api.isCurrentSession else { return }
        do {
            let result = try await api.ownSocialAccounts()
            guard !Task.isCancelled, api.isCurrentSession else { return }
            accounts = result; loaded = true
        } catch {
            guard !Task.isCancelled, api.isCurrentSession else { return }
            self.error += (self.error.isEmpty ? "" : "\n") + "列表刷新失败，请刷新核对。"
        }
    }

    deinit { reading?.cancel() }
}

struct SocialAccountsView: View {
    @ObservedObject var api: GitHub
    @EnvironmentObject private var accountPresentation: AccountPresentation
    @StateObject private var state = SocialAccountsState()
    @State private var pendingDeletion: String?
    @FocusState private var editingLink: Bool

    var body: some View {
        Form {
            Section("社交账号") {
                SoftGroupRows {
                    SoftGroupRow("account") { Label(api.login, systemImage: "person.crop.circle") }
                    if state.loading { SoftGroupRow("loading") { ProgressView("正在加载…") } }
                    for account in state.accounts {
                        SoftGroupRow("social-" + account.id) {
                            Button { state.beginEditing(account) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "link")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(account.title).foregroundStyle(.primary)
                                        Text(account.url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    Image(systemName: "pencil").foregroundStyle(.secondary)
                                }.frame(minHeight: 44)
                            }
                            .accessibilityIdentifier("social-account-" + account.url)
                            .disabled(state.loading || !api.isCurrentSession)
                            .swipeActions {
                                Button("删除", role: .destructive) { pendingDeletion = account.url }
                                    .disabled(state.loading || !api.isCurrentSession)
                            }
                        }
                    }
                    if state.loaded && state.accounts.isEmpty {
                        SoftGroupRow("empty") { Text("尚未添加社交账号").foregroundStyle(.secondary) }
                    }
                }
            }
            Section(state.editingURL == nil ? "添加社交账号" : "编辑社交账号") {
                SoftGroupRows {
                    SoftGroupRow("url") {
                        TextField("https://t.me/用户名", text: $state.draft)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($editingLink).submitLabel(.done).onSubmit { editingLink = false }
                            .accessibilityIdentifier("social-account-url")
                    }
                    SoftGroupRow("save") {
                        Button("保存") { editingLink = false; Task { await state.save(api: api) } }
                            .accessibilityIdentifier("social-account-save")
                            .disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let current = state.editingURL {
                        SoftGroupRow("delete") { Button("删除这个社交账号", role: .destructive) { pendingDeletion = current } }
                        SoftGroupRow("cancel") { Button("取消编辑") { state.cancelEditing() } }
                    }
                    SoftGroupRow("help") {
                        Text("保存后同步到 GitHub 公开资料。修改时会先添加新链接；数量已满时，需先手动删除不再使用的链接。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.disabled(state.loading || !state.loaded || !api.isCurrentSession)
            if state.busy || !state.error.isEmpty || !state.message.isEmpty || !api.isCurrentSession {
                Section {
                    SoftGroupRows {
                        if state.busy { SoftGroupRow("saving") { ProgressView("正在保存…") } }
                        if !state.error.isEmpty { SoftGroupRow("error") { Text(state.error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("social-account-error") } }
                        if !state.message.isEmpty { SoftGroupRow("message") { Text(state.message).font(.callout).foregroundStyle(.secondary) } }
                        if !api.isCurrentSession { SoftGroupRow("session") { Text("账号已切换，请返回后重新打开。").font(.callout) } }
                    }
                }
            }
            Section("授权与账号") {
                SoftGroupRows {
                    SoftGroupRow("authorize") {
                        NavigationLink("授权社交账号管理") { DeviceOAuthView(api: api, writeProfile: true) }
                            .disabled(!api.isCurrentSession)
                    }
                    SoftGroupRow("accounts") { Button("账号管理") { accountPresentation.showing = true } }
                }
            }
        }
        .disabled(state.busy)
        .navigationTitle("社交账号").adaptiveWorkspaceLayout()
        .navigationBarBackButtonHidden(state.busy).interactiveDismissDisabled(state.busy)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { state.load(api: api) } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("刷新社交账号").disabled(state.busy || state.loading || !api.isCurrentSession)
            }
        }
        .confirmationDialog("删除社交账号？", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible, presenting: pendingDeletion) { target in
                Button("删除", role: .destructive) {
                    pendingDeletion = nil
                    Task { await state.delete(target, api: api) }
                }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: { target in Text("将从当前 GitHub 账号删除：\n" + target) }
        .onAppear { state.load(api: api) }
        // Writes finish their add-then-delete sequence even if this view leaves the screen.
        .onDisappear { state.cancelReading(); pendingDeletion = nil }
        .onReceive(NotificationCenter.default.publisher(for: .githubAccountChanged)) { _ in
            pendingDeletion = nil; state.accountChanged()
        }
    }
}
