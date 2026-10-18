import SwiftUI

enum RepositoryHomeSection: String, CaseIterable, Identifiable {
    case owned, starred
    var id: String { rawValue }
    var title: String { self == .owned ? "我的仓库" : "已加星标" }
    var systemImage: String { self == .owned ? "folder" : "star" }
}

/// Native sibling rows keep swipe actions; no synthetic footer or height animation.
struct RepositoryInlineSection: View {
    @ObservedObject var api: GitHub
    let section: RepositoryHomeSection
    @Binding var expanded: Bool
    let repositories: [Repository]
    let loaded: Bool
    let busy: Bool
    let fork: (Repository) -> Void
    let search: () -> Void
    var body: some View {
        Section {
            HStack(spacing: 0) {
            Button {
                UIRules.withoutAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: section.systemImage).frame(width: 24).foregroundStyle(Color.accentColor)
                    Text(section.title).font(.headline)
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }.frame(minHeight: 52).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(section.title)
            .accessibilityValue(expanded ? "已展开" : "已收起")
            Button(action: search) { Image(systemName: "magnifyingglass").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.borderless).accessibilityLabel("搜索" + section.title)
            }
            .softGroupedRow(top: true, bottom: !expanded, animateBackground: false)
            if expanded {
                if repositories.isEmpty {
                    if busy { ProgressView().frame(maxWidth: .infinity).softGroupedRow(bottom: true, animateBackground: false) }
                    else { Text(loaded ? "暂无仓库" : "请登录后刷新").foregroundStyle(.secondary).softGroupedRow(bottom: true, animateBackground: false) }
                }
                ForEach(repositories) { repository in
                    NavigationLink {
                        BrowserView(api: api, repo: repository.full_name, path: "", branch: repository.default_branch ?? "")
                    } label: { RepositoryCard(repository: repository, account: api.login, api: api) }
                    .softGroupedRow(bottom: repository.id == repositories.last?.id, animateBackground: false)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !RepositoryGroupRules.isOwned(repository.full_name, login: api.login) {
                            Button("复刻") { fork(repository) }.tint(.accentColor).disabled(busy)
                        }
                    }
                }
            }

        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
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
    private var filteredRepositories: [Repository] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return repositories.filter { term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) || $0.full_name.localizedCaseInsensitiveContains(term) || ($0.description?.localizedCaseInsensitiveContains(term) ?? false) }
    }
    var body: some View {
        List {
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
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !RepositoryGroupRules.isOwned(repository.full_name, login: api.login) {
                        Button("复刻") { pendingFork = repository }.tint(.accentColor).disabled(busy)
                    }
                }
            }
        }
        .listStyle(.insetGrouped).navigationTitle(section.title).adaptiveWorkspaceLayout()
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索" + section.title)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .toolbar { Button("刷新") { Task { await load() } }.disabled(busy) }
        .refreshable { refreshing = true; defer { refreshing = false }; await load() }
        .task {
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
