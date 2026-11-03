import SwiftUI

struct HistoryView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let branch: String
    @State private var commits: [DesktopCommit] = []
    @State private var page = 1
    @State private var more = true
    @State private var busy = false
    @ScaledMetric(relativeTo: .body) private var messageSize: CGFloat = 16
    var body: some View {
        List {
            Section { Text(repo).softGroupedRow(top: true); Text("分支：" + branch).softGroupedRow(bottom: true) }.font(.caption)
            ForEach(commits) { c in
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
                }.softGroupedRow(top: c.id == commits.first?.id, bottom: c.id == commits.last?.id && !more)
            }
            if busy && commits.isEmpty { ProgressView().softGroupedRow(top: true, bottom: !more) }
            if commits.isEmpty && !busy { Text("暂无提交，或加载失败；可下拉重试。").softGroupedRow(top: true, bottom: !more) }
            if more { Button("加载更多提交") { Task { await load() } }.disabled(busy).softGroupedRow(top: false, bottom: true) }
        }
        .navigationTitle("提交历史")
        .adaptiveWorkspaceLayout()
        .task { if commits.isEmpty { await load() } }
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
            if let d = detail {
                Section("提交") {
                    Text(d.commit.message)
                        .font(.system(size: messageSize, weight: .regular))
                        .lineLimit(messageExpanded ? nil : 4)
                        .textSelection(.enabled)
                        .padding(.vertical, 6).softGroupedRow(top: true)
                    Button(messageExpanded ? "收起说明" : "展开完整说明") { messageExpanded.toggle() }.softGroupedRow()
                    Text(sha).font(.caption).textSelection(.enabled).softGroupedRow()
                    Text(d.commit.author?.name ?? "未知作者").softGroupedRow(bottom: d.stats == nil && d.commit.author?.date == nil)
                    if let date = d.commit.author?.date { Text(CommitDatePresentation.local(date)).font(.caption).softGroupedRow(bottom: d.stats == nil) }
                    if let s = d.stats { Text("总计 +\(s.additions) / −\(s.deletions)").softGroupedRow(bottom: true) }
                }
                Section("变更文件") {
                    ForEach(files) { f in
                        NavigationLink {
                            CommitPatchDestination(file: f)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(f.filename)
                                Text("\(f.status) · +\(f.additions) / −\(f.deletions)").font(.caption)
                                if let old = f.previous_filename { Text("原路径：" + old).font(.caption) }
                            }
                        }.softGroupedRow(top: f.id == files.first?.id)
                    }
                    Text("Patch 由 GitHub 提供；二进制及部分大文件不可预览，不代表无变化。GitHub 最多返回 3,000 个文件。").font(.caption).foregroundColor(.secondary).softGroupedRow(top: files.isEmpty, bottom: true)
                }
            }
            Section {
                if busy { ProgressView().softGroupedRow(top: true, bottom: !more) }
                if more { Button(detail == nil ? "加载详情" : "加载更多文件") { Task { await load() } }.disabled(busy).softGroupedRow(top: !busy, bottom: true) }
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
    @State private var renameName = ""
    var body: some View {
        NavigationStack {
            Form {
                switcherSection
                createSection
                if !deletionMessage.isEmpty {
                    Section { SoftGroupRows { SoftGroupRow("deletion-result") { Text(deletionMessage).font(.footnote).textSelection(.enabled) } } }
                }
                if busy { Section { ProgressView().softGroupedRow(top: true, bottom: true) } }
            }
            .navigationTitle("分支").adaptiveWorkspaceLayout()
            .toolbar { Button("关闭") { dismiss() }.disabled(busy) }
            .task { await load(); await captureHead(); await captureDefaultBranch() }
            .onDisappear { deletion?.cancel() }
            .confirmationDialog("从 \(current) @ \(head.prefix(7)) 创建 \(name)？", isPresented: $confirm, titleVisibility: .visible) {
                Button("确认创建远端分支") { Task { await create() } }
            }
            .alert("重命名 GitHub 远端分支", isPresented: Binding(
                get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { target in
                TextField("新分支名称", text: $renameName).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("取消", role: .cancel) { renaming = nil }
                Button("重命名") {
                    let name = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
                    renaming = nil
                    guard DesktopRules.validBranch(name), name != target.name else {
                        deletionMessage = "新分支名无效或与原名称相同，未做修改。"; return
                    }
                    deletion = Task { await rename(target, to: name) }
                }
            } message: { target in
                Text(repo + "\n" + target.name + " → 新名称\n会在 GitHub 上新建同名分支并删除旧分支，提交不会丢失；默认分支、受保护分支会拒绝。打开中的 Pull Request 可能被关闭，本地 Git 跟踪不会自动改名。")
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
        Section("切换远端浏览分支") {
            Text("当前：" + current).font(.caption).softGroupedRow(top: true, bottom: branches.isEmpty && !more)
            ForEach(branches) { b in
                Button { select(b.name); dismiss() } label: {
                    HStack { Text(b.name); if b.name == current { Image(systemName: "checkmark") } }
                }.disabled(busy)
                .contextMenu {
                    if canWrite && api.isCurrentSession {
                        Button { renameName = b.name + "-new"; renaming = b } label: { Label("重命名 GitHub 远端分支", systemImage: "pencil") }
                            .disabled(busy || b.protected == true || (b.commit?.sha ?? "").isEmpty)
                        Button(role: .destructive) { deletionMessage = ""; deleting = b } label: { Label("删除 GitHub 远端分支", systemImage: "trash") }
                            .disabled(!canDelete(b))
                    }
                }
                .softGroupedRow(bottom: b.id == branches.last?.id && !more)
            }
            if more { Button("加载更多分支") { Task { await load() } }.disabled(busy).softGroupedRow(bottom: true) }
        }
    }
    @ViewBuilder private var createSection: some View {
        if canWrite && api.isCurrentSession {
            Section("从当前分支创建") {
                TextField("新分支名，例如 feature/mobile", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow(top: true)
                Text("来源：" + current + " @ " + String(head.prefix(7))).font(.caption).softGroupedRow()
                Text("只创建新的远端引用，不覆盖已有分支；不切换本地工作区或上传队列的目标。").font(.caption).softGroupedRow()
                Button("创建并切换") { confirm = true }.disabled(busy || head.isEmpty || !DesktopRules.validBranch(name)).softGroupedRow(bottom: true)
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
