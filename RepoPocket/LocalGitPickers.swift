import SwiftUI

struct LocalGitRepositoryPicker: View {
    @ObservedObject var api: GitHub
    let select: (Repository) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repositories: [Repository] = []
    @State private var query = ""
    @State private var attempted = false
    @State private var busy = false
    @State private var failure = ""
    private var visible: [Repository] {
        query.isEmpty ? repositories : repositories.filter { $0.full_name.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        List {
            Section("当前账号可访问的仓库") {
                ForEach(visible) { repository in
                    Button { select(repository); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(repository.full_name, systemImage: repository.private == true ? "lock" : "folder")
                            if let branch = repository.default_branch { Text("默认分支：" + branch).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.softGroupedRow(top: repository.id == visible.first?.id, bottom: repository.id == visible.last?.id)
                }
                if visible.isEmpty && !busy && failure.isEmpty { Text(query.isEmpty ? "暂无可访问仓库" : "没有匹配的仓库").softGroupedRow(top: true, bottom: true) }
            }
            if busy { ProgressView("正在读取仓库…").softGroupedRow(top: true, bottom: true) }
            if !failure.isEmpty { Section { Text(failure).font(.caption).softGroupedRow(top: true); Button("重试") { Task { await load() } }.softGroupedRow(bottom: true) } }
        }.navigationTitle("选择仓库").adaptiveWorkspaceLayout().searchable(text: $query, prompt: "仓库名称")
        .task { guard !attempted else { return }; attempted = true; await load() }
        .refreshable { await load() }
    }
    private func load() async {
        guard !busy, api.isCurrentSession else { return }
        if repositories.isEmpty, let cached = api.cachedCollection(.owned) { repositories = cached }
        busy = true; failure = ""; defer { busy = false }
        do {
            let list = try await api.repositories(); try Task.checkCancellation()
            guard api.isCurrentSession else { return }; repositories = list
        } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { failure = error.localizedDescription } }
    }
}

struct LocalGitBranchPicker: View {
    @ObservedObject var api: GitHub
    let repo: String
    let current: String
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var branches: [DesktopBranch] = []
    @State private var page = 1
    @State private var more = true
    @State private var busy = false
    @State private var attempted = false
    @State private var failure = ""
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    for branch in branches {
                        SoftGroupRow(branch.id) {
                            Button { select(branch.name); dismiss() } label: {
                                HStack { Text(branch.name); Spacer(); if branch.name == current { Image(systemName: "checkmark") } }
                            }
                        }
                    }
                    if busy { SoftGroupRow("loading") { ProgressView("读取分支…") } }
                    if !failure.isEmpty { SoftGroupRow("failure") { Text(failure).font(.caption) } }
                    if more { SoftGroupRow("more") { Button(failure.isEmpty ? "加载更多分支" : "重试") { Task { await load() } }.disabled(busy) } }
                }
            }
        }.navigationTitle("选择分支").adaptiveWorkspaceLayout()
        .task { guard !attempted else { return }; attempted = true; await load() }
    }
    private func load() async {
        guard !busy, api.isCurrentSession else { return }
        busy = true; failure = ""; defer { busy = false }
        do {
            let batch = try await api.branches(repo, page: page); try Task.checkCancellation()
            guard api.isCurrentSession else { return }
            let ids = Set(branches.map(\.id)); branches += batch.filter { !ids.contains($0.id) }
            more = batch.count == 100 && page < 30; page += 1
        } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { failure = error.localizedDescription } }
    }
}
