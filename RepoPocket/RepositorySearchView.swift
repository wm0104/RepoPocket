import SwiftUI

struct RepositorySearchView: View {
    @ObservedObject var api: GitHub
    var selectRepository: ((Repository) throws -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var submitted = ""
    @State private var kind = RepositorySearchKind.repositories
    @State private var repositories: [Repository] = []
    @State private var users: [User] = []
    @State private var codeResults: [CodeSearchResult] = []
    @State private var incomplete = false
    @State private var readingLink: ReadingLink?
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
    private var invalidLink: Bool { kind != .code && RepositorySearchRouting.isLink(submitted) && RepositorySearchRouting.repository(submitted) == nil }
    var body: some View {
        AppNavigationStack {
            List {
                Section {
                    SoftGroupRows {
                    if selectRepository == nil { SoftGroupRow("kind") {
                    Picker("搜索类型", selection: $kind) {
                        Text("仓库").tag(RepositorySearchKind.repositories)
                        Text("用户").tag(RepositorySearchKind.users)
                        Text("代码").tag(RepositorySearchKind.code)
                    }.pickerStyle(.segmented)
                    } }
                if kind == .repositories {
                    SoftGroupRow("filter-heading") { Text("仓库筛选").font(.caption).foregroundStyle(.secondary) }
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
                if submitted.isEmpty {
                    if clean.isEmpty {
                            SoftGroupRow("history-heading") {
                                HStack { Text("近期搜索"); Spacer(); Button("清除") { store.clear(); history = [] }.disabled(history.isEmpty) }
                            }
                            for item in history.filter({ selectRepository == nil || $0.kind == .repositories }) {
                                SoftGroupRow("history-\(item.id)") {
                                Button { query = item.query; begin(item.kind) } label: {
                                    Label(item.query, systemImage: item.kind == .repositories ? "shippingbox" : item.kind == .code ? "doc.text.magnifyingglass" : "person")
                                }
                                .swipeActions { Button("删除", role: .destructive) { store.remove(item); history = store.read() } }
                                }
                            }
                    } else {
                            SoftGroupRow("suggestion-heading") { Text("搜索建议").font(.caption).foregroundStyle(.secondary) }
                            SoftGroupRow("suggest-repository") { Button { begin(.repositories) } label: { Label("搜索仓库：" + clean, systemImage: "shippingbox") } }
                            if selectRepository == nil { SoftGroupRow("suggest-user") { Button { begin(.users) } label: { Label("搜索用户：" + clean, systemImage: "person") } } }
                             if selectRepository == nil { SoftGroupRow("suggest-code") { Button { begin(.code) } label: { Label("搜索代码内容：" + clean, systemImage: "doc.text.magnifyingglass") } } }
                            if let repo = try? RepositoryInput.parse(clean) {
                                SoftGroupRow("direct-repository") {
                                if selectRepository != nil {
                                    Button("收藏仓库：" + repo) { chooseDirect(repo) }.disabled(busy)
                                } else {
                                NavigationLink { BrowserView(api: api, repo: repo, path: "", branch: "") }
                                label: { Label("打开仓库：" + repo, systemImage: "arrow.up.forward.square") }
                                }
                                }
                            }
                    }
                } else {
                        SoftGroupRow("results-heading") { Text(kind == .repositories ? "仓库结果" : kind == .code ? "代码结果" : "用户结果").font(.caption).foregroundStyle(.secondary) }
                        if kind == .code {
                            SoftGroupRow("code-scope") {
                                Text("仅搜索 GitHub 已索引的默认分支内容，可用 repo:用户名/仓库名 缩小范围。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        for repository in repositories {
                            SoftGroupRow("repository-\(repository.id)") {
                            if selectRepository != nil {
                                Button { choose(repository) } label: {
                                    CompactRepositorySummary(fullName: repository.full_name, name: repository.name,
                                        owner: repository.owner?.login, avatarURL: repository.owner?.avatar_url, description: repository.description)
                                }.buttonStyle(.plain)
                                    .accessibilityIdentifier("favorite-add-\(repository.id)")
                            } else {
                            NavigationLink { BrowserView(api: api, repo: repository.full_name, path: "", branch: repository.default_branch ?? "") }
                            label: { RepositoryCard(repository: repository, account: api.login, api: api) }
                            }
                            }
                        }
                        for user in users {
                            SoftGroupRow("user-" + user.login) {
                            NavigationLink { UserRepositoriesView(api: api, user: user) } label: {
                                HStack { GitHubAvatar(url: user.avatar_url); Text(user.login) }
                            }.accessibilityIdentifier("search-user-" + user.login)
                            }
                        }
                        for item in codeResults {
                            SoftGroupRow("code-" + item.id) {
                                Button {
                                    if let url = item.fileURL { readingLink = ReadingLink(url: url) }
                                } label: { CodeSearchResultRow(item: item) }
                                .buttonStyle(.plain).disabled(item.fileURL == nil)
                                .accessibilityIdentifier("search-code-" + item.id)
                            }
                        }
                        if incomplete { SoftGroupRow("incomplete") { Text("本次仅返回部分搜索结果，请缩小范围后重新搜索。").font(.caption).foregroundStyle(.secondary) } }
                        if !busy && repositories.isEmpty && users.isEmpty && codeResults.isEmpty && !incomplete && error.isEmpty { SoftGroupRow("empty") { Text("没有搜索结果").foregroundStyle(.secondary) } }
                        if more { SoftGroupRow("next") { Button("加载更多") { startLoad() }.disabled(busy) } }
                }
                    if busy { SoftGroupRow("busy") { ProgressView("搜索中…") } }
                    if !error.isEmpty {
                        SoftGroupRow("error") { Text(error).foregroundStyle(.secondary) }
                        if !invalidLink { SoftGroupRow("retry") { Button("重试") { startLoad() }.disabled(busy) } }
                    }
                    }
                }
            }
            // Do not animate structural List mutations during keyboard/sheet transitions.
            // Native sheet and navigation animations remain enabled.
            .navigationTitle("搜索").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: selectRepository == nil ? "搜索仓库、用户或代码内容" : "搜索仓库")
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .onSubmit(of: .search) { begin(kind) }
            .onChange(of: kind) { selected in
                guard directRepository == nil, !submitted.isEmpty, submitted == clean, selected != lastSubmittedKind else { return }
                begin(selected)
            }
            .appNavigationDestination(isPresented: Binding(get: { directRepository != nil }, set: { if !$0 { directRepository = nil } })) {
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
            .sheet(item: $readingLink) { ReadingLinkDestination(url: $0.url, api: api) { readingLink = nil } }
        }
    }
    private func begin(_ selected: RepositorySearchKind) {
        guard !clean.isEmpty else { return }
        if selected != .code, let target = RepositorySearchRouting.repository(clean) {
            if selectRepository != nil { chooseDirect(target); return }
            invalidate(); submitted = clean; repositories = []; users = []; codeResults = []; incomplete = false; more = false; error = ""
            store.record(clean, kind: .repositories); history = store.read()
            directRepository = target
            return
        }
        if selectRepository != nil && RepositorySearchRouting.isLink(clean) {
            invalidate(); submitted = clean; repositories = []; users = []; codeResults = []; incomplete = false; more = false
            error = RepositoryInput.Invalid().localizedDescription
            return
        }
        let selected = selectRepository == nil && RepositorySearchRouting.isLink(clean) ? .code : selected
        invalidate(); lastSubmittedKind = selected; kind = selected; submitted = clean
        requestedOptions = options
        repositories = []; users = []; codeResults = []; incomplete = false; page = 1; more = false; busy = false; error = ""
        store.record(submitted, kind: selected); history = store.read()
        startLoad()
    }
    private func choose(_ repository: Repository) {
        guard api.isCurrentSession, let selectRepository else { return }
        do { try selectRepository(repository); dismiss() }
        catch { self.error = (error as? AppError)?.text ?? "收藏未保存，请检查本机存储后重试。" }
    }
    private func chooseDirect(_ name: String) {
        invalidate(); let token = generation
        busy = true; error = ""
        requestTask = Task {
            defer { if token == generation { busy = false } }
            do {
                let repository = try await api.repository(name)
                try Task.checkCancellation(); guard token == generation, api.isCurrentSession else { return }
                choose(repository)
            } catch { if token == generation, api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = "仓库读取失败，请检查网络与账号权限后重试。" } }
        }
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
            } else if requestedKind == .code {
                let value = try await api.searchCode(requested, page: requestedPage)
                guard RepositorySearchRules.accepts(token, current: generation, account: account, currentAccount: AccountStore.generation) else { return }
                var ids = Set(codeResults.map { $0.id })
                codeResults += value.items.filter { ids.insert($0.id).inserted }
                incomplete = incomplete || value.incomplete_results
                more = value.items.count == 30 && requestedPage * 30 < min(value.total_count, 1000)
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
            Section {
                CommunityProfileSection(api: api, login: user.login, avatar: user.avatar_url, connected: true) { readingLink = ReadingLink(url: $0) }
                SoftGroupRows(top: false) {
                    for repository in repositories {
                        SoftGroupRow("repository:" + String(repository.id)) {
                            NavigationLink { BrowserView(api: api, repo: repository.full_name, path: "", branch: repository.default_branch ?? "") }
                            label: { RepositoryCard(repository: repository, account: api.login, api: api) }
                        }
                    }
                    if more { SoftGroupRow("more") { Button("加载更多仓库") { Task { await load() } }.disabled(busy) } }
                    if busy { SoftGroupRow("loading") { ProgressView() } }
                    if !error.isEmpty { SoftGroupRow("error") { Text(error) } }
                    if !busy && error.isEmpty && repositories.isEmpty && !more { SoftGroupRow("empty") { Text("暂无仓库") } }
                }
            }
        }.navigationTitle(user.login).adaptiveWorkspaceLayout().task { guard !attempted else { return }; attempted = true; await load() }
        .sheet(item: $readingLink) { ReadingLinkDestination(url: $0.url, api: api) { readingLink = nil } }
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

private struct CodeSearchResultRow: View {
    let item: CodeSearchResult
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.repository.full_name).font(.caption).foregroundStyle(.secondary)
            Label(item.path, systemImage: "doc.text").font(.callout)
                .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array((item.text_matches ?? []).prefix(3).enumerated()), id: \.offset) { _, match in
                Text(highlighted(match)).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(6)
            }
        }.padding(.vertical, 4)
    }
    private func highlighted(_ match: CodeSearchMatch) -> AttributedString {
        var text = AttributedString(match.fragment)
        for item in match.matches ?? [] where !item.text.isEmpty {
            if let range = text.range(of: item.text) { text[range].backgroundColor = .yellow.opacity(0.25) }
        }
        return text
    }
}
