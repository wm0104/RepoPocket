import SwiftUI

struct RepositoryFeatureLabel: View {
    let title: String
    let symbol: String
    let color: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.white).frame(width: 30, height: 30)
                .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).accessibilityHidden(true)
            Text(title)
        }.padding(.vertical, 3)
    }
}

struct RepositoryCommunitySection: View {
    @ObservedObject var api: GitHub
    let repo: String
    let branch: String
    let avatar: String?
    @State private var expanded = false
    private var owner: String? { (try? RepositoryInput.parse(repo))?.split(separator: "/").first.map(String.init) }
    var body: some View {
        Section {
            SoftGroupRows {
            SoftGroupRow("issues", separatorInset: 62) { NavigationLink { CollaborationListView(api: api, repo: repo, kind: .issues) } label: { RepositoryFeatureLabel(title: "议题", symbol: "exclamationmark.circle", color: .green) } }
            SoftGroupRow("pulls", separatorInset: 62) { NavigationLink { CollaborationListView(api: api, repo: repo, kind: .pulls) } label: { RepositoryFeatureLabel(title: "拉取请求", symbol: "arrow.triangle.branch", color: .blue) } }
            SoftGroupRow("actions", separatorInset: 62) { NavigationLink { WorkflowRunsView(api: api, repo: repo, branch: branch) } label: { RepositoryFeatureLabel(title: "操作 · Actions", symbol: "play.circle", color: .orange) } }
            SoftGroupRow("more", separatorInset: 62) {
                Button { expanded.toggle() } label: {
                    HStack { RepositoryFeatureLabel(title: "更多", symbol: "ellipsis", color: .gray); Spacer(); Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary) }
                }.buttonStyle(.plain).accessibilityValue(expanded ? "已展开" : "已折叠")
            }
            if expanded {
            SoftGroupRow("tools") { NavigationLink { RepositoryToolsView(api: api, repo: repo) } label: { Label("贡献者、统计与工具", systemImage: "chart.bar") } }
            if let owner {
                SoftGroupRow("owner") { NavigationLink("仓库作者") { UserRepositoriesView(api: api, user: User(id: nil, login: owner, avatar_url: avatar, name: nil, followers: nil, following: nil)) } }
            }
            }
            }
        }
#if DEBUG
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-expanded-style-preview") { expanded = true } }
#endif
    }
}

struct CollaborationListView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let kind: CollaborationKind
    @StateObject private var store = CommunityPageStore<CollaborationItem>()
    @State private var state = "open"
    @State private var composing = false
    private var visible: [CollaborationItem] { store.items.filter { kind == .pulls || $0.pull_request == nil } }
    var body: some View {
        List {
            Section {
            SoftGroupRows {
            SoftGroupRow("filter") {
            Picker("状态", selection: $state) {
                Text("开放").tag("open"); Text("已关闭").tag("closed"); Text("全部").tag("all")
            }.pickerStyle(.segmented)
            }
            for item in visible {
                SoftGroupRow("item-\(item.id)") {
                NavigationLink { CollaborationDetailView(api: api, repo: repo, kind: kind, number: item.number) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.headline)
                        Text("#\(item.number) · \(item.user?.login ?? "未知作者") · \(item.draft == true ? "草稿" : item.state)")
                            .font(.caption).foregroundStyle(.secondary)
                        if let date = item.updated_at { Text(ChinaDate.dateTime(date)).font(.caption2).foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
                }
                }
            }
            if store.loaded && visible.isEmpty && store.error.isEmpty { SoftGroupRow("empty") { Text("当前页没有符合条件的 \(kind.title)" + (store.more ? "，可继续加载。" : "。")) } }
            }
            }
            CommunityPageFooter(store: store, next: { load() })
        }.navigationTitle(kind.title).adaptiveWorkspaceLayout()
        .toolbar {
            if kind == .issues { Button("新建议题") { composing = true } }
            Button("刷新") { load(reset: true) }.disabled(store.busy)
        }
        .sheet(isPresented: $composing) { CollaborationComposer(api: api, repo: repo, number: nil) { load(reset: true) } }
        .onChange(of: state) { _ in load(reset: true) }
        .task { if !store.loaded { load() } }
        .onDisappear { store.cancel() }
    }
    private func load(reset: Bool = false) {
        let requested = state
        store.load(reset: reset, api: api) { try await api.collaborationItems(repo, kind: kind, state: requested, page: $0) }
    }
}

struct CommunityPageFooter<Item: Identifiable>: View where Item.ID: Hashable {
    @ObservedObject var store: CommunityPageStore<Item>
    let next: () -> Void
    var body: some View {
        Section {
            SoftGroupRows {
            if store.busy { SoftGroupRow("loading") { ProgressView("加载中…") } }
            if !store.error.isEmpty { SoftGroupRow("error") { Text(store.error).font(.caption).textSelection(.enabled) } }
            if store.more { SoftGroupRow("next") { Button(store.error.isEmpty ? "加载更多" : "重试") { next() }.disabled(store.busy) } }
            if store.limited { SoftGroupRow("limited") { Text("已显示前 300 条。").font(.caption).foregroundStyle(.secondary) } }
            }
        }
    }
}

struct CollaborationDetailView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let kind: CollaborationKind
    let number: Int
    @State private var item: CollaborationItem?
    @State private var error = ""
    @State private var busy = false
    @State private var revision = 0
    @State private var composing = false
    @State private var mutation: CommunityMutation?
    @State private var mutationTitle = ""
    @State private var mayManage = false
    var body: some View {
        List {
            if let item {
                Section {
                    SoftGroupRows {
                    SoftGroupRow("title") { Text(item.title).font(.title3.bold()).textSelection(.enabled) }
                    SoftGroupRow("state") { Text("#\(number) · \(item.merged == true ? "已合并" : item.state) · \(item.user?.login ?? "未知作者")").font(.caption) }
                    if let labels = item.labels, !labels.isEmpty { SoftGroupRow("labels") { Text(labels.map { $0.name }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) } }
                    if let head = item.head, let base = item.base { SoftGroupRow("branches") { Text(head.ref + " → " + base.ref).font(.caption).textSelection(.enabled) } }
                    if let count = item.changed_files { SoftGroupRow("stats") { Text("\(count) 个文件 · +\(item.additions ?? 0) / −\(item.deletions ?? 0)").font(.caption) } }
                    }
                }
                Section("正文") { CommunityMarkdown(text: item.body ?? "暂无正文", baseURL: CommunityRules.webURL(item.html_url), api: api).softGroupedRow(top: true, bottom: true) }
                Section {
                    SoftGroupRows {
                    SoftGroupRow("comments") { NavigationLink("讨论评论") { DiscussionView(api: api, repo: repo, number: number, stream: .conversation) } }
                    if kind == .pulls {
                        SoftGroupRow("reviews") { NavigationLink("审查记录") { DiscussionView(api: api, repo: repo, number: number, stream: .reviews) } }
                        SoftGroupRow("inline") { NavigationLink("行内评论") { DiscussionView(api: api, repo: repo, number: number, stream: .inline) } }
                        SoftGroupRow("files") { NavigationLink("变更文件与差异") { PullFilesView(api: api, repo: repo, number: number) } }
                    }
                    SoftGroupRow("reply") { Button("回复评论") { composing = true }.disabled(busy) }
                    if item.merged != true && (mayManage || item.user?.login.caseInsensitiveCompare(api.login) == .orderedSame) {
                        SoftGroupRow("change-state") { Button(item.state == "open" ? "关闭" : "重新打开") {
                            mutationTitle = item.state == "open" ? "确认关闭？" : "确认重新打开？"
                            mutation = .state(number, item.state == "open" ? "closed" : "open")
                        }.disabled(busy) }
                    }
                    if kind == .pulls, mayManage, item.state == "open", item.draft != true, let sha = item.head?.sha {
                        SoftGroupRow("merge") { Button("合并 PR") { mutationTitle = "确认合并当前 PR？"; mutation = .merge(number, sha) }.disabled(busy) }
                    }
                    }
                }
            }
            Section { SoftGroupRows {
            if busy { SoftGroupRow("loading") { ProgressView("处理中…") } }
            if !error.isEmpty { SoftGroupRow("error") { Text(error) }; SoftGroupRow("retry") { Button("刷新详情") { revision += 1 } } }
            } }
        }.navigationTitle("\(kind.title) #\(number)").adaptiveWorkspaceLayout()
        .toolbar { Button("刷新") { revision += 1 }.disabled(busy) }
        .task(id: revision) { await load() }
        .sheet(isPresented: $composing) { CollaborationComposer(api: api, repo: repo, number: number) { revision += 1 } }
        .confirmationDialog(mutationTitle, isPresented: Binding(get: { mutation != nil }, set: { if !$0 { mutation = nil } }), titleVisibility: .visible) {
            Button("确认操作") { if let action = mutation { mutation = nil; Task { await perform(action) } } }
            Button("取消", role: .cancel) { mutation = nil }
        } message: { Text(repo + " #\(number)。操作会提交到 GitHub；合并会核对当前 PR 提交。") }
    }
    private func load() async {
        busy = true; error = ""; defer { busy = false }
        do {
            let value = try await api.collaborationDetail(repo, kind: kind, number: number)
            try Task.checkCancellation(); guard api.isCurrentSession else { return }; item = value
            let access = try? await api.repository(repo)
            try Task.checkCancellation(); guard api.isCurrentSession else { return }; mayManage = access?.permissions?.push == true
        } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription } }
    }
    private func perform(_ action: CommunityMutation) async {
        guard !busy else { return }; busy = true; error = ""; defer { busy = false }
        do {
            let bytes = try await api.communityMutate(repo, action: action)
            if case .merge = action {
                struct Result: Decodable { let merged: Bool; let message: String }
                let result = try JSONDecoder().decode(Result.self, from: bytes)
                guard result.merged else { throw AppError(text: result.message) }
            }
            try Task.checkCancellation(); guard api.isCurrentSession else { return }; revision += 1
        } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription } }
    }
}

struct DiscussionView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let number: Int
    let stream: DiscussionStream
    @StateObject private var store = CommunityPageStore<CollaborationComment>()
    var body: some View {
        List {
            ForEach(store.items) { comment in
                Section {
                    SoftGroupRows {
                    SoftGroupRow("user") { HStack { GitHubAvatar(url: comment.user?.avatar_url, size: 28); Text(comment.user?.login ?? "已删除用户").font(.headline) } }
                    if let state = comment.state { SoftGroupRow("state") { Text(state).font(.caption).foregroundStyle(.secondary) } }
                    if let date = comment.created_at { SoftGroupRow("date") { Text(ChinaDate.dateTime(date)).font(.caption2).foregroundStyle(.secondary) } }
                    if let path = comment.path { SoftGroupRow("path") { Text(path + (comment.line.map { ":\($0)" } ?? "")).font(.caption).textSelection(.enabled) } }
                    SoftGroupRow("body") { CommunityMarkdown(text: comment.body.flatMap { $0.isEmpty ? nil : $0 } ?? "无文字内容", baseURL: CommunityRules.webURL(comment.html_url) ?? CommunityRules.repositoryURL(repo), api: api) }
                    }
                }
            }
            if store.loaded && store.items.isEmpty { Text("暂无记录").softGroupedRow(top: true, bottom: true) }
            CommunityPageFooter(store: store, next: { load() })
        }.navigationTitle(stream.title).adaptiveWorkspaceLayout()
        .toolbar { Button("刷新") { load(reset: true) }.disabled(store.busy) }
        .task { if !store.loaded { load() } }.onDisappear { store.cancel() }
    }
    private func load(reset: Bool = false) {
        store.load(reset: reset, api: api) { try await api.collaborationComments(repo, number: number, stream: stream, page: $0) }
    }
}

struct PullFilesView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let number: Int
    @StateObject private var store = CommunityPageStore<DesktopCommit.File>()
    var body: some View {
        List {
            ForEach(store.items) { file in
                NavigationLink { CommitPatchDestination(file: file, pullRequest: true) } label: {
                    VStack(alignment: .leading) {
                        Text(file.filename)
                        Text("\(file.status) · +\(file.additions) / −\(file.deletions)").font(.caption).foregroundStyle(.secondary)
                        if let previous = file.previous_filename { Text("原路径：" + previous).font(.caption) }
                    }
                }.softGroupedRow(top: file.id == store.items.first?.id, bottom: file.id == store.items.last?.id)
            }
            if store.loaded && store.items.isEmpty { Text("暂无变更文件").softGroupedRow(top: true, bottom: true) }
            CommunityPageFooter(store: store, next: { load() })
            Section { Text("二进制或部分大文件没有文本 patch；不代表没有变化。").font(.caption).foregroundStyle(.secondary).softGroupedRow(top: true, bottom: true) }

        }.navigationTitle("PR 变更文件").adaptiveWorkspaceLayout()
        .task { if !store.loaded { load() } }.onDisappear { store.cancel() }
    }
    private func load() { store.load(api: api) { try await api.pullFiles(repo, number: number, page: $0) } }
}
