import SwiftUI

struct HistoryView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let branch: String
    @State private var commits: [DesktopCommit] = []
    @State private var page = 1
    @State private var more = true
    @State private var busy = false
    @State private var canManageHistory = false
    @State private var showingHistoryCleanup = false
    @ScaledMetric(relativeTo: .body) private var messageSize: CGFloat = 16
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    SoftGroupRow("repository") { Text(repo).font(.caption) }
                    SoftGroupRow("branch") { Text("分支：" + branch).font(.caption) }
                    for c in commits {
                        SoftGroupRow("commit-" + c.sha) {
                            NavigationLink { CommitDetailView(api: api, repo: repo, sha: c.sha) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(c.commit.message.components(separatedBy: "\n").first ?? c.sha)
                                        .font(.system(size: messageSize, weight: .medium))
                                        .lineLimit(2)
                                    Text((c.commit.author?.name ?? "未知作者") + " · " + String(c.sha.prefix(7))).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                    if let date = c.commit.author?.date { Text(CommitDatePresentation.local(date)).font(.caption2).foregroundColor(.secondary) }
                                }
                                .padding(.vertical, 7)
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                    if busy && commits.isEmpty { SoftGroupRow("loading") { ProgressView() } }
                    if commits.isEmpty && !busy { SoftGroupRow("empty") { Text("暂无提交，或加载失败；可下拉重试。") } }
                    if more { SoftGroupRow("more") { Button("加载更多提交") { Task { await load() } }.disabled(busy) } }
                }
            }
        }
        .navigationTitle("提交历史")
        .adaptiveWorkspaceLayout()
        .task {
            if commits.isEmpty { await load() }
            let access = try? await api.repository(repo)
            guard !Task.isCancelled, api.isCurrentSession else { return }
            canManageHistory = access?.permissions?.push == true
        }
        .toolbar {
            NativeActionMenu(title: "提交历史操作", items: [
                NativeMenuItem(id: "organize", title: "整理已推送提交历史", symbol: "list.bullet", enabled: canManageHistory && !busy) { showingHistoryCleanup = true }
            ])
        }
        .sheet(isPresented: $showingHistoryCleanup) { AppNavigationStack { RemoteHistoryView(api: api, repo: repo, branch: branch).toolbar { Button("关闭") { showingHistoryCleanup = false } } }.appSheetCornerRadius() }
        .onReceive(NotificationCenter.default.publisher(for: .repositoryHistoryChanged)) { notice in
            if notice.userInfo?["repo"] as? String == repo, notice.userInfo?["account"] as? String == api.accountID,
               notice.userInfo?["generation"] as? UUID == AccountStore.generation { Task { await load(refresh: true) } }
        }
        .refreshable { await load(refresh: true) }
    }
    private func load(refresh: Bool = false) async {
        guard !busy else { return }
        let generation = AccountStore.generation
        let requestedPage = refresh ? 1 : page
        busy = true; defer { busy = false }
        do {
            let batch = try await api.history(repo, branch: branch, page: requestedPage)
            try Task.checkCancellation()
            guard generation == AccountStore.generation else { return }
            let ids = Set(commits.map { $0.sha })
            if refresh { commits = batch } else { commits += batch.filter { !ids.contains($0.sha) } }
            more = batch.count == 30; page = requestedPage; page += 1
        } catch { if !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
}

struct CommitDetailView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let sha: String
    @State private var detail: DesktopCommit?
    @State private var files: [DesktopCommit.File] = []
    @State private var page = 1
    @State private var more = true
    @State private var busy = false
    @ScaledMetric(relativeTo: .body) private var messageSize: CGFloat = 16
    @State private var messageExpanded = false
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    if let d = detail {
                        SoftGroupRow("commit-title") { Text("提交").font(.caption).foregroundStyle(.secondary) }
                        SoftGroupRow("message") {
                            Text(d.commit.message)
                                .font(.system(size: messageSize, weight: .regular))
                                .lineLimit(messageExpanded ? nil : 4)
                                .textSelection(.enabled)
                                .padding(.vertical, 6)
                        }
                        SoftGroupRow("message-toggle") { Button(messageExpanded ? "收起说明" : "展开完整说明") { messageExpanded.toggle() } }
                        SoftGroupRow("sha") { Text(sha).font(.caption).textSelection(.enabled) }
                        SoftGroupRow("author") { Text(d.commit.author?.name ?? "未知作者") }
                        if let date = d.commit.author?.date { SoftGroupRow("date") { Text(CommitDatePresentation.local(date)).font(.caption) } }
                        if let s = d.stats { SoftGroupRow("stats") { Text("总计 +\(s.additions) / −\(s.deletions)") } }
                        SoftGroupRow("files-title") { Text("变更文件").font(.caption).foregroundStyle(.secondary) }
                        for f in files {
                            SoftGroupRow("file-" + f.id) {
                                NavigationLink {
                                    CommitPatchDestination(file: f)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(f.filename)
                                        Text("\(f.status) · +\(f.additions) / −\(f.deletions)").font(.caption)
                                        if let old = f.previous_filename { Text("原路径：" + old).font(.caption) }
                                    }
                                }
                            }
                        }
                        SoftGroupRow("patch-note") { Text("Patch 由 GitHub 提供；二进制及部分大文件不可预览，不代表无变化。GitHub 最多返回 3,000 个文件。").font(.caption).foregroundColor(.secondary) }
                    }
                    if busy { SoftGroupRow("loading") { ProgressView() } }
                    if more { SoftGroupRow("more") { Button(detail == nil ? "加载详情" : "加载更多文件") { Task { await load() } }.disabled(busy) } }
                }
            }
        }.listStyle(.insetGrouped).navigationTitle("提交详情").adaptiveWorkspaceLayout()
        .task { if detail == nil { await load() } }
    }
    private func load() async {
        busy = true; defer { busy = false }
        do {
            let d = try await api.commitDetail(repo, sha: sha, page: page); detail = d
            let batch = d.files ?? []; let ids = Set(files.map { $0.id })
            files += batch.filter { !ids.contains($0.id) }; more = batch.count == 100 && page < 30; page += 1
        } catch { if !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
}

struct BranchPickerView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let current: String
    var canWrite: Bool = false
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var branches: [DesktopBranch] = []
    @State private var page = 1
    @State private var more = true
    @State private var busy = false
    @State private var name = ""
    @State private var head = ""
    @State private var confirm = false
    @State private var defaultBranch = ""
    @State private var deleting: DesktopBranch?
    @State private var deletion: Task<Void, Never>?
    @State private var deletionMessage = ""
    @State private var renaming: DesktopBranch?
    @State private var merging: DesktopBranch?
    @State private var renameName = ""
    var body: some View {
        AppNavigationStack {
            Form {
                Section {
                    switcherSection
                    createSection
                    if !deletionMessage.isEmpty {
                        Text(deletionMessage).font(.footnote).textSelection(.enabled).softGroupedRow(bottom: !busy)
                    }
                    if busy { ProgressView().softGroupedRow(bottom: true) }
                }
            }
            .navigationTitle("分支").adaptiveWorkspaceLayout()
            .toolbar { Button("关闭") { dismiss() }.disabled(busy) }
            .task { await load(); await captureHead(); await captureDefaultBranch() }
            .onDisappear { deletion?.cancel() }
            .sheet(item: $merging) { source in
                AppNavigationStack {
                    RemoteBranchMergeView(api: api, repo: repo, source: source.name)
                }.appSheetCornerRadius()
            }
            .confirmationDialog("从 \(current) @ \(head.prefix(7)) 创建 \(name)？", isPresented: $confirm, titleVisibility: .visible) {
                Button("确认创建远端分支") { Task { await create() } }
            }
            .appTextInputAlert("重命名 GitHub 远端分支",
                message: repo + "\n" + (renaming?.name ?? "") + " → 新名称\n会在 GitHub 上新建同名分支并删除旧分支，提交不会丢失；默认分支、受保护分支会拒绝。打开中的 Pull Request 可能被关闭，本地 Git 跟踪不会自动改名。",
                isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                text: $renameName, placeholder: "新分支名称", confirmTitle: "重命名") { [renaming] in
                guard let target = renaming else { return }
                let name = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
                self.renaming = nil
                guard DesktopRules.validBranch(name), name != target.name else {
                    deletionMessage = "新分支名无效或与原名称相同，未做修改。"; return
                }
                deletion = Task { await rename(target, to: name) }
            }
            .confirmationDialog("删除 GitHub 远端分支？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { target in
                Button("删除远端分支", role: .destructive) { deletion = Task { await remove(target) } }
                Button("取消", role: .cancel) { deleting = nil }
            } message: { target in
                Text(repo + "\n" + target.name + " @ " + String((target.commit?.sha ?? "").prefix(7)) + "\n这会删除 GitHub 上的分支，不是本地跟踪记录。请先确认该分支的提交已保留或合并；本地文件不会删除。")
            }
        }
    }
    private var switcherSection: some View {
        SoftGroupRows(bottom: !(canWrite && api.isCurrentSession) && deletionMessage.isEmpty && !busy) {
            SoftGroupRow("switcher-title") { Text("切换远端浏览分支").font(.caption).foregroundStyle(.secondary) }
            SoftGroupRow("current") { Text("当前：" + current).font(.caption) }
            for b in branches {
              SoftGroupRow("branch-" + b.name) {
                Button { select(b.name); dismiss() } label: {
                    HStack { Text(b.name); if b.name == current { Image(systemName: "checkmark") } }
                }.disabled(busy)
                .accessibilityIdentifier("remote-branch-" + b.name)
                .contextMenu {
                    if canWrite && api.isCurrentSession {
                        Button("合并到其他分支…") { merging = b }
                            .disabled(busy || b.commit?.sha.isEmpty != false)
                            .accessibilityIdentifier("remote-branch-merge-" + b.name)
                        Button { renameName = b.name + "-new"; renaming = b } label: { Label("重命名 GitHub 远端分支", systemImage: "pencil") }
                            .disabled(busy || b.protected == true || (b.commit?.sha ?? "").isEmpty)
                        Button(role: .destructive) { deletionMessage = ""; deleting = b } label: { Label("删除 GitHub 远端分支", systemImage: "trash") }
                            .disabled(!canDelete(b))
                    }
                }
              }
            }
            if more { SoftGroupRow("more") { Button("加载更多分支") { Task { await load() } }.disabled(busy) } }
        }
    }
    @ViewBuilder private var createSection: some View {
        if canWrite && api.isCurrentSession {
            SoftGroupRows(top: false, bottom: deletionMessage.isEmpty && !busy) {
                SoftGroupRow("create-title") { Text("从当前分支创建").font(.caption).foregroundStyle(.secondary) }
                SoftGroupRow("name") { TextField("新分支名，例如 feature/mobile", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled() }
                SoftGroupRow("source") { Text("来源：" + current + " @ " + String(head.prefix(7))).font(.caption) }
                SoftGroupRow("help") { Text("只创建新的远端引用，不覆盖已有分支；不切换本地工作区或上传队列的目标。").font(.caption) }
                SoftGroupRow("create") { Button("创建并切换") { confirm = true }.disabled(busy || head.isEmpty || !DesktopRules.validBranch(name)) }
            }
        }
    }
    private func load() async {
        busy = true; defer { busy = false }
        do {
            let batch = try await api.branches(repo, page: page); let ids = Set(branches.map { $0.name })
            branches += batch.filter { !ids.contains($0.name) }; more = batch.count == 100; page += 1
        } catch { if !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
    private func captureHead() async {
        busy = true; defer { busy = false }
        do { head = try await api.workspaceHead(repo, branch: current) }
        catch { if !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
    private func create() async {
        busy = true; defer { busy = false }
        do {
            try await api.createBranch(repo, name: name, from: current, expectedHead: head)
            select(name); dismiss(); api.message = "已创建远端分支：" + name
        } catch { if !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription }; await captureHead() }
    }
    private func canDelete(_ b: DesktopBranch) -> Bool {
        canWrite && api.isCurrentSession && !busy && b.name != current && !defaultBranch.isEmpty &&
            b.name != defaultBranch && b.protected == false && b.commit?.sha.isEmpty == false
    }
    private func captureDefaultBranch() async {
        guard canWrite else { return }
        busy = true; defer { busy = false }
        do {
            let info = try await api.repository(repo)
            guard api.isCurrentSession else { return }
            defaultBranch = info.default_branch ?? ""
        } catch { if api.isCurrentSession && !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
    private func rename(_ target: DesktopBranch, to newName: String) async {
        guard canWrite, api.isCurrentSession, let expectedHead = target.commit?.sha, !busy else {
            deletionMessage = "分支状态或账号已变化，请重新打开分支列表后确认。"; return
        }
        busy = true; deletionMessage = ""
        defer { busy = false }
        do {
            try await api.renameBranch(repo, name: target.name, to: newName, expectedHead: expectedHead, current: current)
            guard api.isCurrentSession else { return }
            if current == target.name { select(newName); dismiss(); return }
            if let index = branches.firstIndex(where: { $0.name == target.name }) {
                branches[index] = DesktopBranch(name: newName, commit: target.commit, protected: target.protected)
            }
            deletionMessage = "已重命名 GitHub 远端分支：" + target.name + " → " + newName
        } catch { if api.isCurrentSession && !RefreshFailure.isCancellation(error) { deletionMessage = error.localizedDescription } }
    }
    private func remove(_ target: DesktopBranch) async {
        guard canDelete(target), let expectedHead = target.commit?.sha else {
            deletionMessage = "分支状态或账号已变化，请重新打开分支列表后确认。"; return
        }
        deleting = nil; deletionMessage = ""; busy = true; defer { busy = false }
        do {
            try await api.deleteBranch(repo, name: target.name, expectedHead: expectedHead, current: current)
            guard api.isCurrentSession else { return }
            branches.removeAll { $0.name == target.name }
            deletionMessage = "已删除 GitHub 远端分支：" + repo + " / " + target.name
        } catch { if api.isCurrentSession && !RefreshFailure.isCancellation(error) { deletionMessage = error.localizedDescription } }
    }
}
