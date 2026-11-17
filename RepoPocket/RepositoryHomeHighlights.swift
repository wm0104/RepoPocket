import SwiftUI

struct RepositoryHomeHighlights: View {
    @ObservedObject var api: GitHub
    let repo: String
    @ObservedObject var releaseState: RepositoryPageLoadState<ManagedRelease>
    var connected = false
    var revalidationID: UUID? = nil
    private var release: ManagedRelease? { releaseState.value }
    private var releaseLoading: Bool { releaseState.loading }
    private var releaseError: String { releaseState.error }
    private var requestKey: String { api.accountID + "\n" + AccountStore.generation.uuidString + "\n" + repo.lowercased() }
    var body: some View {
        Group {
            if connected { releaseContent }
            else {
                Section("发行版") { releaseContent }
            }
        }
    }
    private var releaseContent: some View {
            SoftGroupRows(spacingBefore: connected ? 10 : 0) {
                SoftGroupRow("release-heading", cardVerticalPadding: 0) {
                    Text("发行版").font(.subheadline).foregroundStyle(.secondary)
                }
                if let release {
                    SoftGroupRow("latest", cardVerticalPadding: 8) {
                        NavigationLink { ReleaseManagementDestination(api: api, repo: repo, id: release.id) } label: {
                            QuotaNavigationLabel(showsIndicator: connected) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(release.title).font(.headline)
                                    Text("最新 · " + release.tag_name + " · " + ChinaDate.day(release.date)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else if releaseLoading { SoftGroupRow("loading") { ProgressView("读取最新发行版…") } }
                else if releaseError.isEmpty { SoftGroupRow("empty") { Text("暂无正式发行版").foregroundStyle(.secondary) } }
                if !releaseError.isEmpty { SoftGroupRow("error") { Text(releaseError).font(.caption) } }
                SoftGroupRow("all") { NavigationLink { ReleaseManagementDestination(api: api, repo: repo) } label: { QuotaNavigationLabel(showsIndicator: connected) { Text("全部发行版") } } }
                if !releaseError.isEmpty { SoftGroupRow("retry") { Button("重试读取发行版") { Task { await loadRelease(refresh: true) } }.disabled(releaseLoading) } }
            }
            .task(id: requestKey + (revalidationID?.uuidString ?? "")) { await loadRelease() }
    }
    private func loadRelease(refresh: Bool = false) async {
        let api = api, repo = repo, generation = AccountStore.generation
        await releaseState.load(key: requestKey, refresh: refresh, revalidationID: revalidationID, cached: {
            guard let path = try? GitHub.repoPath(repo) else { return nil }
            return api.cachedContent(ManagedRelease.self, key: ContentSnapshotCache.key(path + "/releases/latest")).map { ($0.value, $0.savedAt) }
        }, operation: {
            let data = try await api.communityRead(GitHub.repoPath(repo) + "/releases/latest")
            return try JSONDecoder().decode(ManagedRelease.self, from: data)
        }, isValid: { api.isCurrentSession && AccountStore.generation == generation }, errorText: {
            ($0 as? GitHubAPIError)?.status == 404 ? "未找到正式发行版，或当前账号没有读取权限。" : $0.localizedDescription
        })
    }
}
