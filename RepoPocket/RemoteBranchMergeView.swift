import SwiftUI

struct RemoteBranchMergeView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let source: String
    @StateObject private var state = RemoteBranchMergeState()
    @State private var target = ""
    @State private var title = ""
    @State private var operation: Task<Void, Never>?
    @State private var showingConfirmation = false
    private var preview: RemoteBranchMergePreview? { state.preview?.target == target ? state.preview : nil }
    private var locked: Bool { state.busy || state.readOnly || !state.result.isEmpty || !api.isCurrentSession }

    var body: some View {
        List {
            Section("远端 PR · Squash") {
                SoftGroupRows {
                    SoftGroupRow("repository") { Text(repo).textSelection(.enabled) }
                    SoftGroupRow("source") { AppLabeledContent("来源分支", value: source) }
                    SoftGroupRow("target") {
                        NavigationLink {
                            LocalGitBranchPicker(api: api, repo: repo, current: target) { selected in
                                target = selected; state.dismissConfirmation()
                            }
                        } label: { AppLabeledContent("已有目标分支", value: target.isEmpty ? "请选择" : target) }
                        .disabled(locked).accessibilityIdentifier("branch-merge-target")
                    }
                    SoftGroupRow("title") { TextField("PR / Squash 提交标题", text: $title).disabled(locked).accessibilityIdentifier("branch-merge-title") }
                    SoftGroupRow("preview") {
                        Button("读取两端 SHA 与差异预览") {
                            run { await state.load(api: api, repo: repo, source: source, target: target) }
                        }.disabled(locked || target.isEmpty || target == source).accessibilityIdentifier("branch-merge-preview")
                    }
                    if target == source { SoftGroupRow("same") { Text("来源与目标不能相同。").foregroundStyle(.orange) } }
                    SoftGroupRow("notice") {
                        Text("这是远端 PR 合并，不操作本地工作树。仅支持 Squash；仓库必须关闭合并后自动删除分支。不主动启动 Actions，但仓库自身的 PR / push 工作流规则仍会生效；检查与审查必须符合 GitHub 规则，不绕过保护。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let preview {
                        SoftGroupRow("sha-heading") { Text("固定 SHA 预览").font(.subheadline).foregroundStyle(.secondary) }
                        SoftGroupRow("head") { Text("来源 \(preview.source)：\(preview.sourceSHA)").font(.caption.monospaced()).textSelection(.enabled) }
                        SoftGroupRow("base") { Text("目标 \(preview.target)：\(preview.targetSHA)").font(.caption.monospaced()).textSelection(.enabled) }
                        SoftGroupRow("limits") {
                            Text("提交最多 5,000 个，文件必须少于 300 个；单次网络响应最多 8 MiB。patch 可能缺失（二进制或 GitHub 省略）或被查看器截断，不代表完整内容。请逐项核实；超限列表不能用于合并。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        SoftGroupRow("commits-heading") { Text("提交（\(preview.commits.count)）").font(.subheadline).foregroundStyle(.secondary) }
                        for commit in preview.commits {
                            SoftGroupRow("commit:" + commit.sha) {
                                NavigationLink { CommitDetailView(api: api, repo: preview.repository, sha: commit.sha) } label: {
                                    VStack(alignment: .leading) {
                                        Text(commit.commit.message).lineLimit(2)
                                        Text(commit.sha).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        SoftGroupRow("files-heading") { Text("文件差异（\(preview.files.count)）").font(.subheadline).foregroundStyle(.secondary) }
                        for file in preview.files {
                            SoftGroupRow("file:" + file.id) {
                                NavigationLink { CommitPatchDestination(file: file, pullRequest: true) } label: {
                                    VStack(alignment: .leading) {
                                        Text(file.filename)
                                        Text("\(file.status) · +\(file.additions) −\(file.deletions)" + (file.patch == nil ? " · 无文本 patch" : ""))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        SoftGroupRow("actions-heading") { Text("明确操作").font(.subheadline).foregroundStyle(.secondary) }
                        if let pull = state.pull {
                            SoftGroupRow("pull") { Text("PR #\(pull.number)：\(preview.source) → \(preview.target)") }
                            SoftGroupRow("gate") {
                                Button("刷新合并门禁并准备确认…") {
                                    run {
                                        await state.refreshGate(api: api, title: title)
                                        showingConfirmation = state.confirmation != nil
                                    }
                                }.disabled(locked || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("branch-merge-refresh")
                            }
                        } else {
                            SoftGroupRow("create") {
                                Button("已核对预览，创建或复用 PR") { run { await state.preparePull(api: api, title: title) } }
                                    .disabled(locked || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("branch-merge-open-pr")
                            }
                        }
                        if let checks = state.checks { SoftGroupRow("checks") { Text(checks.summary).font(.footnote) } }
                        SoftGroupRow("race") {
                            Text("写入前会重新读取两端 SHA。GitHub REST 只能原子校验来源 SHA，不能锁定目标 SHA；目标仍可能在最终读取后前进。以服务器合并结果及保护规则为准，不承诺原子固定目标。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if state.readOnly {
                            SoftGroupRow("reconcile") { Button("只读核实 PR（不重发写入）") { run { await state.reconcile(api: api) } }.disabled(state.busy || !api.isCurrentSession) }
                        }
                    }
                    if state.busy { SoftGroupRow("busy") { ProgressView("读取并校验 GitHub 状态…") } }
                    if !state.failure.isEmpty {
                        SoftGroupRow("failure-heading") { Text("未完成").font(.subheadline).foregroundStyle(.secondary) }
                        SoftGroupRow("failure") { Text(state.failure).textSelection(.enabled) }
                    }
                    if !state.result.isEmpty {
                        SoftGroupRow("result-heading") { Text("结果 / 核实").font(.subheadline).foregroundStyle(.secondary) }
                        SoftGroupRow("result") { Text(state.result).accessibilityIdentifier("branch-merge-result").textSelection(.enabled) }
                    }
                }
            }
        }
        .navigationTitle("远端 PR 压缩合并")
        .adaptiveWorkspaceLayout()
        .confirmationDialog("确认远端 Squash 合并？", isPresented: $showingConfirmation, titleVisibility: .visible) {
            if let frozen = state.confirmation {
                Button("确认压缩合并", role: .destructive) { run { await state.submit(api: api, confirmation: frozen) } }.accessibilityIdentifier("branch-merge-confirm")
                Button("取消", role: .cancel) { state.dismissConfirmation() }
            }
        } message: {
            if let frozen = state.confirmation {
                Text("\(frozen.preview.repository)\n\(frozen.preview.source) → \(frozen.preview.target)\n来源：\(frozen.preview.sourceSHA)\n目标：\(frozen.preview.targetSHA)\n提交标题：\(frozen.title)\n将再次刷新门禁；保留来源分支。")
            }
        }
        .onChange(of: title) { _ in state.dismissConfirmation(); showingConfirmation = false }
        .onDisappear { operation?.cancel(); state.invalidate() }
    }
    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard !state.busy else { return }
        operation = Task { await action() }
    }
}
