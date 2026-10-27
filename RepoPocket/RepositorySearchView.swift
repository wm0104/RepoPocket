import SwiftUI

struct RepositorySearchView: View {
    @ObservedObject var api: GitHub
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var submitted = ""
    @State private var kind = RepositorySearchKind.repositories
    @State private var repositories: [Repository] = []
    @State private var users: [User] = []
    @State private var history: [RepositoryRecentSearch] = []
    @State private var generation = UUID()
    @State private var requestTask: Task<Void, Never>?
    @State private var page = 1
    @State private var more = false
    @State private var busy = false
    @State private var error = ""
    @State private var options = RepositorySearchOptions()
    @State private var requestedOptions = RepositorySearchOptions()
    @State private var directRepository: String?
    @State private var lastSubmittedKind = RepositorySearchKind.repositories
    private var store: RepositorySearchHistory { RepositorySearchHistory(accountID: api.accountID) }
    private var clean: String { RepositorySearchRules.normalized(query) }
    private var invalidLink: Bool { RepositorySearchRouting.isLink(submitted) && RepositorySearchRouting.repository(submitted) == nil }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("搜索类型", selection: $kind) {
                        Text("仓库").tag(RepositorySearchKind.repositories)
                        Text("用户").tag(RepositorySearchKind.users)
                    }.pickerStyle(.segmented).softGroupedRow(top: true, bottom: true)
                }
                if kind == .repositories {
                Section("仓库筛选") {
                    SoftGroupRows {
                    SoftGroupRow("language") {
                    Picker("语言", selection: $options.language) {
                        ForEach(RepositorySearchOptions.languages, id: \.self) { Text($0.isEmpty ? "所有语言" : $0).tag($0) }
                    }
                    }
                    SoftGroupRow("sort") {
                    Picker("排序", selection: $options.sort) {
                        ForEach(RepositorySearchSort.allCases) { Text($0.title).tag($0) }
                    }
                    }
                    if options.sort != .best { SoftGroupRow("direction") { Toggle("升序", isOn: $options.ascending) } }
                    if options != requestedOptions && !submitted.isEmpty && kind == .repositories {
                        SoftGroupRow("apply") { Button("应用筛选并重新搜索") { begin(.repositories) } }
                    }
                    }
                }
                }
                if submitted.isEmpty {
                    if clean.isEmpty {
                        Section {
                            ForEach(history) { item in
                                Button { query = item.query; begin(item.kind) } label: {
                                    Label(item.query, systemImage: item.kind == .repositories ? "shippingbox" : "person")
                                }
                                .swipeActions { Button("删除", role: .destructive) { store.remove(item); history = store.read() } }.softGroupedRow(top: item.id == history.first?.id, bottom: item.id == history.last?.id)
                            }
                        } header: {
                            HStack { Text("近期搜索"); Spacer(); Button("清除") { store.clear(); history = [] }.disabled(history.isEmpty) }
                        }
                    } else {
                        Section("搜索建议") {
                            Button { begin(.repositories) } label: { Label("搜索仓库：" + clean, systemImage: "shippingbox") }.softGroupedRow(top: true)
                            Button { begin(.users) } label: { Label("搜索用户：" + clean, systemImage: "person") }.softGroupedRow(bottom: (try? RepositoryInput.parse(clean)) == nil)
                            if let repo = try? RepositoryInput.parse(clean) {
                                NavigationLink { BrowserView(api: api, repo: repo, path: "", branch: "") }
                                label: { Label("打开仓库：" + repo, systemImage: "arrow.up.forward.square") }.softGroupedRow(bottom: true)
                            }
                        }
                    }
                } else {
                    Section(kind == .repositories ? "仓库结果" : "用户结果") {
                        ForEach(repositories) { repository in
                            NavigationLink { BrowserView(api: api, repo: repository.full_name, path: "", branch: repository.default_branch ?? "") }
                            label: { RepositoryCard(repository: repository, account: api.login, api: api) }.softGroupedRow(top: repository.id == repositories.first?.id, bottom: repository.id == repositories.last?.id && !more)
                        }
                        ForEach(users, id: \.login) { user in
                            NavigationLink { UserRepositoriesView(api: api, user: user) } label: {
                                HStack { GitHubAvatar(url: user.avatar_url); Text(user.login) }
                            }.accessibilityIdentifier("search-user-" + user.login)
                            .softGroupedRow(top: repositories.isEmpty && user.login == users.first?.login, bottom: user.login == users.last?.login && !more)
                        }
                        if !busy && repositories.isEmpty && users.isEmpty && error.isEmpty { Text("没有搜索结果").foregroundStyle(.secondary).softGroupedRow(top: true, bottom: !more) }
                        if more { Button("加载更多") { startLoad() }.disabled(busy).softGroupedRow(top: repositories.isEmpty && users.isEmpty && (busy || !error.isEmpty), bottom: true) }
                    }
                }
                Section {
                    if busy { ProgressView("搜索中…").softGroupedRow(top: true, bottom: error.isEmpty) }
                    if !error.isEmpty {
                        Text(error).foregroundStyle(.secondary).softGroupedRow(top: !busy, bottom: invalidLink)
                        if !invalidLink { Button("重试") { startLoad() }.disabled(busy).softGroupedRow(bottom: true) }
                    }
                }
            }
            // Do not animate structural List mutations during keyboard/sheet transitions.
            // Native sheet and navigation animations remain enabled.
            .navigationTitle("搜索").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索仓库或用户")
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .onSubmit(of: .search) { begin(kind) }
            .onChange(of: kind) { selected in
                guard directRepository == nil, !submitted.isEmpty, submitted == clean, selected != lastSubmittedKind else { return }
                begin(selected)
            }
            .navigationDestination(isPresented: Binding(get: { directRepository != nil }, set: { if !$0 { directRepository = nil } })) {
                if let directRepository { BrowserView(api: api, repo: directRepository, path: "", branch: "") }
            }
            .onChange(of: query) { _ in
                // A history tap sets query and submits in the same transaction;
                // do not invalidate that newly submitted request afterwards.
                guard clean != submitted else { return }
                invalidate(); submitted = ""; error = ""
            }
            .toolbar { SearchDismissButton { invalidate(); dismiss() } }
            .task {
                // Present the native sheet before decoding bounded local history off-main.
                await Task.yield()
                let accountID = api.accountID
                let records = await Task.detached(priority: .utility) {
                    RepositorySearchHistory(accountID: accountID).read()
                }.value
                guard !Task.isCancelled, accountID == api.accountID else { return }
                history = records
            }
            .onDisappear { invalidate() }
        }
    }
    private func begin(_ selected: RepositorySearchKind) {
        guard !clean.isEmpty else { return }
        if let target = RepositorySearchRouting.repository(clean) {
            invalidate(); submitted = clean; repositories = []; users = []; more = false; error = ""
            store.record(clean, kind: .repositories); history = store.read()
            directRepository = target
            return
        }
        if RepositorySearchRouting.isLink(clean) {
            invalidate(); submitted = clean; repositories = []; users = []; more = false
            error = RepositoryInput.Invalid().localizedDescription
            return
        }
        invalidate(); lastSubmittedKind = selected; kind = selected; submitted = clean
        requestedOptions = options
        repositories = []; users = []; page = 1; more = false; busy = false; error = ""
        store.record(submitted, kind: selected); history = store.read()
        startLoad()
    }
    private func invalidate() {
        requestTask?.cancel(); requestTask = nil
        generation = UUID(); busy = false
    }
    private func startLoad() {
        guard !busy else { return }
        requestTask = Task { await load() }
    }
    private func load() async {
        guard !Task.isCancelled, !busy, !submitted.isEmpty else { return }
        let token = generation, account = AccountStore.generation
        let requested = submitted, requestedKind = kind, requestedPage = page
        busy = true; error = ""
        defer { if generation == token { busy = false } }
        do {
            if requestedKind == .repositories {
                let value = try await api.searchRepositories(requested, page: requestedPage, options: requestedOptions)
                guard RepositorySearchRules.accepts(token, current: generation, account: account, currentAccount: AccountStore.generation) else { return }
                let ids = Set(repositories.map { $0.id }); repositories += value.items.filter { !ids.contains($0.id) }
                more = value.items.count == 30 && repositories.count < min(value.total_count, 1000)
            } else {
                let value = try await api.searchUsers(requested, page: requestedPage)
                guard RepositorySearchRules.accepts(token, current: generation, account: account, currentAccount: AccountStore.generation) else { return }
                let ids = Set(users.map { $0.login }); users += value.items.filter { !ids.contains($0.login) }
                more = value.items.count == 30 && users.count < min(value.total_count, 1000)
            }
            page += 1
        } catch {
            guard generation == token, account == AccountStore.generation, !RefreshFailure.isCancellation(error) else { return }
            // Never display raw API error bodies in search results.
            self.error = "搜索失败，请检查网络、账号权限或 GitHub 搜索限流后重试。"
        }
    }
}

struct UserRepositoriesView: View {
    @State private var attempted = false
    @State private var readingLink: ReadingLink?
    @ObservedObject var api: GitHub
    let user: User
    @State private var repositories: [Repository] = []
    @State private var page = 1
    @State private var more = true
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        List {
            CommunityProfileSection(api: api, login: user.login, avatar: user.avatar_url) { readingLink = ReadingLink(url: $0) }
            ForEach(repositories) { repository in
                NavigationLink { BrowserView(api: api, repo: repository.full_name, path: "", branch: repository.default_branch ?? "") }
                label: { RepositoryCard(repository: repository, account: api.login, api: api) }.softGroupedRow(top: repository.id == repositories.first?.id, bottom: repository.id == repositories.last?.id && !more)
            }
            if more { Button("加载更多仓库") { Task { await load() } }.disabled(busy).softGroupedRow(top: repositories.isEmpty, bottom: true) }
            Section {
                if busy { ProgressView().softGroupedRow(top: true, bottom: error.isEmpty) }
                if !error.isEmpty { Text(error).softGroupedRow(top: !busy, bottom: true) }
                if !busy && error.isEmpty && repositories.isEmpty && !more { Text("暂无仓库").softGroupedRow(top: true, bottom: true) }
            }
        }.navigationTitle(user.login).adaptiveWorkspaceLayout().task { guard !attempted else { return }; attempted = true; await load() }
        .sheet(item: $readingLink) { ReadingLinkDestination(url: $0.url, api: api) }
    }
    private func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let account = AccountStore.generation
        do {
            let batch = try await api.userRepositories(user.login, page: page)
            try Task.checkCancellation(); guard account == AccountStore.generation else { return }
            let ids = Set(repositories.map { $0.id }); repositories += batch.filter { !ids.contains($0.id) }
            more = batch.count == 100; page += 1; error = ""
        } catch { if !RefreshFailure.isCancellation(error) { self.error = "仓库加载失败，请稍后重试。" } }
    }
}

/// Resolves dismissSearch below the searchable modifier, not on the parent sheet.
private struct SearchDismissButton: View {
    @Environment(\.dismissSearch) private var dismissSearch
    let action: () -> Void
    var body: some View {
        Button("关闭") {
            dismissSearch()
            action()
        }
    }
}
