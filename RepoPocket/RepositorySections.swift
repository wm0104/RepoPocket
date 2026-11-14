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
    var body: some View {
        Section("我的仓库") {
            SoftGroupRows {
                for section in RepositoryHomeSection.allCases {
                    SoftGroupRow(section.id) {
                        NavigationLink {
                            RepositoryCollectionView(api: api, section: section,
                                initialRepositories: loaded ? (section == .owned ? owned : starred) : nil)
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
            }
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
    @State private var attempted = false
    private var filteredRepositories: [Repository] {
        repositories.filter { HomeListSearch.matches(query, fields: [$0.name, $0.full_name, $0.description ?? ""]) }
    }
    var body: some View {
        List {
            if searchVisible {
                Section { ListSearchField(query: $query, title: section.title).softGroupedRow(top: true, bottom: true) }
            }
            if busy && repositories.isEmpty && !refreshing { ProgressView().frame(maxWidth: .infinity).softGroupedRow(top: true, bottom: true) }
            else if loaded && repositories.isEmpty { Text("暂无仓库").foregroundStyle(.secondary).softGroupedRow(top: true, bottom: true) }
            else if !loaded && !busy { Text("请登录后刷新").foregroundStyle(.secondary).softGroupedRow(top: true, bottom: true) }
            else if loaded && filteredRepositories.isEmpty { Text("没有匹配仓库").foregroundStyle(.secondary).softGroupedRow(top: true, bottom: true) }
            ForEach(filteredRepositories) { repository in
                NavigationLink { BrowserView(api: api, repo: repository.full_name, path: "", branch: repository.default_branch ?? "") }
                label: { RepositoryCard(repository: repository, account: api.login, api: api) }
                // Same full-width separators and card spacing as the home list;
                // boundaries follow the filtered result, not the unfiltered cache.
                .softGroupedRow(top: repository.id == filteredRepositories.first?.id,
                                bottom: repository.id == filteredRepositories.last?.id)
                .accessibilityIdentifier("collection-repository-\(repository.id)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !RepositoryGroupRules.isOwned(repository.full_name, login: api.login) {
                        Button("复刻") { pendingFork = repository }.tint(.accentColor).disabled(busy)
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
            guard !attempted else { return }; attempted = true
            if !loaded, let cached = initialRepositories ?? api.cachedCollection(section) {
                repositories = cached; loaded = true
            }
            if !loaded && !CredentialStore.read().isEmpty { await load() }
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
        do {
            try await api.identify()
            let result: [Repository]
            if section == .owned {
                result = try await api.repositories().filter { RepositoryGroupRules.isOwned($0.full_name, login: api.login) }
            } else { result = try await api.starredRepositories() }
            try Task.checkCancellation()
            guard generation == AccountStore.generation else { return }
            repositories = result; api.cacheCollection(result, section: section); loaded = true
        } catch { if !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
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
