import SwiftUI

struct RepositoryFileSearchView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let branch: String
    let canWrite: Bool
    @StateObject private var request = RepositoryPageLoadState<[Entry]>()
    @State private var query = ""
    @State private var generation = AccountStore.generation
    private var matches: [Entry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, request.error.isEmpty, api.isCurrentSession, generation == AccountStore.generation else { return [] }
        return (request.value ?? []).filter { $0.path.localizedStandardContains(term) }
    }
    var body: some View {
        let results = matches
        List {
            Section {
                SoftGroupRows {
                    SoftGroupRow("scope") { Text("当前分支：" + branch).font(.caption).textSelection(.enabled) }
                    SoftGroupRow("hint") { Text("搜索整个分支的普通文件、文件夹名称与路径，不搜索正文、符号链接或子模块。").font(.caption).foregroundStyle(.secondary) }
                    if request.loading { SoftGroupRow("loading") { ProgressView("加载分支目录…") } }
                    if !request.error.isEmpty {
                        SoftGroupRow("error") { Text(request.error).font(.caption).foregroundStyle(.red) }
                        SoftGroupRow("retry") { Button("重试加载目录") { Task { await load(refresh: true) } } }
                    } else if request.value != nil {
                        SoftGroupRow("count") {
                            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "输入名称开始搜索。" : (results.count > 200 ? "找到 \(results.count) 项，显示前 200 项，请缩小搜索范围。" : "找到 \(results.count) 项。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                SoftGroupRows {
                    for entry in results.prefix(200) {
                        SoftGroupRow(entry.id) {
                            if entry.type == "dir" {
                                NavigationLink { DirectoryBrowserDestination(api: api, repo: repo, path: entry.path, branch: branch) } label: { label(entry) }
                                    .accessibilityIdentifier("repository-search-entry-" + entry.path)
                            } else {
                                NavigationLink { FileView(api: api, repo: repo, entry: entry, branch: branch, canWrite: canWrite) } label: { label(entry) }
                                    .accessibilityIdentifier("repository-search-entry-" + entry.path)
                            }
                        }
                    }
                }
            }
        }.listStyle(.insetGrouped).navigationTitle("搜索代码").adaptiveWorkspaceLayout()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "文件或文件夹名称 / 路径")
            .task { await load() }
            .refreshable { await load(refresh: true) }
            .toolbar { Button("刷新目录") { Task { await load(refresh: true) } }.disabled(request.loading) }
    }
    private func label(_ entry: Entry) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                Text(entry.path).font(.caption).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: entry.type == "dir" ? "folder" : "doc.text") }
    }
    private func load(refresh: Bool = false) async {
        await request.load(key: api.accountID + ":" + generation.uuidString + ":" + repo + ":" + branch, refresh: refresh,
            operation: { try await api.repositoryEntries(repo, branch: branch) },
            isValid: { api.isCurrentSession && generation == AccountStore.generation })
    }
}

extension GitHub {
    func repositoryEntries(_ repo: String, branch: String) async throws -> [Entry] {
        let selected = try await resolvedBranch(repo, branch: branch)
        let head = try await workspaceHead(repo, branch: selected)
        let endpoint = try Self.repoPath(repo)
        let commitBytes = try await communityRead(endpoint + "/git/commits/" + Self.component(head))
        let commit = try JSONDecoder().decode(GitCommitInfo.self, from: commitBytes)
        let treeBytes = try await communityRead(endpoint + "/git/trees/" + Self.component(commit.tree.sha), query: [.init(name: "recursive", value: "1")])
        let tree = try await Task.detached(priority: .userInitiated) { try JSONDecoder().decode(GitTreeInfo.self, from: treeBytes) }.value
        try Task.checkCancellation()
        guard isCurrentSession else { throw CancellationError() }
        guard !tree.truncated, tree.tree.count <= 20000 else { throw AppError(text: "分支目录过大或 GitHub 返回了截断结果，未进行不完整搜索。请按目录浏览。") }
        for item in tree.tree { _ = try Self.filePath(item.path) }
        let entries = await Task.detached(priority: .userInitiated) {
            tree.tree.filter { $0.type == "tree" || ($0.type == "blob" && ["100644", "100755"].contains($0.mode)) }.map { item in
                return Entry(name: (item.path as NSString).lastPathComponent, path: item.path, type: item.type == "tree" ? "dir" : "file",
                             sha: item.sha, size: item.size, download_url: nil, content: nil, encoding: nil)
            }.sorted { $0.type != $1.type ? $0.type == "dir" : $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }.value
        try Task.checkCancellation()
        guard isCurrentSession else { throw CancellationError() }
        return entries
    }
}
