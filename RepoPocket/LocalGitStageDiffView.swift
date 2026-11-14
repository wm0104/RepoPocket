import SwiftUI

struct LocalGitStageDiffView: View {
    let project: LocalGitProject
    let metadata: URL
    let internalRoot: URL
    let generation: UUID
    let isValid: () -> Bool
    let snapshot: LocalGitStageStatus
    let file: LocalGitChange
    let staged: Bool
    @State private var diff: LocalGitDiff?
    @State private var error = ""
    private var comparison: String { staged ? "HEAD → 暂存区（不含未暂存改动）" : "暂存区 → 工作区（不含已暂存改动）" }
    var body: some View {
        VStack(spacing: 8) {
            Text(comparison).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            if let diff {
                if diff.truncated { Text("差异超过预览预算，未完整展示。").font(.caption) }
                else if diff.binary { Text("二进制或非 UTF-8 文件，无法显示文本差异。").font(.caption) }
                CommitPatchView(file: DesktopCommit.File(filename: file.path, previous_filename: nil,
                    status: file.kind, additions: 0, deletions: 0,
                    patch: diff.binary || diff.truncated ? nil : diff.text), workingTree: false, comparisonLabel: comparison)
            } else if error.isEmpty { ProgressView("读取确认快照差异…") }
            else { Text(error + "\n返回暂存面板重新核对。").foregroundStyle(.secondary).padding() }
        }.navigationTitle((file.path as NSString).lastPathComponent)
        .task {
            guard isValid(), generation == AccountStore.generation else { return }
            do {
                var args = snapshot.arguments
                args["path"] = file.path; args["fingerprint"] = file.fingerprint; args["side"] = staged ? "staged" : "unstaged"
                let value: LocalGitDiff = try await LocalGitEngine.shared.run("stageDiff", project: project, metadata: metadata,
                    internalRoot: internalRoot, arguments: args, generation: generation)
                try Task.checkCancellation(); if isValid(), generation == AccountStore.generation { diff = value }
            } catch { if isValid(), !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
