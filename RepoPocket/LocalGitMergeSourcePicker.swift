import SwiftUI

/// Selects only existing local branches; merging changes the current local branch, not GitHub.
struct LocalGitMergeSourcePicker: View {
    let project: LocalGitProject
    let metadata: URL
    let internalRoot: URL
    let generation: UUID
    let isValid: () -> Bool
    let changed: () -> Void
    @State private var branches: LocalGitBranches?
    @State private var busy = false
    @State private var failure = ""
    private var valid: Bool { generation == AccountStore.generation && isValid() }
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    SoftGroupRow("target") {
                        Text("合入当前本地分支：" + (branches?.local.first(where: { $0.current })?.name ?? "读取中…"))
                    }
                    SoftGroupRow("scope") {
                        Text("先选择来源，再预览合并。只操作本地 Git，不自动推送、不运行工作流；有未提交修改或冲突时会停止。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if busy { SoftGroupRow("loading") { ProgressView("读取本地分支…") } }
                    if !failure.isEmpty {
                        SoftGroupRow("error") { Text(failure).font(.caption).foregroundStyle(.secondary) }
                    }
                    SoftGroupRow("refresh") { Button("重新读取分支") { Task { await load() } }.disabled(busy || !valid) }
                }
            }
            if let branches {
                Section("选择要合入的本地分支") {
                    SoftGroupRows {
                        for branch in branches.local.filter({ !$0.current && !$0.remote }) {
                            SoftGroupRow(branch.id) {
                                NavigationLink {
                                    LocalGitMergeView(project: project, metadata: metadata, internalRoot: internalRoot,
                                        generation: generation, isValid: isValid, source: branch, changed: changed)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(branch.name)
                                        Text(String(branch.head.prefix(8))).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.disabled(!valid || busy).accessibilityIdentifier("localgit.merge-source-" + branch.name)
                            }
                        }
                        if !branches.local.contains(where: { !$0.current && !$0.remote }) {
                            SoftGroupRow("empty") { Text("没有其他本地分支，请先在分支管理中创建或切换远端跟踪分支。").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }.navigationTitle("合并本地分支").listStyle(.insetGrouped).adaptiveWorkspaceLayout()
            .task { await load() }
            .refreshable { await load() }
    }
    private func load() async {
        guard valid, !busy else { return }
        busy = true; failure = ""
        defer { busy = false }
        do {
            let value: LocalGitBranches = try await LocalGitEngine.shared.run("branches", project: project,
                metadata: metadata, internalRoot: internalRoot, generation: generation)
            try Task.checkCancellation(); guard valid else { return }
            branches = value
        } catch {
            if valid, !RefreshFailure.isCancellation(error) { failure = error.localizedDescription }
        }
    }
}
