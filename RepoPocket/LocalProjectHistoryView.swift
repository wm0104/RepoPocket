import SwiftUI

private struct LocalCommitMessageHeights: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

enum LocalProjectSheet: Identifiable {
    case commit, info, files(LocalGitAddAction), diff(String), deb(String), delete(String), workflow(repo: String, branch: String)
    var id: String { switch self { case .commit: return "commit"; case .info: return "info"; case .files(let action): return "files:" + action.rawValue; case .diff(let path): return "diff:" + path; case .deb(let path): return "deb:" + path; case .delete(let path): return "delete:" + path; case .workflow(let repo, let branch): return "workflow:" + repo + ":" + branch } }
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
    var workspace: LocalGitHistoryContext? = nil
    @StateObject private var request = RepositoryPageLoadState<LocalGitCommitDetail>()
    private var detail: LocalGitCommitDetail? { request.value }
    private var busy: Bool { request.loading }
    private var failure: String { request.error }
    @State private var generation = AccountStore.generation
    @State private var messageExpanded = false
    @State private var messageNeedsExpansion = false
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    if let detail {
                        SoftGroupRow("commit-title") { Text("本地提交").font(.caption).foregroundStyle(.secondary) }
                        SoftGroupRow("message") { commitMessage(detail.message) }
                        if messageNeedsExpansion {
                            SoftGroupRow("message-toggle") {
                                Button(messageExpanded ? "收起说明" : "展开完整说明") { UIRules.withoutAnimation { messageExpanded.toggle() } }
                                    .accessibilityValue(messageExpanded ? "已展开" : "已收起")
                            }
                        }
                        SoftGroupRow("author") { Text(detail.author + " · " + LocalGitDate.string(detail.time)).font(.caption).foregroundStyle(.secondary) }
                        SoftGroupRow("sha") { Text(detail.sha).font(.caption.monospaced()).textSelection(.enabled) }
                        if let workspace {
                            SoftGroupRow("history-actions") {
                                NavigationLink("历史操作…") {
                                    LocalGitHistoryActions(project: project, metadata: metadata, internalRoot: internalRoot, detail: detail, context: workspace)
                                }.disabled(!workspace.isValid() || workspace.generation != AccountStore.generation)
                            }
                        }
                        if detail.merge { SoftGroupRow("merge") { Text("合并提交：与第一个父提交比较。").font(.caption).foregroundStyle(.secondary) } }
                        SoftGroupRow("files-title") { Text("变更文件 · \(detail.files.count)").font(.caption).foregroundStyle(.secondary) }
                        for file in detail.files {
                            SoftGroupRow("file:" + file.id) {
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
                    if busy { SoftGroupRow("loading") { ProgressView("读取本地提交…") } }
                    if !failure.isEmpty {
                        SoftGroupRow("failure") { Text(failure).font(.caption) }
                        SoftGroupRow("retry") { Button("重试") { Task { await load(refresh: true) } }.disabled(busy) }
                    }
                }
            }
        }.listStyle(.insetGrouped).navigationTitle("提交详情").adaptiveWorkspaceLayout()
        .task { await load() }
    }
    private func commitMessage(_ message: String) -> some View {
        let displayed = message.trimmingCharacters(in: .newlines)
        return Text(displayed)
            .lineLimit(messageExpanded ? nil : 4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { geometry in
                    // Measure at the row's actual width, including Dynamic Type and line wrapping.
                    ZStack(alignment: .topLeading) {
                        Text(displayed).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                            .background { GeometryReader { proxy in
                                Color.clear.preference(key: LocalCommitMessageHeights.self, value: ["summary": proxy.size.height])
                            } }
                        Text(displayed).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            .background { GeometryReader { proxy in
                                Color.clear.preference(key: LocalCommitMessageHeights.self, value: ["full": proxy.size.height])
                            } }
                    }.frame(width: geometry.size.width, alignment: .leading)
                        .hidden().accessibilityHidden(true)
                }
            }
            .onPreferenceChange(LocalCommitMessageHeights.self) { heights in
                let needsExpansion = heights["full", default: 0] > heights["summary", default: 0] + 0.5
                UIRules.withoutAnimation {
                    if messageNeedsExpansion != needsExpansion { messageNeedsExpansion = needsExpansion }
                    if !needsExpansion && messageExpanded { messageExpanded = false }
                }
            }
    }
    private func load(refresh: Bool = false) async {
        await request.load(key: project.id.uuidString + ":" + sha + ":" + generation.uuidString, refresh: refresh,
            operation: { try await LocalGitEngine.shared.run("commitDetail", project: project, metadata: metadata, internalRoot: internalRoot, arguments: ["sha":sha], generation: generation) },
            isValid: { generation == AccountStore.generation })
    }
}
