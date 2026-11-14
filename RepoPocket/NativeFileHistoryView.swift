import SwiftUI

struct NativeFileHistoryView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let path: String
    let branch: String
    @StateObject private var store = CommunityPageStore<DesktopCommit>()
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    SoftGroupRow("path") { Text(path).font(.caption).textSelection(.enabled) }
                    for commit in store.items {
                        SoftGroupRow(commit.sha) {
                            NavigationLink { CommitDetailView(api: api, repo: repo, sha: commit.sha) } label: {
                                VStack(alignment: .leading) {
                                    Text(commit.commit.message.components(separatedBy: "\n").first ?? commit.sha)
                                    Text(String(commit.sha.prefix(8)) + " · " + (commit.commit.author?.name ?? "未知作者")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if store.loaded && store.items.isEmpty { SoftGroupRow("empty") { Text("暂无文件历史") } }
                }
            }
            CommunityPageFooter(store: store, next: { load() })
        }.navigationTitle("文件历史").task { if !store.loaded { load() } }.onDisappear { store.cancel() }
    }
    private func load() {
        store.load(api: api) { page in
            let selected = try await api.resolvedBranch(repo, branch: branch)
            let bytes = try await api.communityRead(GitHub.repoPath(repo) + "/commits", query: CommunityRules.page(page) + [.init(name: "sha", value: selected), .init(name: "path", value: path)])
            return try JSONDecoder().decode([DesktopCommit].self, from: bytes)
        }
    }
}
