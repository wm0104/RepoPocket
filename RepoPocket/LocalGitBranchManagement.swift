import SwiftUI

struct LocalGitBranchManagement: View {
    let project: LocalGitProject
    let metadata: URL
    let internalRoot: URL
    let generation: UUID
    let isValid: () -> Bool
    let changed: () -> Void
    @State private var branches: LocalGitBranches?
    @State private var busy = false
    @State private var failure = ""
    @State private var result = ""
    @State private var newName = ""
    @State private var creating = false
    @State private var confirmingSwitch = false
    @State private var target: LocalGitBranch?
    @State private var deleting: LocalGitBranch?
    @State private var renaming: LocalGitBranch?
    @State private var merging: LocalGitBranch?
    @State private var renameName = ""
    @State private var operation: Task<Void, Never>?
    private var valid: Bool { generation == AccountStore.generation && isValid() }

    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    SoftGroupRow("create") {
                        Button("从当前 HEAD 新建并切换") { newName = ""; creating = true }
                            .disabled(busy || branches == nil || !valid)
                    }
                    SoftGroupRow("preserve") {
                        Text("新分支从当前提交开始，保留全部未提交修改、暂存区及未跟踪文件。切换已有分支前必须先处理至干净状态。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if busy { SoftGroupRow("loading") { ProgressView("正在处理分支…") } }
                    if !failure.isEmpty {
                        SoftGroupRow("failure") { Text(failure).font(.caption).foregroundStyle(.secondary) }
                    }
                    if !result.isEmpty {
                        SoftGroupRow("result") { Text(result).font(.caption).textSelection(.enabled) }
                    }
                    SoftGroupRow("refresh") { Button("重新检查分支") { operation = Task { await load() } }.disabled(busy || !valid) }
                }
            }
            if let branches {
                Section("本地分支") {
                    SoftGroupRows {
                        for branch in branches.local {
                            SoftGroupRow(branch.id) { branchButton(branch) }
                        }
                    }
                }
                Section("已获取的远端跟踪分支") {
                    SoftGroupRows {
                        for branch in branches.remote {
                            SoftGroupRow(branch.id) { branchButton(branch) }
                        }
                        if branches.remote.isEmpty {
                            SoftGroupRow("empty") { Text("暂无已获取的远端跟踪分支；此列表不会联网获取。").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .navigationTitle("本地分支").adaptiveWorkspaceLayout()
        .task { await load() }
        .refreshable { await load() }
        .onDisappear { operation?.cancel() }
        .sheet(item: $merging) { branch in
            NavigationStack {
                LocalGitMergeView(project: project, metadata: metadata, internalRoot: internalRoot,
                    generation: generation, isValid: isValid, source: branch) {
                    branches = nil; changed()
                }
            }.appSheetCornerRadius()
        }
        .alert("从当前 HEAD 新建并切换", isPresented: $creating) {
            TextField("新分支名称", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("新建并切换") {
                guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    failure = "请输入新分支名称。"; result = ""; return
                }
                start("createBranch", arguments: ["name": newName], success: "已创建并切换到本地分支：" + newName)
            }
        } message: { Text("不会提交、移动或清理你的文件，也不会改动已有暂存。") }
        .alert("切换分支？", isPresented: $confirmingSwitch) {
            Button("取消", role: .cancel) {}
            Button("切换") {
                if let target { start("switchBranch", arguments: ["targetRef": target.reference, "expectedTargetHead": target.head], success: "已切换到本地分支：" + target.name) }
            }
        } message: {
            Text((target?.name ?? "") + "\n切换已有分支要求工作目录与暂存区干净；选择远端跟踪分支会创建同名本地分支。不会自动暂存、丢弃或强制切换。")
        }
        .confirmationDialog("删除本地分支？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { branch in
            Button("删除本地分支", role: .destructive) {
                deleting = nil
                start("deleteBranch", arguments: ["targetRef": branch.reference, "expectedTargetHead": branch.head], success: "已删除本地分支：" + branch.name)
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { branch in
            Text("\(branch.name)\n仅删除本地分支，不删除 GitHub 远端分支或项目文件。含有未合并提交的分支会拒绝删除，没有强制删除选项。")
        }
        .alert("重命名本地分支", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { branch in
            TextField("新分支名称", text: $renameName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("取消", role: .cancel) { renaming = nil }
            Button("重命名") {
                let name = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { failure = "请输入新分支名称。"; result = ""; return }
                renaming = nil
                start("renameBranch", arguments: ["targetRef": branch.reference, "expectedTargetHead": branch.head, "name": name], success: "已重命名为本地分支：" + name)
            }
        } message: { branch in
            Text("\(branch.name)\n只改本地分支名称，不会重命名远端分支，也不会移动你的文件和暂存区。跟踪的远端分支和合并目标保持原样。")
        }
    }

    private func branchButton(_ branch: LocalGitBranch) -> some View {
        Button { target = branch; confirmingSwitch = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(branch.name)
                    Text(String(branch.head.prefix(7))).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if branch.current { Image(systemName: "checkmark").accessibilityLabel("当前分支") }
            }
        }.disabled(busy || branch.current || !valid)
        .contextMenu {
            if !branch.remote {
                Button("重命名") { renameName = branch.name; renaming = branch }.disabled(busy || !valid)
            }
            if !branch.current && !branch.remote {
                Button("合并到当前分支…") { merging = branch }.disabled(busy || !valid)
                    .accessibilityIdentifier("localgit.merge-" + branch.name)
                Button("删除本地分支", role: .destructive) { deleting = branch }.disabled(busy || !valid)
            }
        }
    }
    private func readBranches() async throws -> LocalGitBranches {
        guard valid else { throw CancellationError() }
        return try await LocalGitEngine.shared.run("branches", project: project, metadata: metadata,
            internalRoot: internalRoot, generation: generation)
    }
    private func load() async {
        guard !busy, valid else { return }
        busy = true; failure = ""; result = ""; defer { busy = false }
        do {
            let result = try await readBranches(); try Task.checkCancellation()
            guard valid else { return }; branches = result
        } catch { if valid, !RefreshFailure.isCancellation(error) { failure = error.localizedDescription; branches = nil } }
    }
    private func start(_ action: String, arguments: [String: Any], success: String) {
        guard !busy, valid, let current = branches else { return }
        busy = true; failure = ""; result = ""
        operation = Task {
            defer { busy = false }
            do {
                var request = arguments
                request["expectedHead"] = current.head
                request["expectedRef"] = current.reference
                let _: LocalGitReply = try await LocalGitEngine.shared.run(action, project: project, metadata: metadata,
                    internalRoot: internalRoot, arguments: request, generation: generation)
                try Task.checkCancellation(); guard valid else { return }
                let updated = try await readBranches()
                try Task.checkCancellation(); guard valid else { return }
                branches = updated; result = success
            } catch {
                if valid, !RefreshFailure.isCancellation(error) { failure = error.localizedDescription }
                branches = nil
            }
            // Failed/cancelled native writes can still have changed refs; invalidate the parent snapshot too.
            if valid { changed() }
        }
    }
}
