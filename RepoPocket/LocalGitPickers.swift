import SwiftUI

struct LocalProjectRemoteView: View {
    @ObservedObject var api: GitHub
    let project: LocalGitProject
    let metadata: URL
    let internalRoot: URL
    let status: LocalGitStatus
    let generation: UUID
    let isValid: () -> Bool
    let saved: () -> Void
    @State private var remote = ""
    @State private var confirming = false
    @State private var busy = false
    @State private var failure = ""
    @State private var task: Task<Void, Never>?
    private var target: String? { try? LocalGitRules.remote(remote) }

    var body: some View {
        Form {
            Section {
                SoftGroupRows {
                    SoftGroupRow("account") { LabeledContent("账号", value: api.login) }
                    SoftGroupRow("repository") {
                        NavigationLink("选择 GitHub 仓库") {
                            LocalGitRepositoryPicker(api: api) { remote = $0.full_name }
                        }
                    }
                    SoftGroupRow("address") {
                        TextField("owner/repository 或 GitHub HTTPS 地址", text: $remote)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    SoftGroupRow("branch") { LabeledContent("关联同名远端分支", value: status.branch) }
                    SoftGroupRow("help") {
                        Text("只添加 origin 和当前分支的跟踪配置，不修改文件、提交历史，也不会自动拉取或推送。远端历史不一致时仍会停止同步。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    SoftGroupRow("save") {
                        Button("确认关联…") { confirming = true }.disabled(target == nil || !isValid())
                    }
                }
            }.disabled(busy)
            if busy { ProgressView("保存关联…").softGroupedRow(top: true, bottom: true) }
            if !failure.isEmpty { Text(failure).font(.caption).foregroundStyle(.red).softGroupedRow(top: true, bottom: true) }
        }.navigationTitle("关联远端仓库").adaptiveWorkspaceLayout()
        .confirmationDialog("关联此 GitHub 仓库？", isPresented: $confirming, titleVisibility: .visible) {
            Button("确认关联") { save() }
            Button("取消", role: .cancel) {}
        } message: { Text("账号：\(api.login)\n\(target ?? "")\n分支：\(status.branch)\n不会推送任何文件。") }
        .onDisappear { task?.cancel() }
    }

    private func save() {
        guard !busy, isValid(), generation == AccountStore.generation, api.isCurrentSession, let target else { return }
        busy = true; failure = ""
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let _: LocalGitReply = try await LocalGitEngine.shared.run("configureRemote", project: project, metadata: metadata,
                    internalRoot: internalRoot, arguments: ["remote": target, "expectedHead": status.head, "expectedRef": status.reference], generation: generation)
                try Task.checkCancellation()
                guard isValid(), api.isCurrentSession, generation == AccountStore.generation else { return }
                saved()
            } catch { if !RefreshFailure.isCancellation(error) { failure = error.localizedDescription } }
        }
    }
}

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
        let matches = visible
        return List {
            Section("当前账号可访问的仓库") {
                SoftGroupRows {
                    for repository in matches {
                        SoftGroupRow("repository:" + String(repository.id)) {
                            Button { select(repository); dismiss() } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(repository.full_name, systemImage: repository.private == true ? "lock" : "folder")
                                    if let branch = repository.default_branch { Text("默认分支：" + branch).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    if matches.isEmpty && !busy && failure.isEmpty {
                        SoftGroupRow("empty") { Text(query.isEmpty ? "暂无可访问仓库" : "没有匹配的仓库") }
                    }
                }
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
                        SoftGroupRow("branch:" + branch.id) {
                            Button { select(branch.name); dismiss() } label: {
                                HStack { Text(branch.name); Spacer(); if branch.name == current { Image(systemName: "checkmark") } }
                            }.accessibilityIdentifier("remote-branch-choice-" + branch.name)
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
