import SwiftUI

struct LocalGitMergePreview: Decodable {
    let head: String
    let reference: String
    let sourceRef: String
    let sourceSHA: String
    let method: String
    let alreadyContained: Bool
    let fastForward: Bool
    let conflicts: [String]
    let conflictsTruncated: Bool
    let commits: [LocalGitCommit]
    let commitsTruncated: Bool
    let files: [DesktopCommit.File]
    let truncated: Bool
    var needsCommit: Bool { !alreadyContained && (method == "squash" || !fastForward) }
    var targetName: String { String(reference.dropFirst("refs/heads/".count)) }
    var sourceName: String { String(sourceRef.dropFirst("refs/heads/".count)) }
    var arguments: [String: Any] {
        ["expectedHead": head, "expectedRef": reference, "sourceRef": sourceRef,
         "sourceSHA": sourceSHA, "method": method]
    }
}

@MainActor
final class LocalGitMergeState: ObservableObject {
    @Published var preview: LocalGitMergePreview?
    @Published var busy = false
    @Published var failure = ""
    @Published var result = ""
}

struct LocalGitMergeView: View {
    let project: LocalGitProject
    let metadata: URL
    let internalRoot: URL
    let generation: UUID
    let isValid: () -> Bool
    let source: LocalGitBranch
    let changed: () -> Void
    @StateObject private var state = LocalGitMergeState()
    @State private var method = "ordinary"
    @State private var message = ""
    @State private var confirming = false
    @State private var confirmation: LocalGitMergePreview?
    @State private var operation: Task<Void, Never>?
    @AppStorage("localGit.authorName") private var authorName = ""
    @AppStorage("localGit.authorEmail") private var authorEmail = ""
    private var valid: Bool { project.active && generation == AccountStore.generation && isValid() }
    private var canConfirm: Bool {
        guard valid, !state.busy, let preview = state.preview,
              preview.conflicts.isEmpty, !preview.conflictsTruncated, preview.method == method else { return false }
        return !preview.needsCommit || (!authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !authorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        List {
            Section("仅在本地合并") {
                SoftGroupRows {
                    SoftGroupRow("source") { Text("来源本地分支：" + source.name).textSelection(.enabled) }
                    SoftGroupRow("method") {
                        Picker("合并方式", selection: $method) {
                            Text("普通合并").tag("ordinary")
                            Text("压缩合并").tag("squash")
                        }.disabled(state.busy || !valid).accessibilityIdentifier("localgit.merge-method")
                    }
                    SoftGroupRow("explanation") {
                        Text(method == "ordinary" ? "合并到当前检出的分支：可快进时直接快进；分叉时创建双亲合并提交。" : "把三方合并结果作为一个新提交写入当前分支，仅以当前 HEAD 为父提交；不改动来源分支。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    SoftGroupRow("safety") {
                        Text("不会联网、推送、删除分支或触发 Actions。未提交、已暂存、未跟踪、冲突、未完成操作、子模块或游离 HEAD 均拒绝；不自动暂存、重置或强制覆盖。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    SoftGroupRow("refresh") {
                        Button("重新预览并检查分支") { refresh() }.disabled(state.busy || !valid).accessibilityIdentifier("localgit.merge-preview")
                    }
                    if state.busy { SoftGroupRow("busy") { ProgressView("正在核对本地合并…") } }
                    if !state.failure.isEmpty { SoftGroupRow("error") { Text(state.failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) } }
                    if !state.result.isEmpty { SoftGroupRow("result") { Text(state.result).textSelection(.enabled).accessibilityIdentifier("localgit.merge-result") } }
                }
            }
            if let preview = state.preview {
                Section("合并方向") {
                    SoftGroupRows {
                        SoftGroupRow("direction") { Text(preview.sourceName + " → " + preview.targetName).font(.headline).textSelection(.enabled) }
                        SoftGroupRow("pins") {
                            Text("当前：\(preview.head.prefix(7))\n来源：\(preview.sourceSHA.prefix(7))").font(.caption.monospaced()).textSelection(.enabled)
                        }
                        SoftGroupRow("outcome") {
                            Text(preview.alreadyContained ? "当前分支已包含来源提交，不会创建提交或改动文件。" :
                                (preview.needsCommit ? (method == "squash" ? "将创建一个单亲压缩提交。" : "将创建真正的双亲合并提交。") : "将安全快进到来源提交，无需创建新提交。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !preview.conflicts.isEmpty || preview.conflictsTruncated {
                    Section("存在冲突，无法合并") {
                        SoftGroupRows {
                            for path in preview.conflicts { SoftGroupRow("conflict:" + path) { Text(path).foregroundStyle(.red).textSelection(.enabled) } }
                            SoftGroupRow("conflict-help") { Text("仅在内存中计算冲突，没有修改原文件或暂存区。请在桌面 Git 处理冲突后重新预览。最多列出 200 个冲突文件。" + (preview.conflictsTruncated ? "冲突列表未完整展示。" : "")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if preview.needsCommit {
                    Section("提交作者（由你确认）") {
                        SoftGroupRows {
                            SoftGroupRow("message") { TextField("提交信息", text: $message).accessibilityIdentifier("localgit.merge-message") }
                            SoftGroupRow("author-name") { TextField("作者姓名", text: $authorName).accessibilityIdentifier("localgit.merge-author-name") }
                            SoftGroupRow("author-email") { TextField("作者邮箱（由你确认）", text: $authorEmail).accessibilityIdentifier("localgit.merge-author-email").textInputAutocapitalization(.never).autocorrectionDisabled() }
                        }.disabled(state.busy || !valid)
                    }
                }
                Section("来源新增提交 · \(preview.commits.count)") {
                    SoftGroupRows {
                        for commit in preview.commits {
                            SoftGroupRow("commit:" + commit.sha) {
                                NavigationLink {
                                    LocalProjectCommitView(project: project, metadata: metadata, internalRoot: internalRoot, sha: commit.sha)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(commit.message)
                                        Text(commit.author + " · " + String(commit.sha.prefix(7))).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.disabled(state.busy || !valid)
                            }
                        }
                        if preview.commits.isEmpty { SoftGroupRow("no-commits") { Text("没有来源新增提交").foregroundStyle(.secondary) } }
                        if preview.commitsTruncated { SoftGroupRow("commit-limit") { Text("仅展示前 100 个来源提交，列表未完整展示。").font(.caption).foregroundStyle(.secondary) } }
                    }
                }
                Section("合并结果相对当前 HEAD 的文件变化") {
                    SoftGroupRows {
                        for file in preview.files {
                            SoftGroupRow("file:" + file.id) {
                                NavigationLink {
                                    CommitPatchView(file: file, workingTree: false, comparisonLabel: "本地合并结果与预览时当前 HEAD 比较")
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.filename)
                                        Text(file.patch == nil ? "二进制、非 UTF-8、冲突或超出差异预算；无文本预览" : "+\(file.additions)  −\(file.deletions)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.disabled(state.busy || !valid)
                            }
                        }
                        if preview.files.isEmpty { SoftGroupRow("no-files") { Text("没有可展示的文件变化").foregroundStyle(.secondary) } }
                        if preview.truncated { SoftGroupRow("file-limit") { Text("预览未完整展示：最多 200 个文件、20,000 项比较、单文件 256 KiB、总差异 1 MiB。完整合并另有安全预算，超过即拒绝，不会只合并预览部分。").font(.caption).foregroundStyle(.secondary) } }
                    }
                }
                Section {
                    SoftGroupRows {
                        SoftGroupRow("confirm") {
                            Button(preview.alreadyContained ? "确认无需合并" : "确认本地合并…") {
                                guard canConfirm else { return }
                                confirmation = preview; confirming = true
                            }.disabled(!canConfirm).accessibilityIdentifier("localgit.merge-confirm")
                        }
                    }
                }
            }
        }
        .navigationTitle("合并本地分支").adaptiveWorkspaceLayout()
        .task { await load() }
        .onChange(of: method) { _ in
            confirming = false; confirmation = nil; state.preview = nil; refresh()
        }
        .onChange(of: valid) { active in
            if !active { operation?.cancel(); confirming = false; confirmation = nil; state.preview = nil }
        }
        .onDisappear { operation?.cancel(); confirming = false; confirmation = nil }
        .alert("确认合并到当前分支？", isPresented: $confirming) {
            Button("取消", role: .cancel) { confirmation = nil }
            Button("确认本地合并") {
                guard canConfirm, let confirmation else { return }
                operation = Task { await apply(confirmation) }
            }
        } message: {
            if let confirmation {
                Text("\(confirmation.sourceName) → \(confirmation.targetName)\n方式：\(confirmation.method == "ordinary" ? "普通合并" : "压缩合并")\n当前 \(confirmation.head.prefix(7)) · 来源 \(confirmation.sourceSHA.prefix(7))\n提交与来源分支如有变化将拒绝执行，必须重新预览。仅修改本地当前分支，不推送。")
            }
        }
    }

    private func refresh() { operation = Task { await load() } }
    private func load() async {
        guard valid, !state.busy else { return }
        state.busy = true; state.failure = ""; state.result = ""; state.preview = nil
        confirming = false; confirmation = nil
        defer { state.busy = false }
        do {
            guard !source.remote, !source.current else { throw LocalGitError(text: "请选择另一个已有本地分支作为来源。") }
            let branches: LocalGitBranches = try await LocalGitEngine.shared.run("branches", project: project,
                metadata: metadata, internalRoot: internalRoot, generation: generation)
            try Task.checkCancellation(); guard valid else { throw CancellationError() }
            guard let currentSource = branches.local.first(where: { $0.reference == source.reference }), !currentSource.current else {
                throw LocalGitError(text: "来源分支不存在或已成为当前分支，请返回重新选择。")
            }
            let preview: LocalGitMergePreview = try await LocalGitEngine.shared.run("mergePreview", project: project,
                metadata: metadata, internalRoot: internalRoot,
                arguments: ["expectedHead": branches.head, "expectedRef": branches.reference,
                            "sourceRef": currentSource.reference, "sourceSHA": currentSource.head, "method": method], generation: generation)
            try Task.checkCancellation(); guard valid else { return }
            state.preview = preview
            if message.isEmpty { message = "Merge \(preview.sourceName) into \(preview.targetName)" }
        } catch {
            if valid, !RefreshFailure.isCancellation(error) { state.failure = error.localizedDescription }
        }
    }
    private func apply(_ preview: LocalGitMergePreview) async {
        guard valid, canConfirm, preview.method == method else { return }
        state.busy = true; state.failure = ""; state.result = ""; state.preview = nil; confirmation = nil
        defer { state.busy = false; if valid { changed() } }
        do {
            try Task.checkCancellation(); guard valid else { throw CancellationError() }
            var arguments = preview.arguments
            arguments["authorName"] = authorName; arguments["authorEmail"] = authorEmail; arguments["message"] = message
            let result: LocalGitReply = try await LocalGitEngine.shared.run("mergeBranch", project: project,
                metadata: metadata, internalRoot: internalRoot, arguments: arguments, generation: generation)
            try Task.checkCancellation(); guard valid else { return }
            state.result = preview.alreadyContained ? "当前分支已包含来源，无需合并。" :
                "已在本地完成\(method == "ordinary" ? "普通合并" : "压缩合并")：\(preview.sourceName) → \(preview.targetName)\n\(result.head ?? result.commit ?? "")\n尚未推送，来源分支保持不变。"
        } catch {
            if valid {
                state.failure = RefreshFailure.isCancellation(error) ? "操作已取消。若写入已开始，请重新检查仓库；中断恢复记录会保留，不会自动重置或清理文件。" : error.localizedDescription
            }
        }
    }
}
