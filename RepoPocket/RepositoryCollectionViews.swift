import SwiftUI

struct RepositoryFavoritesHomeLink: View {
    @ObservedObject var api: GitHub
    @ObservedObject var favorites: RepositoryFavoritesState
    var body: some View {
        NavigationLink { RepositoryFavoritesView(api: api, favorites: favorites) } label: {
            HStack { Label("收藏夹", systemImage: "bookmark"); Spacer(); Text(favorites.repositories.count.formatted()).foregroundStyle(.secondary) }
        }.accessibilityIdentifier("home-collection-favorites")
    }
}

struct RepositoryFavoriteActionHost<Content: View>: View {
    @ObservedObject var api: GitHub
    let repository: Repository?
    @ObservedObject var favorites: RepositoryFavoritesState
    let content: (NativeMenuItem) -> Content
    var body: some View {
        let saved = repository.map(favorites.contains) ?? false
        content(NativeMenuItem(id: "repository-favorite", title: saved ? "移出收藏夹" : "收藏到收藏夹",
            symbol: saved ? "bookmark.fill" : "bookmark", enabled: repository != nil && api.isCurrentSession,
            selected: saved, perform: {
                guard api.isCurrentSession, let repository else { return }
                do {
                    if favorites.contains(repository) { try favorites.remove([repository.id]) }
                    else { try favorites.add(repository) }
                } catch { api.message = error.localizedDescription }
            }))
    }
}

struct RepositoryFavoritesView: View {
    @ObservedObject var api: GitHub
    @ObservedObject var favorites: RepositoryFavoritesState
    @State private var searchVisible = false
    @State private var query = ""
    @State private var adding = false
    @State private var editMode = EditMode.inactive
    private var values: [Repository] {
        favorites.repositories.filter { HomeListSearch.matches(query, fields: [$0.full_name, $0.description ?? ""]) }
    }
    var body: some View {
        List {
            Section {
                if searchVisible { ListSearchField(query: $query, title: "收藏夹").softGroupedRow(top: true, bottom: true) }
                if values.isEmpty {
                    Text(query.isEmpty ? "暂无收藏。点右上角…搜索并添加仓库。" : "没有匹配仓库")
                        .foregroundStyle(.secondary).softGroupedRow(top: true, bottom: true)
                }
                ForEach(Array(values.enumerated()), id: \.element.id) { offset, repository in
                    NavigationLink { BrowserView(api: api, repo: repository.full_name, path: "", branch: repository.default_branch ?? "") }
                        label: { RepositoryCard(repository: repository, account: api.login, api: api) }
                        .accessibilityIdentifier("favorite-repository-\(repository.id)")
                        .softGroupedRow(top: offset == 0, bottom: offset == values.count - 1)
                }
                .onDelete { offsets in
                    do { try favorites.remove(Set(offsets.map { values[$0].id })) } catch { api.message = error.localizedDescription }
                }
                .onMove { offsets, destination in
                    var order = favorites.repositories.map(\.id); order.move(fromOffsets: offsets, toOffset: destination)
                    do { try favorites.reorder(order) } catch { api.message = error.localizedDescription }
                }.moveDisabled(!query.isEmpty)
                if !favorites.error.isEmpty { Text(favorites.error).font(.caption).softGroupedRow(top: true, bottom: true, spacingBefore: 10) }
            }
        }.listStyle(.insetGrouped).navigationTitle("收藏夹").adaptiveWorkspaceLayout().environment(\.editMode, $editMode)
        .disabled(!api.isCurrentSession)
        .toolbar {
            ListSearchButton(visible: $searchVisible, query: $query, title: "收藏夹")
            NativeActionMenu(title: "收藏夹操作", items: [
                NativeMenuItem(id: "favorite-add", title: "添加收藏", symbol: "plus", perform: { editMode = .inactive; adding = true }),
                NativeMenuItem(id: "favorite-manage", title: editMode.isEditing ? "完成管理" : "管理收藏", symbol: "arrow.up.arrow.down",
                    enabled: editMode.isEditing || (query.isEmpty && !favorites.repositories.isEmpty), perform: { editMode = editMode.isEditing ? .inactive : .active })
            ])
        }
        .sheet(isPresented: $adding) {
            RepositorySearchView(api: api, selectRepository: { try favorites.add($0) }).appSheetCornerRadius()
        }
    }
}

struct StarListsView: View {
    @ObservedObject var api: GitHub
    var initialRepositories: [Repository]? = nil
    @State private var index: StarListIndex?
    @State private var busy = false
    @State private var error = ""
    @State private var updatedAt: Date?
    @State private var editor: StarListEditorTarget?
    @State private var deleting: StarRepositoryList?
    @State private var operation: Task<Void, Never>?
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    SoftGroupRow("all") {
                        NavigationLink { RepositoryCollectionView(api: api, section: .starred, initialRepositories: initialRepositories) }
                            label: { Label("全部星标", systemImage: "star") }.accessibilityIdentifier("star-list-all")
                    }
                }
                SoftGroupRows(spacingBefore: 10) {
                    SoftGroupRow("heading") { Text("分类列表").font(.subheadline).foregroundStyle(.secondary) }
                    for list in index?.lists ?? [] {
                        SoftGroupRow(list.id) {
                            HStack {
                                NavigationLink { StarListDetailView(api: api, list: list) } label: {
                                    HStack { Label(list.name, systemImage: list.isPrivate ? "lock.rectangle" : "list.bullet"); Spacer(); Text(list.items.totalCount.formatted()).foregroundStyle(.secondary) }
                                }.accessibilityIdentifier("star-list-" + list.id)
                                NativeActionMenu(title: "分类操作：" + list.name, items: [
                                    NativeMenuItem(id: "rename", title: "重命名", symbol: "pencil", perform: { editor = .init(list: list) }),
                                    NativeMenuItem(id: "delete", title: "删除分类", symbol: "trash", destructive: true, perform: { deleting = list })
                                ]).frame(width: 44)
                            }
                        }
                    }
                    if busy && index == nil { SoftGroupRow("loading") { ProgressView("读取GitHub分类…") } }
                    if let index, index.lists.isEmpty { SoftGroupRow("empty") { Text("暂无分类，可从…新建。").foregroundStyle(.secondary) } }
                    if !error.isEmpty { SoftGroupRow("error") { Text(error).font(.caption).accessibilityIdentifier("star-list-error") } }
                    if updatedAt != nil { SoftGroupRow("freshness") { ContentFreshnessText(updatedAt: updatedAt, updating: busy, error: error) } }
                }
            }
        }.listStyle(.insetGrouped).navigationTitle("已加星标").adaptiveWorkspaceLayout().disabled(!api.isCurrentSession)
        .navigationBarBackButtonHidden(busy && operation != nil)
        .toolbar {
            NativeActionMenu(title: "Star分类操作", enabled: !busy, items: [
                NativeMenuItem(id: "create", title: "新建分类", symbol: "plus", perform: { editor = .init(list: nil) }),
                NativeMenuItem(id: "refresh", title: "刷新分类", symbol: "arrow.clockwise", perform: { operation = Task { await load() } })
            ])
        }
        .task {
            if index == nil, let cached = api.cachedContent(StarListIndex.self, key: "star-lists") { index = cached.value; updatedAt = cached.savedAt }
            await load()
        }
        .refreshable { await load() }
        .sheet(item: $editor, onDismiss: { operation = Task { await load() } }) { target in
            AppNavigationStack { StarListNameView(api: api, list: target.list) }.appSheetCornerRadius()
        }
        .confirmationDialog("删除这个分类？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { list in
            Button("确认删除分类", role: .destructive) {
                operation = Task {
                    guard !busy else { return }; busy = true; error = ""
                    do { try await api.starLists.delete(list) }
                    catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription + " 请刷新核对结果，不会自动重发。" } }
                    busy = false
                    if error.isEmpty { await load() }
                }
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { list in Text(list.name + "。只删除分类，不会取消仓库的Star。") }
        .onDisappear { operation?.cancel() }
    }
    private func load() async {
        guard !busy, api.isCurrentSession else { return }; busy = true; error = ""; defer { busy = false }
        do {
            let value = try await api.starLists.index()
            try Task.checkCancellation(); guard api.isCurrentSession else { return }
            index = value; updatedAt = Date()
            if let data = try? JSONEncoder().encode(value) { ContentSnapshotCache.shared.save(data, accountID: api.accountID, key: "star-lists") }
        } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription } }
    }
}

private struct StarListEditorTarget: Identifiable { let id = UUID(); let list: StarRepositoryList? }
private struct StarListNameView: View {
    @ObservedObject var api: GitHub
    let list: StarRepositoryList?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @State private var attempted = false
    @State private var error = ""
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    SoftGroupRow("name") { TextField("分类名称", text: $name).accessibilityIdentifier("star-list-name") }
                    SoftGroupRow("notice") { Text(list == nil ? "新建分类默认为私密，只对自己可见。" : "只修改名称，保持原有公开性和仓库归属。").font(.caption).foregroundStyle(.secondary) }
                    if busy { SoftGroupRow("busy") { ProgressView("保存中…") } }
                    if !error.isEmpty { SoftGroupRow("error") { Text(error).font(.caption) } }
                }
            }
        }.listStyle(.insetGrouped).navigationTitle(list == nil ? "新建分类" : "重命名分类").navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(busy)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    busy = true; attempted = true
                    Task {
                        defer { busy = false }
                        do {
                            if let list { _ = try await api.starLists.rename(list, name: name) }
                            else { _ = try await api.starLists.create(name: name) }
                            guard api.isCurrentSession else { return }; dismiss()
                        } catch { if api.isCurrentSession { self.error = error.localizedDescription + " 请关闭后刷新核对，再决定是否重试。" } }
                    }
                }.disabled(busy || attempted || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !api.isCurrentSession)
            }
        }.onAppear { name = list?.name ?? "" }
    }
}

struct StarListDetailView: View {
    @ObservedObject var api: GitHub
    let list: StarRepositoryList
    @State private var repositories: [StarListRepository] = []
    @State private var busy = false
    @State private var error = ""
    @State private var adding = false
    @State private var removing: StarListRepository?
    @State private var query = ""
    @State private var searchVisible = false
    @State private var operation: Task<Void, Never>?
    @State private var updatedAt: Date?
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    if searchVisible { SoftGroupRow("search") { ListSearchField(query: $query, title: list.name) } }
                    for item in repositories.filter({ HomeListSearch.matches(query, fields: [$0.nameWithOwner, $0.description ?? ""]) }) {
                        SoftGroupRow(item.id) {
                            NavigationLink { BrowserView(api: api, repo: item.nameWithOwner, path: "", branch: "") }
                                label: { RepositoryCard(repository: item.repository, account: api.login, api: api) }
                                .accessibilityIdentifier("star-list-repository-" + item.id)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) { Button("移出分类", role: .destructive) { removing = item }.disabled(busy) }
                        }
                    }
                    if busy && repositories.isEmpty { SoftGroupRow("busy") { ProgressView("核对分类…") } }
                    if !busy && repositories.isEmpty && error.isEmpty { SoftGroupRow("empty") { Text("此分类暂无仓库。").foregroundStyle(.secondary) } }
                    if !error.isEmpty { SoftGroupRow("error") { Text(error).font(.caption) } }
                    if updatedAt != nil { SoftGroupRow("freshness") { ContentFreshnessText(updatedAt: updatedAt, updating: busy, error: error) } }
                }
            }
        }.listStyle(.insetGrouped).navigationTitle(list.name).adaptiveWorkspaceLayout().disabled(!api.isCurrentSession)
        .navigationBarBackButtonHidden(busy)
        .toolbar {
            ListSearchButton(visible: $searchVisible, query: $query, title: list.name)
            NativeActionMenu(title: "分类仓库操作", enabled: !busy, items: [
                NativeMenuItem(id: "add", title: "添加已加星标的仓库", symbol: "plus", perform: { adding = true }),
                NativeMenuItem(id: "refresh", title: "刷新分类", symbol: "arrow.clockwise", perform: { operation = Task { await load() } })
            ])
        }
        .task {
            if let cached = api.cachedContent([StarListRepository].self, key: "star-list:" + list.id) { repositories = cached.value; updatedAt = cached.savedAt }
            await load()
        }.refreshable { await load() }
        .sheet(isPresented: $adding, onDismiss: { operation = Task { await load() } }) { AppNavigationStack { StarListRepositoryPicker(api: api, list: list) }.appSheetCornerRadius() }
        .confirmationDialog("移出这个分类？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { item in
            Button("移出分类", role: .destructive) {
                operation = Task {
                    guard !busy else { return }; busy = true; error = ""
                    do { try await api.starLists.setMembership(item.repository, list: list, included: false) }
                    catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription + " 请刷新核对结果。" } }
                    busy = false; if error.isEmpty { await load() }
                }
            }
        } message: { item in Text(item.nameWithOwner + "。仓库仍然保持Star，并保留其他分类归属。") }
        .onDisappear { operation?.cancel() }
    }
    private func load() async {
        guard !busy, api.isCurrentSession else { return }; busy = true; error = ""; defer { busy = false }
        do {
            let values = try await api.starLists.repositories(in: list)
            try Task.checkCancellation(); guard api.isCurrentSession else { return }; repositories = values; updatedAt = Date()
            if let data = try? JSONEncoder().encode(values) { ContentSnapshotCache.shared.save(data, accountID: api.accountID, key: "star-list:" + list.id) }
        }
        catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription } }
    }
}

private struct StarListRepositoryPicker: View {
    @ObservedObject var api: GitHub
    let list: StarRepositoryList
    @Environment(\.dismiss) private var dismiss
    @State private var repositories: [Repository] = []
    @State private var query = ""
    @State private var busy = false
    @State private var error = ""
    @State private var attempted = false
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    for repository in repositories.filter({ HomeListSearch.matches(query, fields: [$0.full_name, $0.description ?? ""]) }) {
                        SoftGroupRow(String(repository.id)) {
                            Button {
                                busy = true; attempted = true; error = ""
                                Task {
                                    defer { busy = false }
                                    do { try await api.starLists.setMembership(repository, list: list, included: true); guard api.isCurrentSession else { return }; dismiss() }
                                    catch { if api.isCurrentSession { self.error = error.localizedDescription + " 请核对分类后再操作。" } }
                                }
                            } label: {
                                CompactRepositorySummary(fullName: repository.full_name, name: repository.name,
                                    owner: repository.owner?.login, avatarURL: repository.owner?.avatar_url, description: repository.description)
                            }.buttonStyle(.plain).disabled(attempted)
                                .accessibilityIdentifier("star-list-add-\(repository.id)")
                        }
                    }
                    if busy { SoftGroupRow("busy") { ProgressView("读取并核对仓库…") } }
                    if !busy && repositories.isEmpty { SoftGroupRow("empty") { Text("暂无已加星标的仓库。") } }
                    if !error.isEmpty { SoftGroupRow("error") { Text(error).font(.caption) } }
                }
            }
        }.listStyle(.insetGrouped).navigationTitle("添加到分类").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索已加星标的仓库").disabled(busy || !api.isCurrentSession)
        .interactiveDismissDisabled(busy)
        .toolbar { Button("取消") { dismiss() }.disabled(busy) }
        .task {
            busy = true; defer { busy = false }
            do { let values = try await api.starredRepositories(); try Task.checkCancellation(); guard api.isCurrentSession else { return }; repositories = values }
            catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
}
