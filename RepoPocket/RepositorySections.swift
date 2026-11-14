import SwiftUI

enum RepositoryHomeSection: String, CaseIterable, Identifiable {
    case owned, starred
    var id: String { rawValue }
    var title: String { self == .owned ? "我的仓库" : "已加星标" }
    var systemImage: String { self == .owned ? "folder" : "star" }
}

struct RepositoryHomeLinksSection: View {
    @ObservedObject var api: GitHub
    let owned: [Repository]
    let starred: [Repository]
    let loaded: Bool
    var connected = false
    var body: some View {
        Group {
            if connected { content }
            else { Section("我的仓库") { content } }
        }
    }
    private var content: some View {
            SoftGroupRows {
                if connected { SoftGroupRow("heading") { Text("我的仓库").font(.subheadline).foregroundStyle(.secondary) } }
                for section in RepositoryHomeSection.allCases {
                    SoftGroupRow(section.id) {
                        NavigationLink {
                            if section == .starred {
                                StarListsView(api: api, initialRepositories: loaded ? starred : nil)
                            } else {
                                RepositoryCollectionView(api: api, section: section,
                                    initialRepositories: loaded ? (section == .owned ? owned : starred) : nil)
                            }
                        } label: {
                            HStack {
                                Label(section.title, systemImage: section.systemImage)
                                Spacer()
                                Text(loaded ? (section == .owned ? owned.count : starred.count).formatted() : "—")
                                    .foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("home-collection-" + section.id)
                    }
                }
                SoftGroupRow("favorites") { RepositoryFavoritesHomeLink(api: api, favorites: api.favorites) }
            }
    }
}

struct RepositoryCollectionView: View {
    @ObservedObject var api: GitHub
    let section: RepositoryHomeSection
    @State private var repositories: [Repository] = []
    @State private var busy = false
    @State private var loaded = false
    @State private var refreshing = false
    @State private var pendingFork: Repository?
    var initialRepositories: [Repository]? = nil
    @State private var query = ""
    @State private var searchVisible = false
    @State private var updatedAt: Date?
    @State private var loadError = ""
    private var filteredRepositories: [Repository] {
        repositories.filter { HomeListSearch.matches(query, fields: [$0.name, $0.full_name, $0.description ?? ""]) }
    }
    var body: some View {
        List {
            Section {
                SoftGroupRows {
            if searchVisible { SoftGroupRow("search") { ListSearchField(query: $query, title: section.title) } }
            if busy && repositories.isEmpty && !refreshing { SoftGroupRow("loading") { ProgressView().frame(maxWidth: .infinity) } }
            else if loaded && repositories.isEmpty { SoftGroupRow("empty") { Text("暂无仓库").foregroundStyle(.secondary) } }
            else if !loaded && !busy { SoftGroupRow("login") { Text("请登录后刷新").foregroundStyle(.secondary) } }
            else if loaded && filteredRepositories.isEmpty { SoftGroupRow("no-match") { Text("没有匹配仓库").foregroundStyle(.secondary) } }
            for repository in filteredRepositories {
                SoftGroupRow("repository-\(repository.id)") {
                NavigationLink { BrowserView(api: api, repo: repository.full_name, path: "", branch: repository.default_branch ?? "") }
                label: {
                    VStack(alignment: .leading, spacing: 4) {
                        RepositoryCard(repository: repository, account: api.login, api: api)
                        if section == .starred, let date = ChinaDate.parse(repository.updated_at) {
                            RepositoryUpdatedText(date: date)
                        }
                    }
                }
                .accessibilityIdentifier("collection-repository-\(repository.id)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !RepositoryGroupRules.isOwned(repository.full_name, login: api.login) {
                        Button("复刻") { pendingFork = repository }.tint(.accentColor).disabled(busy)
                    }
                }
                }
            }
            if updatedAt != nil {
                SoftGroupRow("freshness") { ContentFreshnessText(updatedAt: updatedAt, updating: busy, error: loadError) }
            }
                }
            }
        }
        .listStyle(.insetGrouped).navigationTitle(section.title).adaptiveWorkspaceLayout()
        .toolbar {
            ListSearchButton(visible: $searchVisible, query: $query, title: section.title)
            Button("刷新") { Task { await load() } }.disabled(busy)
        }
        .refreshable { refreshing = true; defer { refreshing = false }; await load() }
        .task {
            if !loaded, let cached = initialRepositories ?? api.cachedCollection(section) {
                repositories = cached; loaded = true
                updatedAt = api.cachedContent([Repository].self, key: "collection:" + section.rawValue)?.savedAt
            }
            if !CredentialStore.read().isEmpty { await load() }
        }
        .onChange(of: api.starRevision) { _ in
            guard api.isCurrentSession else { return }
            if let cached = api.cachedCollection(section) { repositories = cached }
            else if loaded && !busy { Task { await load() } }
        }
        .confirmationDialog("复刻到我的仓库？", isPresented: Binding(get: { pendingFork != nil }, set: { if !$0 { pendingFork = nil } }), titleVisibility: .visible) {
            if let repository = pendingFork { Button("复刻") { pendingFork = nil; Task { await fork(repository) } } }
            Button("取消", role: .cancel) { pendingFork = nil }
        } message: { Text(pendingFork?.full_name ?? "") }
    }
    private func load() async {
        guard !busy else { return }
        let generation = AccountStore.generation
        busy = true; defer { busy = false }
        loadError = ""
        do {
            try await api.identify()
            let result: [Repository]
            if section == .owned {
                result = try await api.repositories().filter { RepositoryGroupRules.isOwned($0.full_name, login: api.login) }
            } else { result = try await api.starredRepositories() }
            try Task.checkCancellation()
            guard generation == AccountStore.generation else { return }
            repositories = result; api.cacheCollection(result, section: section); loaded = true; updatedAt = Date()
        } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { loadError = error.localizedDescription; api.message = loadError } }
    }
    private func fork(_ repository: Repository) async {
        guard !busy else { return }
        let generation = AccountStore.generation
        busy = true; defer { busy = false }
        do {
            let result = try await api.fork(repository.full_name)
            try Task.checkCancellation()
            guard generation == AccountStore.generation else { return }
            api.message = "已复刻：\(result.full_name)。GitHub 可能需要片刻准备内容。"
        } catch { if !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
}
