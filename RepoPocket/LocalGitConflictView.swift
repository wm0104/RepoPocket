import SwiftUI

struct LocalGitConflictView: View {
    let project: LocalGitProject
    let metadata: URL
    let internalRoot: URL
    let generation: UUID
    let isValid: () -> Bool
    let changed: () -> Void
    @State private var session: LocalGitConflictSession?
    @State private var busy = false
    @State private var error = ""
    @State private var result = ""
    @State private var confirmation = ""
    @State private var confirming = false
    @State private var message = "Merge resolved changes"
    @State private var task: Task<Void, Never>?
    @AppStorage("localGit.authorName") private var authorName = ""
    @AppStorage("localGit.authorEmail") private var authorEmail = ""
    private var valid: Bool { project.active && generation == AccountStore.generation && isValid() }
    private var ready: Bool {
        guard valid, !busy, let session, session.active, let files = session.files else { return false }
        return session.phase != "aborting" && !files.isEmpty && files.allSatisfy(\.resolved) &&
            !authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !authorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    SoftGroupRow("explanation") {
                        Text("解决结果仅保存在真实 Git 暂存区；工作文件在明确继续时才更新。中止恢复合并前暂存区，不清理新增或忽略文件；外部修改会阻止覆盖。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    SoftGroupRow("refresh") { Button("重新核对合并状态") { refresh() }.disabled(busy || !valid) }
                    if busy { SoftGroupRow("progress") { ProgressView("正在核对合并…") } }
                    if !error.isEmpty { SoftGroupRow("error") { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                    if !result.isEmpty { SoftGroupRow("result") { Text(result).textSelection(.enabled) } }
                    if let session, session.active {
                        SoftGroupRow("direction-heading") { Text("合并方向与进度").font(.subheadline).foregroundStyle(.secondary) }
                        SoftGroupRow("target") { Text("当前分支：" + session.targetName) }
                        SoftGroupRow("source") { Text("传入分支：" + session.sourceName) }
                        SoftGroupRow("pins") { Text("当前 \((session.head ?? "").prefix(7)) · 传入 \((session.sourceSHA ?? "").prefix(7))").font(.caption.monospaced()) }
                        SoftGroupRow("count") { Text("已解决 \(session.resolved ?? 0) / \(session.files?.count ?? 0) · \(session.phase ?? "")") }
                        SoftGroupRow("rename") { Text("rename 相似度检测未启用：改名显示为删除原路径与新增目标路径。删除/修改冲突可明确选择保留或删除；跨路径、目录/文件冲突会在开始前拒绝，不猜测改名意图。合并结果请在继续前逐文件核对。 ").font(.caption).foregroundStyle(.secondary) }
                        SoftGroupRow("recovery") { Text("恢复引用：" + (session.recoveryRef ?? "")).font(.caption.monospaced()).textSelection(.enabled) }
                        SoftGroupRow("files-heading") { Text("冲突文件 · 结果优先").font(.subheadline).foregroundStyle(.secondary) }
                        for file in session.files ?? [] {
                            SoftGroupRow("file:" + file.path) {
                                NavigationLink {
                                    LocalGitConflictEditor(project: project, metadata: metadata, internalRoot: internalRoot,
                                        generation: generation, isValid: isValid, session: session, path: file.path) { refresh(); changed() }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label(file.path, systemImage: file.resolved ? "checkmark.circle" : "exclamationmark.triangle")
                                        Text((file.resolved ? "已标记解决" : "待解决") + (!file.oursExists ? " · 当前已删除" : "") + (!file.theirsExists ? " · 传入已删除" : "")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.disabled(busy || !valid || session.phase != "resolving")
                            }
                        }
                        SoftGroupRow("continue-heading") { Text(session.method == "squash" ? "继续生成单亲压缩提交" : "继续生成双亲合并提交").font(.subheadline).foregroundStyle(.secondary) }
                        SoftGroupRow("name") { TextField("作者姓名", text: $authorName) }
                        SoftGroupRow("email") { TextField("作者邮箱", text: $authorEmail).textInputAutocapitalization(.never).keyboardType(.emailAddress) }
                        SoftGroupRow("message") { TextField("合并提交说明", text: $message) }
                        SoftGroupRow("continue") {
                            Button("全部校验并继续本地合并…") { confirmation = "conflictContinue"; confirming = true }
                                .disabled(!ready).accessibilityIdentifier("localgit.conflict-continue")
                        }
                        SoftGroupRow("abort") {
                            Button("安全中止本地合并…", role: .destructive) { confirmation = "conflictAbort"; confirming = true }
                                .disabled(busy || !valid)
                                .accessibilityIdentifier("localgit.conflict-abort")
                        }
                    } else if session != nil {
                        SoftGroupRow("empty-session") { Text("当前没有未完成的 RepoPocket 合并会话。") }
                    }
                }
            }
        }.navigationTitle("本地合并冲突").adaptiveWorkspaceLayout()
        .task { await load() }
        .onDisappear { task?.cancel() }
        .onChange(of: valid) { active in if !active { task?.cancel(); confirming = false; session = nil } }
        .alert(confirmation == "conflictAbort" ? "安全中止合并？" : "继续生成本地合并提交？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button(confirmation == "conflictAbort" ? "确认中止" : "确认继续", role: confirmation == "conflictAbort" ? .destructive : nil) {
                let operation = confirmation; task = Task { await mutate(operation) }
            }
        } message: {
            Text(confirmation == "conflictAbort" ? "恢复合并前状态，保留合并后新增的无关文件。发现外部修改会拒绝覆盖，不执行 hard reset 或 clean。" : "再次核对分支、暂存区指纹、工作文件及全部解决状态后，签出结果并创建本地提交。不自动推送，不触发工作流。")
        }
    }
    private func refresh() { task = Task { await load() } }
    private func load() async {
        guard valid, !busy else { return }; busy = true; error = ""; defer { busy = false }
        do {
            let value: LocalGitConflictSession = try await LocalGitEngine.shared.run("conflictStatus", project: project, metadata: metadata, internalRoot: internalRoot, generation: generation)
            try Task.checkCancellation(); if valid { session = value }
        } catch { if valid, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription } }
    }
    private func mutate(_ operation: String) async {
        guard valid, !busy, let session, session.active, operation != "conflictContinue" || ready else { return }
        busy = true; error = ""; defer { busy = false }
        do {
            var args = session.arguments; args["authorName"] = authorName; args["authorEmail"] = authorEmail; args["message"] = message
            let reply: LocalGitReply = try await LocalGitEngine.shared.run(operation, project: project, metadata: metadata, internalRoot: internalRoot, arguments: args, generation: generation)
            try Task.checkCancellation(); guard valid else { return }
            result = operation == "conflictAbort" ? "已安全中止；无关新增文件未删除。" : "合并提交已保存在本地：\(reply.head ?? "")\n尚未推送。"
            self.session = nil; changed()
        } catch { if valid { self.error = RefreshFailure.isCancellation(error) ? "操作取消；会话与恢复证据保留，请重新核对。" : error.localizedDescription } }
    }
}
