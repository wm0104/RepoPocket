import SwiftUI

struct RepositoryHomeHighlights: View {
    @ObservedObject var api: GitHub
    let repo: String
    @ObservedObject var releaseState: RepositoryPageLoadState<ManagedRelease>
    @ObservedObject var runState: RepositoryPageLoadState<[WorkflowRun]>
    var connected = false
    var revalidationID: UUID? = nil
    private var release: ManagedRelease? { releaseState.value }
    private var run: WorkflowRun? { runState.value?.first }
    private var releaseLoading: Bool { releaseState.loading }
    private var runLoading: Bool { runState.loading }
    private var releaseError: String { releaseState.error }
    private var runError: String { runState.error }
    private var requestKey: String { api.accountID + "\n" + AccountStore.generation.uuidString + "\n" + repo.lowercased() }
    var body: some View {
        Group {
            if connected { releaseContent; runContent }
            else {
                Section("发行版") { releaseContent }
                Section("最近一次 Actions · 所有分支") { runContent }
            }
        }
    }
    private var releaseContent: some View {
            SoftGroupRows(spacingBefore: connected ? 10 : 0) {
                SoftGroupRow("release-heading") {
                    HStack {
                        Text("发行版").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        NativeActionMenu(title: "发行版操作", items: [
                            NativeMenuItem(id: "refresh", title: "刷新发行版", symbol: "arrow.clockwise", enabled: !releaseLoading) { Task { await loadRelease(refresh: true) } }
                        ]).frame(width: 44, height: 44)
                    }.listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12))
                }
                if let release {
                    SoftGroupRow("latest") {
                        NavigationLink { ReleaseManagementDestination(api: api, repo: repo, id: release.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("最新正式发行版", systemImage: "shippingbox").font(.caption).foregroundStyle(.secondary)
                                Text(release.title).font(.headline)
                                Text(release.tag_name + " · " + ChinaDate.day(release.date)).font(.caption).foregroundStyle(.secondary)
                                Text("查看说明与下载附件").font(.caption).foregroundStyle(.tint)
                            }.padding(.vertical, 4)
                        }
                    }
                } else if releaseLoading { SoftGroupRow("loading") { ProgressView("读取最新发行版…") } }
                else if releaseError.isEmpty { SoftGroupRow("empty") { Text("暂无正式发行版").foregroundStyle(.secondary) } }
                if !releaseError.isEmpty { SoftGroupRow("error") { Text(releaseError).font(.caption) } }
                SoftGroupRow("all") { NavigationLink("全部发行版") { ReleaseManagementDestination(api: api, repo: repo) } }
                if !releaseError.isEmpty { SoftGroupRow("retry") { Button("重试读取发行版") { Task { await loadRelease(refresh: true) } }.disabled(releaseLoading) } }
            }
            .task(id: requestKey + (revalidationID?.uuidString ?? "")) { await loadRelease() }
    }
    private var runContent: some View {
            SoftGroupRows(spacingBefore: connected ? 10 : 0) {
                SoftGroupRow("run-heading") {
                    HStack {
                        Text("最近一次 Actions · 所有分支").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        NativeActionMenu(title: "运行状态操作", items: [
                            NativeMenuItem(id: "refresh", title: "刷新运行状态", symbol: "arrow.clockwise", enabled: !runLoading) { Task { await loadRuns(refresh: true) } }
                        ]).frame(width: 44, height: 44)
                    }.listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12))
                }
                if let run {
                    SoftGroupRow("latest") {
                        NavigationLink { WorkflowRunView(api: api, repo: repo, run: run) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                WorkflowStatusBadge(status: run.status, conclusion: run.conclusion)
                                Text(run.display_title ?? run.name ?? "Workflow").font(.headline).lineLimit(2)
                                Text("#\(run.run_number) · \(run.head_branch ?? "—") · \(ChinaDate.day(run.created_at))").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                } else if runLoading { SoftGroupRow("loading") { ProgressView("读取最近运行…") } }
                else if runError.isEmpty { SoftGroupRow("empty") { Text("暂无运行记录").foregroundStyle(.secondary) } }
                if !runError.isEmpty { SoftGroupRow("error") { Text(runError).font(.caption) } }
                SoftGroupRow("all") { NavigationLink("全部运行") { WorkflowRunsView(api: api, repo: repo, branch: "") } }
                if !runError.isEmpty { SoftGroupRow("retry") { Button("重试读取运行") { Task { await loadRuns(refresh: true) } }.disabled(runLoading) } }
            }
            .task(id: requestKey + (revalidationID?.uuidString ?? "")) { await loadRuns() }
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
    private func loadRuns(refresh: Bool = false) async {
        let api = api, repo = repo, generation = AccountStore.generation
        await runState.load(key: requestKey, refresh: refresh, revalidationID: revalidationID, cached: {
            api.cachedWorkflowRuns(repo, branch: "").map { ($0.value, $0.savedAt) }
        }, operation: {
            try await api.workflowRuns(repo, branch: "", page: 1)
        }, isValid: { api.isCurrentSession && AccountStore.generation == generation })
    }
}
