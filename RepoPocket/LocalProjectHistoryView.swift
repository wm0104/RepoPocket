import SwiftUI

enum LocalProjectSheet: Identifiable {
    case commit, diff(String)
    var id: String { switch self { case .commit: return "commit"; case .diff(let path): return "diff:" + path } }
}
struct LocalGitCommitDetail: Decodable {
    let sha: String
    let message: String
    let author: String
    let time: Double
    let files: [DesktopCommit.File]
    let truncated: Bool
    let merge: Bool
}
struct LocalProjectCommitView: View {
    let project: LocalGitProject
    let metadata: URL
    let internalRoot: URL
    let sha: String
    @State private var detail: LocalGitCommitDetail?
    @State private var attempted = false
    @State private var busy = false
    @State private var failure = ""
    @State private var generation = AccountStore.generation
    var body: some View {
        List {
            if let detail {
                Section("本地提交") {
                    SoftGroupRows {
                        SoftGroupRow("message") { Text(detail.message).textSelection(.enabled) }
                        SoftGroupRow("author") { Text(detail.author + " · " + LocalGitDate.string(detail.time)).font(.caption).foregroundStyle(.secondary) }
                        SoftGroupRow("sha") { Text(detail.sha).font(.caption.monospaced()).textSelection(.enabled) }
                        if detail.merge { SoftGroupRow("merge") { Text("合并提交：与第一个父提交比较。").font(.caption).foregroundStyle(.secondary) } }
                    }
                }
                Section("变更文件 · \(detail.files.count)") {
                    SoftGroupRows {
                        for file in detail.files {
                            SoftGroupRow(file.id) {
                                NavigationLink { CommitPatchDestination(file: file) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(file.filename)
                                        Text(file.patch == nil ? "二进制、较大文件或差异超出预算" : "+\(file.additions)  −\(file.deletions)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if detail.files.isEmpty && !detail.truncated { SoftGroupRow("empty") { Text("此提交没有文件内容变化") } }
                        if detail.truncated { SoftGroupRow("limit") { Text("提交超过预览预算（200 个变化文件、20,000 项比较或 1 MiB 差异），未完整展示；可使用桌面工具查看。").font(.caption).foregroundStyle(.secondary) } }
                    }
                }
            }
            if busy { ProgressView("读取本地提交…").softGroupedRow(top: true, bottom: true) }
            if !failure.isEmpty { Section {
                Text(failure).font(.caption).softGroupedRow(top: true)
                Button("重试") { Task { await load() } }.disabled(busy).softGroupedRow(bottom: true)
            } }
        }.listStyle(.insetGrouped).navigationTitle("提交详情").adaptiveWorkspaceLayout()
        .task { guard !attempted else { return }; attempted = true; await load() }
    }
    private func load() async {
        guard !busy, generation == AccountStore.generation else { return }
        busy = true; failure = ""; defer { busy = false }
        do {
            let value: LocalGitCommitDetail = try await LocalGitEngine.shared.run("commitDetail", project: project, metadata: metadata, internalRoot: internalRoot, arguments: ["sha":sha], generation: generation)
            try Task.checkCancellation(); guard generation == AccountStore.generation else { return }; detail = value
        } catch {
            if Task.isCancelled || RefreshFailure.isCancellation(error) { attempted = false }
            else { failure = error.localizedDescription }
        }
    }
}
