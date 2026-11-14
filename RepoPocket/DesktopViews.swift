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
            Section { Text(repo); Text("分支：" + branch) }.font(.caption)
            ForEach(commits) { c in
                NavigationLink { CommitDetailView(api: api, repo: repo, sha: c.sha) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(c.commit.message.components(separatedBy: "\n").first ?? c.sha)
                            .font(.system(size: messageSize, weight: .medium))
                            .lineLimit(2)
                        Text(String(c.sha.prefix(7)) + " · " + (c.commit.author?.name ?? "未知作者")).font(.caption).foregroundColor(.secondary)
                        if let date = c.commit.author?.date { Text(date).font(.caption2).foregroundColor(.secondary) }
                    }
                    .padding(.vertical, 7)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            if busy && commits.isEmpty { ProgressView() }
            if commits.isEmpty && !busy { Text("暂无提交，或加载失败；可下拉重试。") }
            if more { Button("加载更多提交") { Task { await load() } }.disabled(busy) }
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
                    Button(messageExpanded ? "收起说明" : "展开完整说明") { messageExpanded.toggle() }
                    Text(sha).font(.caption).textSelection(.enabled)
                    Text(d.commit.author?.name ?? "未知作者").softGroupedRow(bottom: d.stats == nil && d.commit.author?.date == nil)
                    if let date = d.commit.author?.date { Text(date).font(.caption).softGroupedRow(bottom: d.stats == nil) }
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
            if busy { ProgressView() }
            if more { Button(detail == nil ? "加载详情" : "加载更多文件") { Task { await load() } }.disabled(busy) }
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
    var body: some View {
        NavigationStack {
            Form {
                Section("切换远端浏览分支") {
                    Text("当前：" + current).font(.caption)
                    ForEach(branches) { b in
                        Button { select(b.name); dismiss() } label: {
                            HStack { Text(b.name); if b.name == current { Image(systemName: "checkmark") } }
                        }.disabled(busy)
                    }
                    if more { Button("加载更多分支") { Task { await load() } }.disabled(busy) }
                }
                if canWrite && api.isCurrentSession { Section("从当前分支创建") {
                    TextField("新分支名，例如 feature/mobile", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("来源：" + current + " @ " + String(head.prefix(7))).font(.caption)
                    Text("只创建新的远端引用，不覆盖已有分支；不切换本地工作区或上传队列的目标。").font(.caption)
                    Button("创建并切换") { confirm = true }.disabled(busy || head.isEmpty || !DesktopRules.validBranch(name))
                }
                }
                if busy { ProgressView() }
            }
            .navigationTitle("分支").adaptiveWorkspaceLayout()
            .toolbar { Button("关闭") { dismiss() }.disabled(busy) }
            .task { await load(); await captureHead() }
            .confirmationDialog("从 \(current) @ \(head.prefix(7)) 创建 \(name)？", isPresented: $confirm, titleVisibility: .visible) {
                Button("确认创建远端分支") { Task { await create() } }
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
}
