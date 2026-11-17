import SwiftUI

struct CommitFileView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let commitSHA: String
    let file: DesktopCommit.File
    @State private var text: String?
    @State private var failure = ""
    @State private var loading = false
    @State private var attempted = false
    @State private var generation = AccountStore.generation
    private var valid: Bool { api.isCurrentSession && generation == AccountStore.generation }
    var body: some View {
        VStack(spacing: 0) {
            Text("只读 · 提交 " + String(commitSHA.prefix(7)))
                .font(.caption).foregroundStyle(.secondary).padding(8)
            if !valid {
                Text("账号已切换，请返回重新打开。").padding()
            } else if let text {
                SourceCodeView(text: text, filename: file.filename)
                    .accessibilityIdentifier("commit-full-file-content")
            } else if loading {
                ProgressView("读取此提交的完整文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Text(failure).textSelection(.enabled)
                    if file.status != "removed" && file.status != "deleted" {
                        Button("重试") { Task { await load() } }
                    }
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle((file.filename as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task { guard !attempted else { return }; attempted = true; await load() }
        .onReceive(NotificationCenter.default.publisher(for: .githubAccountChanged)) { _ in text = nil }
    }
    private func load() async {
        guard !loading, valid else { return }
        loading = true; failure = ""
        defer { loading = false }
        do {
            try CommitFileRules.validate(commitSHA: commitSHA, status: file.status)
            let entry = try await api.file(repo, path: file.filename, branch: commitSHA)
            try Task.checkCancellation()
            guard valid else { return }
            guard entry.path == file.filename, entry.type == "file" else {
                throw AppError(text: "此提交中的路径不是可读取的普通文件。")
            }
            text = try CommitFileRules.decode(size: entry.size, encoding: entry.encoding, content: entry.content)
        } catch {
            guard valid, !RefreshFailure.isCancellation(error) else { return }
            if let response = error as? GitHubAPIError, response.status == 404 {
                failure = "此提交中的文件不存在或当前账号无权读取；未切换到最新分支。"
            } else { failure = error.localizedDescription }
        }
    }
}
