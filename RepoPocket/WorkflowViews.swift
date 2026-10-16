import SwiftUI

extension Notification.Name { static let workflowRunDeleted = Notification.Name("workflowRunDeleted") }

struct WorkflowStatusBadge: View {
    let status: String
    let conclusion: String?
    private var value: WorkflowStatusPresentation { .init(status: status, conclusion: conclusion) }
    private var color: Color {
        switch value.tone { case "green": return .green; case "red": return .red; case "orange": return .orange; default: return .secondary }
    }
    var body: some View { Label(value.title, systemImage: value.symbol).foregroundStyle(color).accessibilityLabel("运行状态：" + value.title) }
}

struct WorkflowRunsView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let branch: String
    @StateObject private var store = CommunityPageStore<WorkflowRun>()
    @State private var currentBranchOnly = false
    var body: some View {
        List {
            Section { Toggle("仅当前分支", isOn: $currentBranchOnly).disabled(branch.isEmpty).softGroupedRow(top: true, bottom: true) }
            Section {
                SoftGroupRows {
                    for run in store.items {
                        SoftGroupRow(String(run.id)) {
                            NavigationLink { WorkflowRunView(api: api, repo: repo, run: run) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(run.display_title ?? run.name ?? "Workflow").font(.headline)
                                    WorkflowStatusBadge(status: run.status, conclusion: run.conclusion).font(.subheadline)
                                    Text((run.name ?? "Workflow") + " #\(run.run_number) · " + WorkflowTime.trigger(run.event)).font(.caption).foregroundStyle(.secondary)
                                    Label(run.head_branch ?? "分支未知", systemImage: "arrow.triangle.branch").font(.caption)
                                    WorkflowCreatedText(timestamp: run.created_at).font(.caption).foregroundStyle(.secondary)
                                    Label { WorkflowElapsedText(start: run.run_started_at, end: run.updated_at, status: run.status, approximate: true) } icon: { Image(systemName: "stopwatch") }
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if store.loaded && store.items.isEmpty { SoftGroupRow("empty") { Text("暂无运行记录") } }
                }
            }
            CommunityPageFooter(store: store, next: { load() })
        }.navigationTitle("Actions").adaptiveWorkspaceLayout()
        .toolbar { Button("刷新") { load(reset: true) }.disabled(store.busy) }
        .task { if !store.loaded { load() } }.onChange(of: currentBranchOnly) { _ in load(reset: true) }.onDisappear { store.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .workflowRunDeleted)) { notice in
            if notice.userInfo?["repo"] as? String == repo,
               notice.userInfo?["generation"] as? UUID == AccountStore.generation { load(reset: true) }
        }
    }
    private func load(reset: Bool = false) { store.load(reset: reset, api: api) { try await api.workflowRuns(repo, branch: currentBranchOnly ? branch : "", page: $0) } }
}

struct WorkflowRunView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let run: WorkflowRun
    @StateObject private var store = CommunityPageStore<WorkflowJob>()
    @State private var canWrite = false
    @State private var action: CommunityMutation?
    @State private var busy = false
    @State private var message = ""
    @State private var confirmingDeletion = false
    @Environment(\.dismiss) private var dismiss
    @State private var freshRun: WorkflowRun?
    @State private var statusRevision = 0
    @State private var artifactCount: Int?
    @State private var statusError = ""
    private var displayedRun: WorkflowRun { freshRun ?? run }
    var body: some View {
        List {
            Section {
                WorkflowRunHeading(repo: repo, run: displayedRun)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            Section {
                SoftGroupRows {
                    SoftGroupRow("metadata") { WorkflowRunMetadata(run: displayedRun) }
                    SoftGroupRow("metrics") { WorkflowRunMetrics(api: api, repo: repo, run: displayedRun, artifactCount: artifactCount) }
                    if !statusError.isEmpty { SoftGroupRow("status-error") { Text(statusError).font(.caption).foregroundStyle(.secondary) } }
                }
            } footer: { Text("总耗时按最后更新时间估算；任务与步骤使用各自起止时间。") }
            Section("任务") {
                SoftGroupRows {
                    for job in store.items {
                        SoftGroupRow("job-\(job.id)") {
                            NavigationLink { WorkflowJobView(api: api, repo: repo, run: run.id, job: job) } label: {
                                WorkflowJobRow(job: job)
                            }
                        }
                    }
                    if store.loaded && store.items.isEmpty { SoftGroupRow("empty") { Text("暂无任务") } }
                }
            }
            CommunityPageFooter(store: store, next: { load() })
            if canWrite {
                Section("运行管理") {
                    SoftGroupRows {
                        SoftGroupRow("rerun") { Button("重新运行此工作流") { action = .rerun(run.id) }.disabled(busy) }
                        if displayedRun.status != "completed" {
                            SoftGroupRow("cancel") { Button("取消正在进行的运行", role: .destructive) { action = .cancelRun(run.id) }.disabled(busy) }
                        }
                        SoftGroupRow("delete") { Button("删除此次运行", role: .destructive) { confirmingDeletion = true }.disabled(busy || displayedRun.status != "completed") }
                        if busy { SoftGroupRow("busy") { ProgressView("提交操作…") } }
                        if !message.isEmpty { SoftGroupRow("result") { Text(message).font(.caption) } }
                    }
                }
            }
        }.navigationTitle("运行 #\(run.run_number)").adaptiveWorkspaceLayout().navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("刷新") { load(reset: true); statusRevision += 1 }.disabled(store.busy || busy) }
        .task(id: statusRevision) {
            statusError = ""
            do {
                let bytes = try await api.communityRead(GitHub.repoPath(repo) + "/actions/runs/\(run.id)")
                let value = try JSONDecoder().decode(WorkflowRun.self, from: bytes)
                try Task.checkCancellation(); guard api.isCurrentSession else { return }; freshRun = value
            } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { statusError = "刷新状态失败：" + error.localizedDescription } }
            do {
                let bytes = try await api.communityRead(GitHub.repoPath(repo) + "/actions/runs/\(run.id)/artifacts", query: [.init(name: "per_page", value: "1")])
                let value = try JSONDecoder().decode(WorkflowArtifacts.self, from: bytes)
                try Task.checkCancellation(); guard api.isCurrentSession else { return }; artifactCount = value.total_count
            } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { artifactCount = nil } }
        }
        .task {
            if !store.loaded { load() }
            let access = try? await api.repository(repo)
            guard !Task.isCancelled, api.isCurrentSession else { return }; canWrite = access?.permissions?.push == true
        }.onDisappear { store.cancel() }
        .confirmationDialog("确认操作此工作流运行？", isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), titleVisibility: .visible) {
            Button("确认") { if let selected = action { action = nil; Task { await perform(selected) } } }
            Button("取消", role: .cancel) { action = nil }
        } message: { Text(repo + " · #\(run.run_number)。重新运行会消耗该仓库的 Actions 配额，取消会终止当前运行。") }
        .confirmationDialog("永久删除此次运行？", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("永久删除运行 #\(run.run_number)", role: .destructive) { Task { await perform(.deleteRun(run.id)) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(repo) · #\(run.run_number)\n删除后，本次运行记录及其日志、构建产物将不可再访问，无法撤销。正在进行的运行须先取消。")
        }
    }
    private func load(reset: Bool = false) { store.load(reset: reset, api: api) { try await api.workflowJobs(repo, run: run.id, page: $0) } }
    private func perform(_ action: CommunityMutation) async {
        guard !busy else { return }; busy = true; message = ""; defer { busy = false }
        do {
            _ = try await api.communityMutate(repo, action: action)
            guard api.isCurrentSession else { return }
            if case .deleteRun = action {
                NotificationCenter.default.post(name: .workflowRunDeleted, object: nil,
                    userInfo: ["repo": repo, "run": run.id, "generation": AccountStore.generation])
                dismiss()
            } else { message = "GitHub 已接受操作，请刷新核实新状态。"; statusRevision += 1; load(reset: true) }
        } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { message = error.localizedDescription } }
    }
}

struct WorkflowArtifactsView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let run: Int
    @StateObject private var store = CommunityPageStore<WorkflowArtifact>()
    @State private var downloading = false
    @State private var result = ""
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    for artifact in store.items {
                        SoftGroupRow(String(artifact.id)) {
                            Button { Task { await download(artifact) } } label: {
                                VStack(alignment: .leading) {
                                    Text(artifact.name)
                                    Text(artifact.expired ? "已过期" : ByteCountFormatter.string(fromByteCount: Int64(artifact.size_in_bytes), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(artifact.expired || downloading)
                        }
                    }
                    if store.loaded && store.items.isEmpty { SoftGroupRow("empty") { Text("暂无构建产物") } }
                    if downloading { SoftGroupRow("busy") { ProgressView("下载中，请保持前台…") } }
                    if !result.isEmpty { SoftGroupRow("result") { Text(result).font(.caption) } }
                }
            }
            CommunityPageFooter(store: store, next: { load() })
        }.navigationTitle("构建产物").task { if !store.loaded { load() } }.onDisappear { store.cancel() }
    }
    private func load() {
        store.load(api: api) { page in
            let bytes = try await api.communityRead(GitHub.repoPath(repo) + "/actions/runs/\(run)/artifacts", query: CommunityRules.page(page))
            return try JSONDecoder().decode(WorkflowArtifacts.self, from: bytes).artifacts
        }
    }
    private func download(_ artifact: WorkflowArtifact) async {
        guard !downloading, !artifact.expired else { return }; downloading = true; result = ""; defer { downloading = false }
        do {
            let generation = AccountStore.generation
            try await DownloadStore.shared.requireAuthorization()
            guard api.isCurrentSession else { throw CancellationError() }
            DownloadStore.shared.begin(); defer { DownloadStore.shared.end() }
            let file = try await api.communityArtifact(repo, id: artifact.id, name: artifact.name)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            _ = try await DownloadStore.shared.persist(file, session: generation)
            guard api.isCurrentSession else { throw CancellationError() }; result = "已保存 ZIP 到 " + DownloadStore.shared.label
        } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { result = error.localizedDescription } }
    }
}

struct WorkflowJobView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let run: Int
    let job: WorkflowJob
    @StateObject private var logs = RepositoryPageLoadState<WorkflowStepLogs>()
    @State private var generation = AccountStore.generation
    @State private var freshJob: WorkflowJob?
    @State private var revision = 0
    @State private var expandedSteps: Set<Int> = []
    @State private var error = ""
    private var displayedJob: WorkflowJob { freshJob ?? job }
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    SoftGroupRow("summary") { WorkflowJobRow(job: displayedJob) }
                    if !error.isEmpty { SoftGroupRow("error") { Text(error).font(.caption) } }
                }
            }
            Section("步骤") {
                SoftGroupRows(animateBackground: false) {
                    for step in displayedJob.steps ?? [] {
                        SoftGroupRow("step-\(step.number)") {
                            WorkflowStepRow(step: step, expanded: expandedSteps.contains(step.number), toggle: {
                                var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    if !expandedSteps.insert(step.number).inserted { expandedSteps.remove(step.number) }
                                }
                                if expandedSteps.contains(step.number), step.conclusion != "skipped" { Task { await loadLogs() } }
                            }, output: AnyView(WorkflowInlineLog(output: logs.value?.steps[step.number], loading: logs.loading,
                                error: logs.error, skipped: step.conclusion == "skipped", retry: { Task { await loadLogs(refresh: true) } })))
                        }
                    }
                    SoftGroupRow("log") { NavigationLink("查看任务日志") { WorkflowLogView(api: api, repo: repo, id: job.id) } }
                }
            }
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        }.navigationTitle("任务详情").adaptiveWorkspaceLayout()
        .toolbar { Button("刷新") { revision += 1 } }
        .task(id: revision) {
            error = ""
            do {
                let bytes = try await api.communityRead(GitHub.repoPath(repo) + "/actions/jobs/\(job.id)")
                let value = try JSONDecoder().decode(WorkflowJob.self, from: bytes)
                try Task.checkCancellation(); guard api.isCurrentSession else { return }; freshJob = value
                if !expandedSteps.isEmpty { await loadLogs(refresh: revision > 0) }
            } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
    private func loadLogs(refresh: Bool = false) async {
        let current = displayedJob
        await logs.load(key: repo + ":\(run):\(job.id):" + generation.uuidString, refresh: refresh,
            operation: { try await api.communityRunStepLogs(repo, run: run, job: current.name, steps: Set((current.steps ?? []).map(\.number))) },
            isValid: { generation == AccountStore.generation && api.isCurrentSession })
    }
}

struct WorkflowInlineLog: View {
    let output: WorkflowStepOutput?
    let loading: Bool
    let error: String
    let skipped: Bool
    let retry: () -> Void
    var body: some View {
        if skipped { Text("此步骤已跳过，没有输出。") }
        else if loading { ProgressView("读取步骤日志…") }
        else if !error.isEmpty { Text(error).foregroundStyle(.secondary); Button("重试读取日志", action: retry) }
        else if let output {
            if output.limited { Text(output.text).foregroundStyle(.secondary) }
            else if output.text.isEmpty { Text("此步骤没有输出。") }
            else {
                SourceCodeView(text: output.text, filename: "output.log").frame(height: 260)
                NavigationLink("全屏查看此步骤日志") { SourceCodeView(text: output.text, filename: "output.log").navigationTitle("步骤日志") }
            }
        } else { Text("该步骤日志暂未提供，运行结束后可刷新重试。").foregroundStyle(.secondary) }
    }
}

struct WorkflowLogView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let id: Int
    @State private var log: String?
    @State private var error = ""
    @State private var revision = 0
    var body: some View {
        Group {
          if let log { SourceCodeView(text: log, filename: "output.log") }
          else {
            VStack(alignment: .leading) {
                if error.isEmpty { ProgressView("加载日志…") }
                if !error.isEmpty { Text(error); Button("重试") { revision += 1 } }
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
          }
        }.navigationTitle("运行日志")
        .task(id: revision) {
            error = ""
            do {
                let value = try await api.communityJobLog(repo, id: id)
                try Task.checkCancellation(); guard api.isCurrentSession else { return }; log = value
            } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
}
