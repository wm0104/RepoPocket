import SwiftUI

@MainActor final class UpstreamUpdatesStore: ObservableObject {
    @Published private(set) var watches: [UpstreamWatch] = []
    @Published private(set) var updates: [String: UpstreamWatchUpdate] = [:]
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var loading = false
    private var account = ""
    private var excluded: Set<String> = []
    private var lastCheck: Date?

    func restore(api: GitHub) {
        guard api.isCurrentSession else { return }
        if account != api.accountID {
            account = api.accountID
            watches = (UserDefaults.standard.data(forKey: UpstreamWatchRules.key(account))).flatMap { try? JSONDecoder().decode([UpstreamWatch].self, from: $0) } ?? []
            excluded = Set(UserDefaults.standard.stringArray(forKey: UpstreamWatchRules.key(account) + ".excluded") ?? [])
            updates = [:]; failures = [:]; lastCheck = nil
        }
        let prefix = "RepoPocket.upstreamSync.v1." + account + "."
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix(prefix) {
            guard let saved = UpstreamSyncRules.decodeMemory(value as? String),
                  let watch = try? UpstreamWatchRules.watch(repository: saved.repository, branch: saved.branch),
                  !excluded.contains(watch.id), !watches.contains(where: { $0.id == watch.id }) else { continue }
            watches.append(watch)
        }
        save()
    }
    func add(_ watch: UpstreamWatch, api: GitHub) {
        guard api.isCurrentSession, account == api.accountID, !loading else { return }
        excluded.remove(watch.id)
        if !watches.contains(where: { $0.id == watch.id }) { watches.append(watch) }
        lastCheck = nil; save()
    }
    func remove(_ watch: UpstreamWatch, api: GitHub) {
        guard api.isCurrentSession, account == api.accountID, !loading else { return }
        watches.removeAll { $0.id == watch.id }; excluded.insert(watch.id)
        updates[watch.id] = nil; failures[watch.id] = nil; save()
    }
    func acknowledge(_ watch: UpstreamWatch, api: GitHub) {
        guard api.isCurrentSession, !loading, let update = updates[watch.id],
              let index = watches.firstIndex(where: { $0.id == watch.id }) else { return }
        watches[index] = UpstreamWatchRules.acknowledge(watches[index], head: update.head, branches: update.branches)
        updates[watch.id] = UpstreamWatchUpdate(head: update.head, branches: update.branches, comparison: nil, changed: false, newBranches: [])
        save()
    }
    private func save() {
        guard !account.isEmpty, AccountStore.activeID == account else { return }
        if let data = try? JSONEncoder().encode(watches) { UserDefaults.standard.set(data, forKey: UpstreamWatchRules.key(account)) }
        UserDefaults.standard.set(Array(excluded), forKey: UpstreamWatchRules.key(account) + ".excluded")
    }
    func refresh(api: GitHub, force: Bool = false) async {
        guard api.isCurrentSession, !loading else { return }
        restore(api: api)
        guard force || (lastCheck.map { Date().timeIntervalSince($0) >= 300 } ?? true) else { return }
        let generation = AccountStore.generation
        loading = true; defer { loading = false }
        for watch in watches {
            guard !Task.isCancelled, api.isCurrentSession, generation == AccountStore.generation else { return }
            do {
                let head = try await api.upstreamBranchHead(repo: watch.repository, branch: watch.branch)
                var branches: [String] = []
                for page in 1...30 {
                    let batch = try await api.branches(watch.repository, page: page)
                    branches += batch.map(\.name)
                    if batch.count < 100 { break }
                    if page == 30 { throw AppError(text: "仓库分支过多，未进行不完整检测。") }
                }
                var comparison: UpstreamCompare?
                var warning: String?
                if let path = try UpstreamWatchRules.comparePath(watch, head: head) {
                    do { comparison = try JSONDecoder().decode(UpstreamCompare.self, from: await api.communityRead(path)) }
                    catch {
                        if RefreshFailure.isCancellation(error) { throw error }
                        warning = "提交已变化，但暂时无法比较历史：" + error.localizedDescription
                    }
                }
                try Task.checkCancellation()
                guard api.isCurrentSession, generation == AccountStore.generation,
                      let index = watches.firstIndex(where: { $0.id == watch.id }) else { return }
                updates[watch.id] = UpstreamWatchUpdate(head: head, branches: branches, comparison: comparison,
                    changed: watch.seenHead.map { $0 != head } ?? false,
                    newBranches: UpstreamWatchRules.newBranches(seen: watch.seenBranches, current: branches))
                failures[watch.id] = warning
                // First check establishes a baseline, not a flood of historical notifications.
                if watch.seenHead == nil { watches[index] = UpstreamWatchRules.acknowledge(watch, head: head, branches: branches) }
            } catch {
                guard api.isCurrentSession, generation == AccountStore.generation, !RefreshFailure.isCancellation(error) else { return }
                failures[watch.id] = error.localizedDescription
            }
        }
        guard api.isCurrentSession, generation == AccountStore.generation else { return }
        lastCheck = Date(); save()
    }
}

struct UpstreamUpdatesSection: View {
    @ObservedObject var api: GitHub
    @ObservedObject var store: UpstreamUpdatesStore
    var connected = false
    let add: () -> Void
    var body: some View {
        Group {
            if connected { content }
            else { Section("上游动态") { content } }
        }
        .task { await store.refresh(api: api) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RepoPocket.upstreamForegroundCheck"))) { notification in
            guard notification.object as? String == api.accountID else { return }
            Task { await store.refresh(api: api) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RepoPocket.upstreamSourceSelected"))) { notification in
            guard notification.object as? String == api.accountID else { return }
            Task { await store.refresh(api: api, force: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RepoPocket.upstreamRefreshRequested"))) { notification in
            guard notification.object as? String == api.accountID else { return }
            Task { await store.refresh(api: api, force: true) }
        }
    }
    private var content: some View {
            SoftGroupRows(spacingBefore: connected ? 10 : 0) {
            if connected { SoftGroupRow("heading") { Text("上游动态").font(.subheadline).foregroundStyle(.secondary) } }
            for watch in store.watches {
                SoftGroupRow(watch.id) {
                    NavigationLink {
                        UpstreamUpdatesDetail(api: api, store: store, watch: watch)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(watch.repository)
                            Text(watch.branch).font(.caption).foregroundStyle(.secondary)
                            Text(summary(watch)).font(.caption)
                        }
                    }
                    .contextMenu { Button("停止跟踪", role: .destructive) { store.remove(watch, api: api) }.disabled(store.loading) }
                }
            }
            if store.loading { SoftGroupRow("loading") { ProgressView("检查上游更新…") } }
            if store.watches.isEmpty {
                SoftGroupRow("empty") { Text("跟踪已设置的上游，也可以添加指定仓库。首次检查只记录基线，之后显示新提交和新分支。").font(.caption).foregroundStyle(.secondary) }
            }
            SoftGroupRow("add") { Button("添加跟踪仓库", action: add).disabled(store.loading).accessibilityIdentifier("upstream-watch-add") }
        }
    }
    private func summary(_ watch: UpstreamWatch) -> String {
        if let error = store.failures[watch.id] { return error }
        guard let update = store.updates[watch.id] else { return "等待检查" }
        var messages: [String] = []
        if update.changed { messages.append(update.count > 0 ? "有 \(update.count) 条新提交" : "提交历史有变化") }
        if !update.newBranches.isEmpty { messages.append("新增 \(update.newBranches.count) 个分支") }
        return messages.isEmpty ? "暂未发现新变化" : messages.joined(separator: " · ")
    }
}

struct UpstreamWatchAddView: View {
    @ObservedObject var api: GitHub
    let add: (UpstreamWatch) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repository = ""
    @State private var branch = ""
    @State private var failure = ""
    @State private var branchRepository: String?
    @FocusState private var editingRepository: Bool
    var body: some View {
        let canonical = try? RepositoryInput.parse(repository)
        return Form {
            Section {
                SoftGroupRows {
                    SoftGroupRow("repository") {
                        TextField("仓库名称或链接", text: Binding(get: { repository }, set: {
                            guard repository != $0 else { return }
                            repository = $0; branch = ""
                        })).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($editingRepository).accessibilityIdentifier("upstream-watch-repository")
                    }
                    SoftGroupRow("branch") {
                        Button {
                            editingRepository = false
                            branchRepository = canonical
                        } label: { AppLabeledContent("分支", value: branch.isEmpty ? "请选择" : branch) }
                            .disabled(canonical == nil)
                            .accessibilityIdentifier("upstream-watch-branch")
                    }
                    SoftGroupRow("save") {
                        Button("开始跟踪") {
                            do { add(try UpstreamWatchRules.watch(repository: repository, branch: branch)); dismiss() }
                            catch { failure = error.localizedDescription }
                        }.disabled(branch.isEmpty || canonical == nil || !api.isCurrentSession)
                            .accessibilityIdentifier("upstream-watch-save")
                    }
                    if !failure.isEmpty { SoftGroupRow("error") { Text(failure).foregroundStyle(.secondary) } }
                    SoftGroupRow("scope") { Text("只在打开 App 或下拉刷新时检查，不是后台实时推送；不会自动合并、创建分支或修改远端代码。").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle("跟踪仓库").adaptiveWorkspaceLayout()
            .toolbar { Button("关闭") { dismiss() }.accessibilityIdentifier("upstream-watch-close") }
            .sheet(isPresented: Binding(get: { branchRepository != nil }, set: { if !$0 { branchRepository = nil } })) {
                if let selectedRepository = branchRepository {
                    AppNavigationStack {
                        LocalGitBranchPicker(api: api, repo: selectedRepository, current: branch) {
                            guard api.isCurrentSession, canonical == selectedRepository else { return }
                            branch = $0
                        }.toolbar { Button("关闭") { branchRepository = nil } }
                    }.appSheetCornerRadius()
                }
            }
    }
}

private struct UpstreamUpdatesDetail: View {
    @ObservedObject var api: GitHub
    @ObservedObject var store: UpstreamUpdatesStore
    let watch: UpstreamWatch
    private var update: UpstreamWatchUpdate? { store.updates[watch.id] }
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    SoftGroupRow("source") { Text(watch.repository + " · " + watch.branch).textSelection(.enabled) }
                    SoftGroupRow("refresh") { Button("检查更新") { Task { await store.refresh(api: api, force: true) } }.disabled(store.loading) }
                    if let failure = store.failures[watch.id] { SoftGroupRow("error") { Text(failure).font(.caption).foregroundStyle(.secondary) } }
                    SoftGroupRow("history") { NavigationLink("查看此分支提交") { HistoryView(api: api, repo: watch.repository, branch: watch.branch) } }
                    SoftGroupRow("sync") { NavigationLink("同步到我的仓库") { UpstreamWatchTargetView(api: api, source: watch) } }
                    SoftGroupRow("read") { Button("标为已读") { store.acknowledge(watch, api: api) }.disabled(update == nil || store.loading) }
                    SoftGroupRow("commits-heading") { Text("新增提交").font(.subheadline).foregroundStyle(.secondary) }
                    for commit in (update?.comparison?.commits ?? []).suffix(30).reversed() {
                        SoftGroupRow("commit:" + commit.sha) {
                            NavigationLink { CommitDetailView(api: api, repo: watch.repository, sha: commit.sha) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(commit.commit.message.split(separator: "\n").first.map(String.init) ?? "无提交说明").lineLimit(2)
                                    Text(String(commit.sha.prefix(8)) + " · " + (commit.commit.author?.name ?? "未知作者")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if update?.changed != true { SoftGroupRow("no-commits") { Text("没有未读的新提交").foregroundStyle(.secondary) } }
                    else { SoftGroupRow("limit") { Text("显示最多 30 条提交；点击提交查看文件和代码差异，完整记录可在分支提交列表查看。").font(.caption).foregroundStyle(.secondary) } }
                    SoftGroupRow("branches-heading") { Text("新增分支").font(.subheadline).foregroundStyle(.secondary) }
                    for branch in update?.newBranches ?? [] {
                        SoftGroupRow("branch:" + branch) { NavigationLink(branch) { UpstreamNewBranchView(api: api, store: store, repository: watch.repository, branch: branch) } }
                    }
                    if update?.newBranches.isEmpty != false { SoftGroupRow("no-branches") { Text("没有未读的新分支").foregroundStyle(.secondary) } }
                }
            }
        }.navigationTitle("上游更新").listStyle(.insetGrouped).adaptiveWorkspaceLayout()
    }
}

private struct UpstreamWatchTargetView: View {
    @ObservedObject var api: GitHub
    let source: UpstreamWatch
    @State private var repository: Repository?
    @State private var branch = ""
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    SoftGroupRow("source") { Text("上游：" + source.repository + " · " + source.branch).font(.caption) }
                    SoftGroupRow("repo") {
                        NavigationLink {
                            LocalGitRepositoryPicker(api: api) { repository = $0; branch = "" }
                        } label: { AppLabeledContent("目标仓库", value: repository?.full_name ?? "请选择") }
                    }
                    SoftGroupRow("branch") {
                        NavigationLink {
                            LocalGitBranchPicker(api: api, repo: repository?.full_name ?? "", current: branch) { branch = $0 }
                        } label: { AppLabeledContent("目标分支", value: branch.isEmpty ? "请选择" : branch) }
                            .disabled(repository == nil)
                    }
                    if let repository, !branch.isEmpty {
                        SoftGroupRow("preview") {
                            NavigationLink {
                                UpstreamSyncView(api: api, repo: repository.full_name, branch: branch,
                                    canWrite: repository.permissions?.push == true, repository: repository,
                                    initialUpstream: .init(repository: source.repository, branch: source.branch))
                            } label: { Text("预览上游差异") }
                        }
                    }
                    SoftGroupRow("hint") { Text("先预览，再在临时分支合并；有冲突即停，确认后才应用到目标分支，不会强制推送。").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle("选择同步目标").listStyle(.insetGrouped).adaptiveWorkspaceLayout()
    }
}

private struct UpstreamNewBranchView: View {
    @ObservedObject var api: GitHub
    @ObservedObject var store: UpstreamUpdatesStore
    let repository: String
    let branch: String
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    SoftGroupRow("branch") { Text(repository + " · " + branch).textSelection(.enabled) }
                    SoftGroupRow("history") { NavigationLink("查看分支提交与代码差异") { HistoryView(api: api, repo: repository, branch: branch) } }
                    SoftGroupRow("sync") {
                        NavigationLink("同步此分支到我的仓库") {
                            UpstreamWatchTargetView(api: api, source: UpstreamWatch(repository: repository, branch: branch))
                        }
                    }
                    SoftGroupRow("watch") {
                        Button("跟踪此分支后续提交") { store.add(UpstreamWatch(repository: repository, branch: branch), api: api) }
                            .disabled(store.loading || store.watches.contains { $0.repository == repository && $0.branch == branch })
                    }
                }
            }
        }.navigationTitle("新增分支").listStyle(.insetGrouped).adaptiveWorkspaceLayout()
    }
}
