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
    @State private var newName = ""
    @State private var creating = false
    @State private var confirmingSwitch = false
    @State private var target: LocalGitBranch?
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
        .alert("从当前 HEAD 新建并切换", isPresented: $creating) {
            TextField("新分支名称", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("新建并切换") { start("createBranch", arguments: ["name": newName]) }.disabled(newName.isEmpty)
        } message: { Text("不会提交、移动或清理你的文件，也不会改动已有暂存。") }
        .alert("切换分支？", isPresented: $confirmingSwitch) {
            Button("取消", role: .cancel) {}
            Button("切换") {
                if let target { start("switchBranch", arguments: ["targetRef": target.reference, "expectedTargetHead": target.head]) }
            }
        } message: {
            Text((target?.name ?? "") + "\n切换已有分支要求工作目录与暂存区干净；选择远端跟踪分支会创建同名本地分支。不会自动暂存、丢弃或强制切换。")
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
    }
    private func readBranches() async throws -> LocalGitBranches {
        guard valid else { throw CancellationError() }
        return try await LocalGitEngine.shared.run("branches", project: project, metadata: metadata,
            internalRoot: internalRoot, generation: generation)
    }
    private func load() async {
        guard !busy, valid else { return }
        busy = true; failure = ""; defer { busy = false }
        do {
            let result = try await readBranches(); try Task.checkCancellation()
            guard valid else { return }; branches = result
        } catch { if valid, !RefreshFailure.isCancellation(error) { failure = error.localizedDescription; branches = nil } }
    }
    private func start(_ action: String, arguments: [String: Any]) {
        guard !busy, valid, let current = branches else { return }
        busy = true; failure = ""
        operation = Task {
            defer { busy = false }
            do {
                var request = arguments
                request["expectedHead"] = current.head
                request["expectedRef"] = current.reference
                let _: LocalGitReply = try await LocalGitEngine.shared.run(action, project: project, metadata: metadata,
                    internalRoot: internalRoot, arguments: request, generation: generation)
                try Task.checkCancellation(); guard valid else { return }
                branches = try await readBranches()
            } catch {
                if valid, !RefreshFailure.isCancellation(error) { failure = error.localizedDescription }
                branches = nil
            }
            // Failed/cancelled native writes can still have changed refs; invalidate the parent snapshot too.
            if valid { changed() }
        }
    }
}
