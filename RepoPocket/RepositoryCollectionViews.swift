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
    private enum Mode { case normal, sorting, removing }
    @State private var mode = Mode.normal
    @State private var repositories: [StarListRepository] = []
    @State private var busy = false
    @State private var membershipKnown = false
    @State private var orderReady = false
    @State private var error = ""
    @State private var notice = ""
    @State private var progress = ""
    @State private var adding = false
    @State private var removing: StarListRepository?
    @State private var confirmingBatch = false
    @State private var selected = Set<String>()
    @State private var query = ""
    @State private var searchVisible = false
    @State private var operation: Task<Void, Never>?
    @State private var updatedAt: Date?
    private var values: [StarListRepository] {
        repositories.filter { HomeListSearch.matches(query, fields: [$0.nameWithOwner, $0.description ?? ""]) }
    }
    private var storage: StarListLocalOrder { StarListLocalOrder(accountID: api.accountID) }
    var body: some View {
        Group {
            if mode == .sorting {
                VStack(spacing: 0) {
                    Text("长按卡片拖动排序，每次放下即保存。仅保存在本机。")
                        .font(.caption).foregroundStyle(.secondary).padding()
                    if !error.isEmpty { Text(error).font(.caption).padding(.horizontal).accessibilityIdentifier("star-list-detail-error") }
                    StarListReorderView(items: repositories, isCurrent: { api.isCurrentSession && mode == .sorting && query.isEmpty }, card: { item in
                        AnyView(RepositoryCard(repository: item.repository, account: api.login, api: api, copyLinkContextMenu: false).allowsHitTesting(false))
                    }, commit: saveOrder)
                }
            } else {
                List {
                    Section {
                        SoftGroupRows {
                            if searchVisible { SoftGroupRow("search") { ListSearchField(query: $query, title: list.name) } }
                            for item in values {
                                SoftGroupRow(item.id) {
                                    if mode == .removing {
                                        Button {
                                            if !selected.insert(item.id).inserted { selected.remove(item.id) }
                                        } label: {
                                            HStack {
                                                Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                                // Selection rows must not embed the normal card's owner/parent buttons.
                                                CompactRepositorySummary(fullName: item.repository.full_name, name: item.repository.name,
                                                    owner: item.repository.owner?.login, avatarURL: item.repository.owner?.avatar_url,
                                                    description: item.repository.description, repository: item.repository, starStore: api.stars)
                                                    .environment(\.repositorySocialAPI, nil)
                                            }
                                        }.buttonStyle(.plain).disabled(busy || !membershipKnown)
                                            .accessibilityElement(children: .ignore).accessibilityLabel(item.nameWithOwner)
                                            .accessibilityIdentifier("star-list-select-" + item.id)
                                            .accessibilityValue(selected.contains(item.id) ? "已选择" : "未选择")
                                    } else {
                                        NavigationLink { BrowserView(api: api, repo: item.nameWithOwner, path: "", branch: "") }
                                            label: { RepositoryCard(repository: item.repository, account: api.login, api: api) }
                                            .accessibilityIdentifier("star-list-repository-" + item.id)
                                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                                Button("移出分类", role: .destructive) { removing = item }.disabled(busy || !membershipKnown)
                                            }
                                    }
                                }
                            }
                            if busy && repositories.isEmpty { SoftGroupRow("busy") { ProgressView("核对分类…") } }
                            if busy && !progress.isEmpty { SoftGroupRow("progress") { ProgressView(progress).accessibilityIdentifier("star-list-remove-progress") } }
                            if !busy && repositories.isEmpty && error.isEmpty { SoftGroupRow("empty") { Text("此分类暂无仓库。").foregroundStyle(.secondary) } }
                            if !notice.isEmpty { SoftGroupRow("notice") { Text(notice).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("star-list-detail-notice") } }
                            if !error.isEmpty { SoftGroupRow("error") { Text(error).font(.caption).accessibilityIdentifier("star-list-detail-error") } }
                            if updatedAt != nil { SoftGroupRow("freshness") { ContentFreshnessText(updatedAt: updatedAt, updating: busy, error: error) } }
                        }
                    }
                }.listStyle(.insetGrouped).refreshable { if mode != .sorting { await load() } }
            }
        }.navigationTitle(list.name).adaptiveWorkspaceLayout().disabled(!api.isCurrentSession)
        .navigationBarBackButtonHidden(busy)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if mode != .sorting { ListSearchButton(visible: $searchVisible, query: $query, title: list.name) }
                if mode != .normal {
                    Button("完成") { mode = .normal; selected.removeAll() }.disabled(busy)
                        .accessibilityIdentifier("star-list-edit-done")
                }
                if mode == .normal {
                    NativeActionMenu(title: "分类仓库操作", enabled: !busy, items: [
                        NativeMenuItem(id: "add", title: "添加已加星标的仓库", symbol: "plus", perform: { adding = true }),
                        NativeMenuItem(id: "sort", title: "编辑排序", symbol: "arrow.up.arrow.down", enabled: !repositories.isEmpty && membershipKnown && orderReady,
                            perform: {
                                guard query.isEmpty else { error = "请先清空搜索词，再编辑全部仓库的排序。"; return }
                                error = ""; mode = .sorting
                            }),
                        NativeMenuItem(id: "refresh", title: "刷新分类", symbol: "arrow.clockwise", perform: { operation = Task { await load() } })
                    ])
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if mode == .removing {
                    Button("从分类移除(\(selected.count))", role: .destructive) { confirmingBatch = true }
                        .disabled(busy || selected.isEmpty || !membershipKnown).accessibilityIdentifier("star-list-remove-selected")
                }
            }
        }
        .task {
            if repositories.isEmpty, let cached = api.cachedContent([StarListRepository].self, key: "star-list:" + list.id) {
                apply(cached.value, authoritative: false); updatedAt = cached.savedAt
            }
            await load()
        }
        .sheet(isPresented: $adding, onDismiss: { operation = Task { await load() } }) {
            AppNavigationStack { StarListRepositoryPicker(api: api, list: list) }.appSheetCornerRadius()
        }
        .confirmationDialog("移出这个分类？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { item in
            Button("移出分类", role: .destructive) { removing = nil; operation = Task { await remove([item]) } }
            Button("取消", role: .cancel) { removing = nil }
        } message: { item in Text(item.nameWithOwner + "。仓库仍然保持Star，并保留其他分类归属。") }
        .confirmationDialog("从分类移除\(selected.count)个仓库？", isPresented: $confirmingBatch, titleVisibility: .visible) {
            Button("确认从分类移除", role: .destructive) {
                let pending = repositories.filter { selected.contains($0.id) }
                operation = Task { await remove(pending) }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("只移出当前分类，保留Star、其他分类和仓库本身；不会删除分类。") }
        .onChange(of: query) { _ in if mode == .sorting { mode = .normal } }
        .onChange(of: api.isCurrentSession) { current in
            if !current { operation?.cancel(); mode = .normal; membershipKnown = false; selected.removeAll(); removing = nil; confirmingBatch = false }
        }
        .onDisappear { operation?.cancel(); mode = .normal; membershipKnown = false; selected.removeAll(); removing = nil; confirmingBatch = false }
    }
    private func saveOrder(_ ids: [String]) -> Bool {
        guard api.isCurrentSession, mode == .sorting, query.isEmpty,
              ids.count == repositories.count, Set(ids) == Set(repositories.map(\.id)) else { return false }
        do {
            try storage.save(ids, listID: list.id, isCurrent: { api.isCurrentSession })
            let byID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
            repositories = ids.compactMap { byID[$0] }; error = ""
            return true
        } catch { self.error = "排序未保存，已恢复原顺序：" + error.localizedDescription; return false }
    }
    private func apply(_ values: [StarListRepository], authoritative: Bool) {
        repositories = values; orderReady = false
        do {
            let ids = try storage.orderedIDs(listID: list.id, members: values.map(\.id))
            let byID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
            repositories = ids.compactMap { byID[$0] }
            // A failed prune/save must not discard an order that was read successfully.
            if authoritative { try storage.save(ids, listID: list.id, isCurrent: { api.isCurrentSession }) }
            orderReady = true
        } catch { self.error = "本机排序读取或保存失败：" + error.localizedDescription }
        if authoritative {
            membershipKnown = true; selected.formIntersection(Set(values.map(\.id))); updatedAt = Date()
            if let data = try? JSONEncoder().encode(values) { ContentSnapshotCache.shared.save(data, accountID: api.accountID, key: "star-list:" + list.id) }
        }
    }
    @discardableResult private func reconcile() async -> Bool {
        membershipKnown = false
        do {
            let values = try await api.starLists.repositories(in: list)
            try Task.checkCancellation(); guard api.isCurrentSession else { return false }
            apply(values, authoritative: true)
            return true
        } catch {
            if api.isCurrentSession, !RefreshFailure.isCancellation(error) {
                membershipKnown = false
                self.error += (self.error.isEmpty ? "" : "\n") + "成员核对失败：" + error.localizedDescription + " 请刷新；不会自动重发。"
            }
            return false
        }
    }
    private func load() async {
        guard !busy, api.isCurrentSession, mode != .sorting else { return }
        busy = true; error = ""; defer { busy = false }
        await reconcile()
    }
    private func remove(_ pending: [StarListRepository]) async {
        guard !busy, membershipKnown, !pending.isEmpty, api.isCurrentSession else { return }
        busy = true; error = ""; notice = ""; progress = "准备移出 0/\(pending.count)"
        defer { busy = false; progress = "" }
        var succeeded = 0
        for (offset, item) in pending.enumerated() {
            guard !Task.isCancelled, api.isCurrentSession else { return }
            progress = "正在移出 \(offset + 1)/\(pending.count)"
            do {
                try await api.starLists.setMembership(item.repository, list: list, included: false)
                try Task.checkCancellation(); guard api.isCurrentSession else { return }
                succeeded += 1; selected.remove(item.id)
                apply(repositories.filter { $0.id != item.id }, authoritative: true)
            } catch {
                guard api.isCurrentSession, !RefreshFailure.isCancellation(error) else { return }
                self.error = error.localizedDescription + " 已暂停，请核对未完成项；不会自动重发。"
                break
            }
        }
        progress = "只读核对分类成员…"
        let verified = await reconcile()
        guard api.isCurrentSession, !Task.isCancelled else { return }
        if verified {
            let remaining = Set(repositories.map(\.id))
            succeeded = pending.filter { !remaining.contains($0.id) }.count
        }
        notice = "已从分类移出\(succeeded)/\(pending.count)个仓库" + (verified ? "" : "；部分结果待核对")
    }
}

private struct StarListRepositoryPicker: View {
    @ObservedObject var api: GitHub
    let list: StarRepositoryList
    @Environment(\.dismiss) private var dismiss
    @State private var repositories: [Repository] = []
    @State private var memberIDs = Set<Int>()
    @State private var membershipKnown = false
    @State private var selected = Set<Int>()
    @State private var multiple = false
    @State private var query = ""
    @State private var busy = false
    @State private var error = ""
    @State private var notice = ""
    @State private var progress = ""
    @State private var operation: Task<Void, Never>?
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    for repository in repositories.filter({ HomeListSearch.matches(query, fields: [$0.full_name, $0.description ?? ""]) }) {
                        SoftGroupRow(String(repository.id)) {
                            Button {
                                if multiple {
                                    if !selected.insert(repository.id).inserted { selected.remove(repository.id) }
                                } else { operation = Task { await add([repository]) } }
                            } label: {
                                HStack {
                                    if multiple { Image(systemName: selected.contains(repository.id) ? "checkmark.circle.fill" : "circle") }
                                    CompactRepositorySummary(fullName: repository.full_name, name: repository.name,
                                        owner: repository.owner?.login, avatarURL: repository.owner?.avatar_url, description: repository.description)
                                    if memberIDs.contains(repository.id) { Text("已添加").font(.caption).foregroundStyle(.secondary) }
                                    else if !membershipKnown { Text("待核对").font(.caption).foregroundStyle(.secondary) }
                                }
                            }.buttonStyle(.plain).disabled(busy || !membershipKnown || memberIDs.contains(repository.id))
                                .accessibilityIdentifier("star-list-add-\(repository.id)")
                                .accessibilityValue(memberIDs.contains(repository.id) ? "已添加" : !membershipKnown ? "待核对" : selected.contains(repository.id) ? "已选择" : "未选择")
                        }
                    }
                    if busy { SoftGroupRow("busy") { ProgressView(progress.isEmpty ? "读取并核对仓库…" : progress).accessibilityIdentifier("star-list-add-progress") } }
                    if !busy && repositories.isEmpty { SoftGroupRow("empty") { Text("暂无已加星标的仓库。") } }
                    if !error.isEmpty { SoftGroupRow("error") { Text(error).font(.caption).accessibilityIdentifier("star-list-add-error") } }
                    if !membershipKnown && !busy {
                        SoftGroupRow("verify") { Button("重新读取并核对") { operation = Task { await load() } } }
                    }
                }
            }
        }.listStyle(.insetGrouped).navigationTitle("添加到分类").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索已加星标的仓库").disabled(!api.isCurrentSession)
        .interactiveDismissDisabled(busy)
        .overlay(alignment: .topTrailing) {
            if !notice.isEmpty {
                Text(notice).font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8).allowsHitTesting(false)
                    .accessibilityIdentifier("star-list-add-notice")
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { selected.removeAll(); dismiss() }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) {
                Button(multiple ? "取消多选" : "多选") { selected.removeAll(); multiple.toggle() }
                    .disabled(busy || !membershipKnown).accessibilityIdentifier("star-list-add-multiple")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if multiple {
                    Button("添加(\(selected.count))") {
                        let pending = repositories.filter { selected.contains($0.id) && !memberIDs.contains($0.id) }
                        operation = Task { await add(pending) }
                    }.disabled(busy || !membershipKnown || selected.isEmpty).accessibilityIdentifier("star-list-add-selected")
                }
            }
        }
        .task { await load() }
        .onChange(of: api.isCurrentSession) { current in
            if !current { operation?.cancel(); membershipKnown = false; selected.removeAll(); multiple = false }
        }
        .onDisappear { operation?.cancel(); membershipKnown = false; selected.removeAll() }
    }
    @discardableResult private func reconcile() async -> Bool {
        membershipKnown = false
        do {
            let members = try await api.starLists.repositories(in: list)
            try Task.checkCancellation(); guard api.isCurrentSession else { return false }
            memberIDs = Set(members.map(\.databaseId)); membershipKnown = true
            selected.formIntersection(Set(repositories.map(\.id)).subtracting(memberIDs))
            do {
                let storage = StarListLocalOrder(accountID: api.accountID)
                let ids = try storage.orderedIDs(listID: list.id, members: members.map(\.id))
                try storage.save(ids, listID: list.id, isCurrent: { api.isCurrentSession })
            } catch { self.error += "\n本机排序更新失败：" + error.localizedDescription }
            return true
        } catch {
            guard api.isCurrentSession, !RefreshFailure.isCancellation(error) else { return false }
            membershipKnown = false
            self.error += (self.error.isEmpty ? "" : "\n") + "成员核对失败：" + error.localizedDescription + " 请重新核对；不会自动重发。"
            return false
        }
    }
    private func load() async {
        guard !busy, api.isCurrentSession else { return }
        busy = true; membershipKnown = false; error = ""; notice = ""; defer { busy = false }
        do {
            let values = try await api.starredRepositories()
            try Task.checkCancellation(); guard api.isCurrentSession else { return }
            repositories = values
            selected.formIntersection(Set(values.map(\.id)).subtracting(memberIDs))
            await reconcile()
        } catch {
            if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription }
        }
    }
    private func add(_ pending: [Repository]) async {
        guard !busy, membershipKnown, !pending.isEmpty, api.isCurrentSession else { return }
        busy = true; error = ""; notice = ""; defer { busy = false; progress = "" }
        var succeeded = 0
        for (offset, repository) in pending.enumerated() {
            guard !Task.isCancelled, api.isCurrentSession else { return }
            guard !memberIDs.contains(repository.id) else { selected.remove(repository.id); continue }
            progress = "正在添加 \(offset + 1)/\(pending.count)"
            do {
                try await api.starLists.setMembership(repository, list: list, included: true)
                try Task.checkCancellation(); guard api.isCurrentSession else { return }
                memberIDs.insert(repository.id); selected.remove(repository.id); succeeded += 1
                notice = pending.count == 1 ? "添加成功" : "已添加\(succeeded)/\(pending.count)个仓库"
            } catch {
                guard api.isCurrentSession, !RefreshFailure.isCancellation(error) else { return }
                self.error = error.localizedDescription + " 已暂停，请核对未完成项；不会自动重发。"
                break
            }
        }
        progress = "只读核对分类成员…"
        let verified = await reconcile()
        guard api.isCurrentSession, !Task.isCancelled else { return }
        if verified { succeeded = pending.filter { memberIDs.contains($0.id) }.count }
        if pending.count == 1 && succeeded == 1 { notice = "添加成功" }
        else { notice = "已添加\(succeeded)/\(pending.count)个仓库" }
        if !verified { notice += "；部分结果待核对" }
        // Remain on this page in both single and multiple selection modes.
    }
}
