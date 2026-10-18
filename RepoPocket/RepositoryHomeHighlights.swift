import SwiftUI

struct RepositoryHomeHighlights: View {
    @ObservedObject var api: GitHub
    let repo: String
    @ObservedObject var releaseState: RepositoryPageLoadState<ManagedRelease>
    @ObservedObject var runState: RepositoryPageLoadState<[WorkflowRun]>
    private var release: ManagedRelease? { releaseState.value }
    private var run: WorkflowRun? { runState.value?.first }
    private var releaseLoading: Bool { releaseState.loading }
    private var runLoading: Bool { runState.loading }
    private var releaseError: String { releaseState.error }
    private var runError: String { runState.error }
    private var requestKey: String { api.accountID + "\n" + AccountStore.generation.uuidString + "\n" + repo.lowercased() }
    var body: some View {
        Section("发行版") {
            SoftGroupRows {
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
                SoftGroupRow("refresh") { Button(releaseError.isEmpty ? "刷新发行版" : "重试读取发行版") { Task { await loadRelease(refresh: true) } }.disabled(releaseLoading) }
            }
        }.task(id: requestKey) { await loadRelease() }
        Section("最近一次 Actions · 所有分支") {
            SoftGroupRows {
                if let run {
                    SoftGroupRow("latest") {
                        NavigationLink { WorkflowRunView(api: api, repo: repo, run: run) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                WorkflowStatusBadge(status: run.status, conclusion: run.conclusion)
                                Text(run.display_title ?? run.name ?? "Workflow").font(.headline).lineLimit(2)
                                Text("#\(run.run_number) · \(run.head_branch ?? "—") · \(String(run.created_at.prefix(10)))").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                } else if runLoading { SoftGroupRow("loading") { ProgressView("读取最近运行…") } }
                else if runError.isEmpty { SoftGroupRow("empty") { Text("暂无运行记录").foregroundStyle(.secondary) } }
                if !runError.isEmpty { SoftGroupRow("error") { Text(runError).font(.caption) } }
                SoftGroupRow("all") { NavigationLink("全部运行") { WorkflowRunsView(api: api, repo: repo, branch: "") } }
                SoftGroupRow("refresh") { Button(runError.isEmpty ? "刷新运行状态" : "重试读取运行") { Task { await loadRuns(refresh: true) } }.disabled(runLoading) }
            }
        }.task(id: requestKey) { await loadRuns() }
    }
    private func loadRelease(refresh: Bool = false) async {
        let api = api, repo = repo, generation = AccountStore.generation
        await releaseState.load(key: requestKey, refresh: refresh, operation: {
            let data = try await api.communityRead(GitHub.repoPath(repo) + "/releases/latest")
            return try JSONDecoder().decode(ManagedRelease.self, from: data)
        }, isValid: { api.isCurrentSession && AccountStore.generation == generation }, errorText: {
            ($0 as? GitHubAPIError)?.status == 404 ? "未找到正式发行版，或当前账号没有读取权限。" : $0.localizedDescription
        })
    }
    private func loadRuns(refresh: Bool = false) async {
        let api = api, repo = repo, generation = AccountStore.generation
        await runState.load(key: requestKey, refresh: refresh, operation: {
            try await api.workflowRuns(repo, branch: "", page: 1)
        }, isValid: { api.isCurrentSession && AccountStore.generation == generation })
    }
}
