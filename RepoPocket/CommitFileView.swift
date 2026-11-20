import SwiftUI

struct CommitFileView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let commitSHA: String
    let file: DesktopCommit.File
    @State private var accountChanged = false
    private var validationFailure: String? {
        do {
            try CommitFileRules.validate(commitSHA: commitSHA, status: file.status)
            return nil
        } catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(spacing: 0) {
            Text("只读 · 提交 " + String(commitSHA.prefix(7)))
                .font(.caption).foregroundStyle(.secondary).padding(8)
            if accountChanged || !api.isCurrentSession {
                Text("账号已切换，请返回重新打开。").padding()
            } else if let validationFailure {
                Text(validationFailure).textSelection(.enabled)
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let version = CommitFileRules.Version(sha: commitSHA, path: file.filename)
                CommitHistoryPreviewContent(api: api, repo: repo, version: version)
                    .id(version)
                    .accessibilityIdentifier("commit-full-file-content")
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle((file.filename as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: .githubAccountChanged)) { _ in
            if !api.isCurrentSession { accountChanged = true }
        }
    }
}

// Used only for immutable historical versions; owning view removes this content when its account changes.
struct CommitHistoryPreviewContent: View {
    let api: GitHub
    let repo: String
    let version: CommitFileRules.Version
    @State private var preview: RepositoryFilePreview?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let preview {
                RepositoryFilePreviewBody(preview: preview, path: version.path)
            } else if let failure {
                VStack(spacing: 12) {
                    Text(failure).textSelection(.enabled)
                    Button("重试") { self.failure = nil; attempt += 1 }
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("读取此提交的完整文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: attempt) { await load() }
    }
    private func load() async {
        guard api.isCurrentSession, preview == nil else { return }
        do {
            let preview = try await api.repositoryFilePreview(repo, path: version.path, ref: version.sha, allowEditing: false)
            try Task.checkCancellation()
            guard api.isCurrentSession else { return }
            self.preview = preview
            failure = nil
        } catch {
            guard api.isCurrentSession, !Task.isCancelled, !RefreshFailure.isCancellation(error) else { return }
            if let response = error as? GitHubAPIError, response.status == 404 {
                failure = "此提交中的文件不存在或当前账号无权读取；未切换到最新分支。"
            } else { failure = error.localizedDescription }
        }
    }
}
