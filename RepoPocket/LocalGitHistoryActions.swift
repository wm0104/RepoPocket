import SwiftUI

struct LocalGitHistoryContext {
    let api: GitHub
    let status: LocalGitStatus
    let remote: String
    let generation: UUID
    let isValid: () -> Bool
    let changed: () -> Void
}
struct LocalGitHistoryPreview: Decodable {
    let head: String
    let reference: String
    let tree: String
    let upstream: String
    let commits: [String]
    let files: [DesktopCommit.File]
    let truncated: Bool
    var recoveryRef: String? = nil
}

struct LocalGitHistoryActions: View {
    let project: LocalGitProject
    let metadata: URL
    let internalRoot: URL
    let detail: LocalGitCommitDetail
    let context: LocalGitHistoryContext
    @State private var kind = "revert"
    @State private var count = 2
    @State private var message = ""
    @AppStorage("localGit.authorName") private var authorName = ""
    @AppStorage("localGit.authorEmail") private var authorEmail = ""
    @State private var preview: LocalGitHistoryPreview?
    @State private var error = ""
    @State private var result = ""
    @State private var busy = false
    @State private var confirming = false
    @State private var visible = false
    @State private var task: Task<Void, Never>?
    private var valid: Bool { visible && context.generation == AccountStore.generation && context.api.isCurrentSession && context.isValid() }
    private var top: Bool { detail.sha == context.status.head }
    private var ready: Bool {
        valid && !busy && result.isEmpty && (!detail.merge || kind != "revert") &&
        (kind == "revert" || top) && context.status.canCommit && context.status.files.isEmpty
    }
    private var explanation: String {
        switch kind {
        case "removeKeep": return "仅移除当前分支最新一条普通提交；保留文件内容为未暂存修改。原 HEAD 会保留在恢复引用中。"
        case "removeDiscard": return "仅移除当前分支最新一条普通提交，并将跟踪文件恢复到父提交；不清理忽略文件。原 HEAD 会保留在恢复引用中。"
        case "squash": return "将当前分支顶部连续多条未推送普通提交合为一条，保留最终文件树；不会删除中间记录或做 rebase。请填写新的提交说明。"
        default: return "新增一条反向提交，不删除原历史。若内存预检发现冲突则拒绝，不会留下未完成的 revert。合并提交未提供主线选择，不能执行。"
        }
    }
    var body: some View {
        List {
            Section("当前分支：" + context.status.branch) { SoftGroupRows {
                SoftGroupRow("operation") {
                    NativeActionMenu(title: "历史操作", accessibilityIdentifier: "localgit.history-operation", enabled: !busy && result.isEmpty, items: operationItems)
                }
                SoftGroupRow("explanation") { Text(explanation).font(.caption).foregroundStyle(.secondary) }
                if kind != "revert" {
                    SoftGroupRow("proof") { Text("预览和确认时均获取 origin 的新鲜分支与标签（只读远端）；仅支持同名 upstream，拒绝无 upstream、浅克隆、额外远端、远端/标签可达或离线无法确认的记录。不会自动推送或 force push。").font(.caption).foregroundStyle(.secondary) }
                }
                if !top { SoftGroupRow("not-top") { Text("这不是当前分支最新提交，仅可新增反向提交，不能移除或压缩此记录。").font(.caption).foregroundStyle(.secondary) } }
                if detail.merge { SoftGroupRow("merge") { Text("合并提交的反向操作需要选择主线；此版本禁用。顶部范围包含合并节点时也拒绝压缩。").font(.caption).foregroundStyle(.secondary) } }
                if kind == "squash" { SoftGroupRow("count") { Stepper("顶部连续 \(count) 条", value: $count, in: 2...100) } }
                if kind == "revert" || kind == "squash" { SoftGroupRow("message") { TextField("新提交说明", text: $message) } }
                SoftGroupRow("author") { TextField("作者姓名", text: $authorName) }
                SoftGroupRow("email") { TextField("作者邮箱", text: $authorEmail).textInputAutocapitalization(.never).autocorrectionDisabled() }
                SoftGroupRow("preview") { Button("检查并预览影响") { run(apply: false) }.disabled(!ready) }
                if let preview {
                    SoftGroupRow("preview-heading") { Text("确认前预览").font(.subheadline).foregroundStyle(.secondary) }
                    SoftGroupRow("head") { Text("基准：" + preview.head).font(.caption.monospaced()).textSelection(.enabled) }
                    SoftGroupRow("commits") { Text("涉及 \(preview.commits.count) 条提交\n" + preview.commits.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled) }
                    for file in preview.files { SoftGroupRow("file:" + file.id) { NavigationLink { CommitPatchDestination(file: file) } label: { Text(file.filename) } } }
                    if kind == "removeKeep" { SoftGroupRow("keep") { Text("以上文件仍留在工作目录，操作后成为未暂存修改。").font(.caption) } }
                    if kind == "squash" { SoftGroupRow("same-tree") { Text("最终 tree 保持不变，不会改写工作文件。").font(.caption) } }
                    if preview.truncated { SoftGroupRow("truncated") { Text("差异超出预览预算，当前不允许确认；请用桌面 Git 检查。").font(.caption).foregroundStyle(.secondary) } }
                    SoftGroupRow("apply") { Button("确认本地历史操作…", role: .destructive) { confirming = true }.disabled(!ready || preview.truncated || authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ((kind == "revert" || kind == "squash") && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) }
                }
                if busy { SoftGroupRow("busy") { ProgressView("核对本地历史…") } }
                if !error.isEmpty { SoftGroupRow("error") { Text(error).font(.caption).foregroundStyle(.red) } }
                if !result.isEmpty { SoftGroupRow("result") { Text(result).font(.caption).textSelection(.enabled) } }
            } }
        }.listStyle(.insetGrouped).navigationTitle("历史操作").adaptiveWorkspaceLayout()
        .onAppear { visible = true; if message.isEmpty { message = "Revert \"" + detail.message.components(separatedBy: "\n")[0] + "\"" } }
        .onDisappear { visible = false; task?.cancel() }
        .onChange(of: kind) { _ in preview = nil; error = ""; message = kind == "squash" ? "" : "Revert \"" + detail.message.components(separatedBy: "\n")[0] + "\"" }
        .onChange(of: count) { _ in preview = nil }
        .confirmationDialog("确认仅修改当前本地分支？", isPresented: $confirming, titleVisibility: .visible) {
            Button("执行本地操作", role: .destructive) { run(apply: true) }
            Button("取消", role: .cancel) {}
        } message: { Text(explanation + "\n账号：" + context.api.login + "\n分支：" + context.status.branch + "\n不会自动推送。") }
    }
    private var operationItems: [NativeMenuItem] {
        [("revert", "新增反向提交", !detail.merge), ("removeKeep", "移除最新提交，保留改动", top), ("removeDiscard", "移除最新提交，丢弃改动", top), ("squash", "压缩顶部连续提交", top)].map { value in
            NativeMenuItem(id: value.0, title: value.1, symbol: value.0 == kind ? "checkmark" : "clock.arrow.circlepath", enabled: value.2, perform: { kind = value.0 })
        }
    }
    private func run(apply: Bool) {
        guard ready, !apply || preview != nil else { return }
        var arguments: [String: Any] = ["kind":kind, "sha":detail.sha, "count":kind == "squash" ? count : 1,
            "expectedHead":context.status.head, "expectedRef":context.status.reference,
            "expectedRemote":context.remote, "token":CredentialStore.read(account:AccountStore.activeID)]
        if let preview, apply {
            arguments["expectedTree"] = preview.tree; arguments["expectedUpstream"] = preview.upstream
            arguments["message"] = message; arguments["authorName"] = authorName; arguments["authorEmail"] = authorEmail
        }
        busy = true; error = ""
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            do {
                let reply: LocalGitHistoryPreview = try await LocalGitEngine.shared.run(apply ? "historyApply" : "historyPreview", project: project, metadata: metadata, internalRoot: internalRoot, arguments: arguments, generation: context.generation)
                guard valid else { if apply { context.changed() }; return }
                if apply {
                    preview = nil
                    result = "本地历史已更新，未推送。\n原 HEAD 恢复引用：" + (reply.recoveryRef ?? "请检查仓库记录")
                    context.changed()
                } else { preview = reply }
            } catch {
                if apply { context.changed() }
                if valid { preview = nil; self.error = error.localizedDescription }
            }
        }
    }
}
