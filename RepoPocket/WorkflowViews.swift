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
    var headSHA = ""
    @StateObject private var store = CommunityPageStore<WorkflowRun>()
    @StateObject private var selection = WorkflowRunSelection()
    @State private var currentBranchOnly = false
    @State private var failedOnly = false
    @State private var canWrite = false
    @State private var deletionTarget: WorkflowRunDeletionTarget?
    @State private var showingDispatch = false
    @State private var dispatchedBranch: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    private var shouldPoll: Bool {
        visible && scenePhase == .active && api.isCurrentSession && !selection.active && !selection.busy
            && store.items.contains { $0.status == "queued" || $0.status == "in_progress" }
    }
    private var displayedBranch: String { dispatchedBranch ?? branch }
    @SoftGroupRowsBuilder private var runsSection: [SoftGroupRow] {
        for run in store.items {
            SoftGroupRow(String(run.id)) {
                if selection.active {
                    Button { selection.toggle(run) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: selection.selected.contains(run.id) ? "checkmark.square.fill" : "square")
                                .font(.title2).foregroundStyle(Color.accentColor).frame(width: 44, height: 44)
                            WorkflowRunSummary(run: run)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(selection.busy || run.status != "completed")
                        .accessibilityValue(selection.selected.contains(run.id) ? "已选中" : "未选中")
                        .accessibilityIdentifier("workflow-run-\(run.id)")
                } else {
                    NavigationLink { WorkflowRunView(api: api, repo: repo, run: run) } label: {
                        WorkflowRunSummary(run: run)
                    }.accessibilityIdentifier("workflow-run-\(run.id)")
                }
            }
        }
        if store.loaded && store.items.isEmpty {
            SoftGroupRow("empty") { Text(headSHA.isEmpty ? "暂无运行记录" : "尚未发现本次提交的运行。GitHub 可能仍在排队，也可能未配置此分支的 push 工作流，请稍后刷新；不会自动触发或显示其他提交。") }
        }
        // Paging rows stay in this group: a separate section leaves an iOS 16 gap
        // and the split groups lose their outer rounded corners.
        if store.busy && store.items.isEmpty { SoftGroupRow("page-loading") { ProgressView("加载中…") } }
        if !store.error.isEmpty { SoftGroupRow("page-error") { Text(store.error).font(.caption).textSelection(.enabled) } }
        if store.more { SoftGroupRow("page-next") { Button(store.error.isEmpty ? "加载更多" : "重试") { load() }.disabled(store.busy || selection.busy) } }
        if store.limited { SoftGroupRow("page-limited") { Text("已显示前 300 条。").font(.caption).foregroundStyle(.secondary) } }
        if store.updatedAt != nil {
            SoftGroupRow("freshness") {
                ContentFreshnessText(updatedAt: store.updatedAt, updating: store.busy, error: store.error)
            }
        }
    }
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    if headSHA.isEmpty {
                        SoftGroupRow("branch") {
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle("仅当前分支", isOn: $currentBranchOnly).disabled(displayedBranch.isEmpty)
                                    .accessibilityIdentifier("workflow-filter-branch")
                                if let dispatchedBranch { Text(dispatchedBranch).font(.caption).foregroundStyle(.secondary) }
                            }.disabled(selection.busy)
                        }
                    } else {
                        SoftGroupRow("commit") { Text(branch + " · " + String(headSHA.prefix(7))).font(.caption).textSelection(.enabled) }
                    }
                    SoftGroupRow("failed") {
                        Toggle("仅看失败记录", isOn: $failedOnly).accessibilityIdentifier("workflow-filter-failed").disabled(selection.busy)
                    }
                    runsSection
                    if selection.busy { SoftGroupRow("deleting") { ProgressView("正在逐条删除…") } }
                    if !selection.result.isEmpty { SoftGroupRow("result") { Text(selection.result).font(.caption).accessibilityIdentifier("workflow-selection-result") } }
                    if !selection.failures.isEmpty {
                        SoftGroupRow("failures") { Text(selection.failures.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
                    }
                }
            }
        }.navigationTitle("Actions").adaptiveWorkspaceLayout()
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if headSHA.isEmpty {
                    Button("运行工作流") { showingDispatch = true }
                        .disabled(selection.busy || selection.active || !api.isCurrentSession)
                        .accessibilityIdentifier("workflow-dispatch-open")
                }
                if canWrite {
                    Button(selection.active ? "完成" : "多选") {
                        if selection.active { selection.reset() } else { selection.active = true }
                    }.disabled(selection.busy || store.busy)
                }
                Button("刷新") { load(reset: true, preserveItems: true) }.disabled(store.busy || selection.busy)
                    .accessibilityIdentifier("workflow-refresh")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if selection.active && canWrite {
                    Button(allSelected ? "取消全选" : "全选已加载") { selection.toggleAll(store.items) }
                        .disabled(selection.busy || store.busy || selectableIDs.isEmpty)
                    Spacer()
                    Button("删除（\(selection.selected.count)）", role: .destructive) {
                        deletionTarget = selection.target(store.items, repo: repo, api: api)
                    }.disabled(selection.busy || store.busy || selection.selected.isEmpty)
                }
            }
        }
        .task {
            visible = true
            if !store.loaded, let cached = api.cachedWorkflowRuns(repo, branch: (currentBranchOnly || !headSHA.isEmpty) ? displayedBranch : "", failedOnly: failedOnly, headSHA: headSHA) {
                store.seed(cached.value, updatedAt: cached.savedAt)
            }
            load(reset: true, preserveItems: true)
            let access = try? await api.repository(repo)
            guard !Task.isCancelled, api.isCurrentSession else { return }
            canWrite = access?.permissions?.push == true
        }
        .task(id: shouldPoll) {
            guard shouldPoll else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                guard shouldPoll else { return }
                if !store.busy { pollRunning() }
            }
        }
        .refreshable { load(reset: true, preserveItems: true); await store.waitForLoad() }
        .sheet(isPresented: $showingDispatch) {
            AppNavigationStack {
                WorkflowDispatchView(api: api, repo: repo) { ref in
                    dispatchedBranch = ref
                    currentBranchOnly = true
                    failedOnly = false
                    load(reset: true)
                }
            }
        }
        .onChange(of: currentBranchOnly) { _ in load(reset: true) }
        .onChange(of: failedOnly) { _ in load(reset: true) }
        .onChange(of: scenePhase) { phase in if phase == .active && visible { load(reset: true, preserveItems: true) } }
        .onChange(of: selectableIDs) { _ in selection.reconcile(store.items) }
        .onDisappear { visible = false; store.cancel(); selection.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .workflowRunDeleted)) { notice in
            if api.isCurrentSession, notice.userInfo?["repo"] as? String == repo,
               notice.userInfo?["generation"] as? UUID == AccountStore.generation,
               let runID = notice.userInfo?["run"] as? Int { store.remove(id: runID) }
        }
        .confirmationDialog("永久删除选中的运行？", isPresented: Binding(
            get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } }),
            titleVisibility: .visible, presenting: deletionTarget) { target in
            Button("永久删除 \(target.runs.count) 条运行", role: .destructive) {
                store.cancel()
                selection.remove(target, api: api) { runID in
                    NotificationCenter.default.post(name: .workflowRunDeleted, object: nil,
                        userInfo: ["repo": target.repo, "run": runID, "generation": target.generation])
                }
            }
            Button("取消", role: .cancel) {}
        } message: { target in
            Text("\(target.repo)\n将删除选中的 \(target.runs.count) 条已结束运行，包括日志和构建产物，无法撤销。未选择的记录会保留。")
        }
    }
    private var selectableIDs: Set<Int> { Set(store.items.filter { $0.id > 0 && $0.status == "completed" }.map(\.id)) }
    private var allSelected: Bool { !selectableIDs.isEmpty && selectableIDs.isSubset(of: selection.selected) }
    private func pollRunning() {
        let ids = store.items.filter { $0.status == "queued" || $0.status == "in_progress" }.map(\.id)
        store.refreshItems(ids: ids, api: api) { id in
            let bytes = try await api.communityRead(GitHub.repoPath(repo) + "/actions/runs/\(id)")
            return try JSONDecoder().decode(WorkflowRun.self, from: bytes)
        }
    }
    private func load(reset: Bool = false, preserveItems: Bool = false) {
        guard !selection.busy else { return }
        if reset {
            if !preserveItems { selection.reset() }
            deletionTarget = nil
        }
        let requestedBranch = (currentBranchOnly || !headSHA.isEmpty) ? displayedBranch : "", requestedFailedOnly = failedOnly
        store.load(reset: reset, preserveItems: preserveItems, api: api) { try await api.workflowRuns(repo, branch: requestedBranch, page: $0, failedOnly: requestedFailedOnly, headSHA: headSHA) }
    }
}

struct WorkflowDispatchView: View {
    @ObservedObject var api: GitHub
    let repo: String
    var initialBranch: String = ""
    let accepted: (String) -> Void
    @StateObject private var state = WorkflowDispatchState()
    @State private var confirmation: WorkflowDispatchTarget?
    @State private var schemaRevision = 0
    @Environment(\.dismiss) private var dismiss
    private var ready: Bool { state.schemaReady && api.isCurrentSession && !state.attempted }
    private var hasStatus: Bool { state.busy || !state.result.isEmpty || !state.error.isEmpty || !api.isCurrentSession }
    private var workflow: DispatchWorkflow? { state.workflows.first { $0.id == state.workflowID } }
    private var schemaSelection: String {
        "\(repo)|\(api.workflowDispatchSession.accountID)|\(api.workflowDispatchSession.generation)|\(state.workflowID ?? 0)|\(state.ref)|\(workflow?.state ?? "")|\(state.branches.contains { $0.name == state.ref })|\(api.isCurrentSession)|\(schemaRevision)"
    }
    private var listItems: [NativeMenuItem] {
        [NativeMenuItem(id: "workflows", title: state.workflows.isEmpty ? "加载工作流" : "加载更多工作流",
            enabled: state.moreWorkflows && !state.loadingWorkflows, perform: { Task { await state.loadWorkflows(repo, api: api) } }),
         NativeMenuItem(id: "branches", title: state.branches.isEmpty ? "加载分支" : "加载更多分支",
            enabled: state.moreBranches && !state.loadingBranches, perform: { Task { await state.loadBranches(repo, api: api) } })]
    }
    var body: some View {
        List {
            Section {
                SoftGroupRows(bottom: false) {
                    SoftGroupRow("repo") { AppLabeledContent("仓库", value: repo).textSelection(.enabled) }
                    SoftGroupRow("workflow") {
                        VStack(alignment: .leading, spacing: 4) {
                            NativeActionMenu(title: "工作流：" + (workflow?.name ?? "请选择工作流"), symbol: nil,
                                accessibilityIdentifier: "workflow-dispatch-workflow", items: state.workflows.map { item in
                                    NativeMenuItem(id: String(item.id), title: item.name + " · " + item.path + (item.state == "active" ? "" : "（已停用）"),
                                        enabled: item.state == "active",
                                        perform: { state.workflowID = item.id })
                                }).workflowInputSelection(workflow.map { $0.name + " · " + $0.path + ($0.state == "active" ? "" : "（已停用）") })
                            if let workflow { Text(workflow.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                    if state.loadingWorkflows { SoftGroupRow("loading-workflows") { ProgressView("加载工作流…") } }
                    if !state.moreWorkflows && state.workflows.isEmpty { SoftGroupRow("no-workflows") { Text("仓库没有可用工作流。") } }
                    SoftGroupRow("ref") {
                        VStack(alignment: .leading, spacing: 4) {
                            NativeActionMenu(title: "分支：" + (state.ref.isEmpty ? "请选择已有分支" : state.ref), symbol: nil,
                                accessibilityIdentifier: "workflow-dispatch-branch", items: state.branches.map { branch in
                                    NativeMenuItem(id: branch.name, title: branch.name,
                                        perform: { state.ref = branch.name })
                                }).workflowInputSelection(state.ref)
                            if !state.ref.isEmpty && !state.branches.contains(where: { $0.name == state.ref }) {
                                Text(state.ref + "（待核对，请加载分支）").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if state.loadingBranches { SoftGroupRow("loading-branches") { ProgressView("加载分支…") } }
                    if !state.moreBranches && state.branches.isEmpty { SoftGroupRow("no-branches") { Text("没有可选择的已有分支。") } }
                    SoftGroupRow("lists") {
                        NativeActionMenu(title: "列表选项", symbol: nil, items: [.submenu("分页加载", symbol: "list.bullet", children: listItems)])
                    }
                }.disabled(state.attempted || !api.isCurrentSession)
                SoftGroupRows(top: false, bottom: !hasStatus) {
                    SoftGroupRow("schema-heading") { Text("工作流参数").font(.subheadline).foregroundStyle(.secondary) }
                    if state.loadingSchema { SoftGroupRow("schema-loading") { ProgressView("读取所选 ref 的 workflow_dispatch.inputs…") } }
                    if !state.schemaError.isEmpty {
                        SoftGroupRow("schema-error") { Text(state.schemaError).foregroundStyle(.secondary).textSelection(.enabled) }
                        SoftGroupRow("schema-retry") { Button("重新读取参数") { schemaRevision += 1 } }
                    }
                    if let definition = state.definition {
                        if definition.schema.inputs.isEmpty {
                            SoftGroupRow("no-inputs") { Text("此工作流声明了 workflow_dispatch，但没有 inputs。将不发送额外参数。") }
                        }
                        for input in definition.schema.inputs {
                            SoftGroupRow("input-" + input.id) {
                                WorkflowInputField(input: input, environments: definition.environments,
                                    value: Binding(get: { state.inputValues[input.id] ?? "" }, set: { state.inputValues[input.id] = $0 }))
                            }
                        }
                        if !state.validationError.isEmpty { SoftGroupRow("validation") { Text(state.validationError).font(.caption).foregroundStyle(.secondary) } }
                    } else if !state.loadingSchema && state.schemaError.isEmpty {
                        SoftGroupRow("schema-select") { Text("请先选择工作流和已有分支。参数配置读取成功前不能启动。") }
                    }
                    SoftGroupRow("schema-help") { Text("仅发送此文件声明的参数。切换工作流或分支将清除旧值；运行前会再次核对文件。GitHub 仍会校验默认分支中的手动运行资格及 Actions 权限。").font(.caption).foregroundStyle(.secondary) }
                }.disabled(state.attempted || !api.isCurrentSession)
                if hasStatus {
                    SoftGroupRows(top: false) {
                        if state.busy { SoftGroupRow("busy") { ProgressView("正在请求启动…") } }
                        if !state.result.isEmpty { SoftGroupRow("result") { Text(state.result).textSelection(.enabled) } }
                        if !state.error.isEmpty { SoftGroupRow("error") { Text(state.error).foregroundStyle(.secondary).textSelection(.enabled) } }
                        if !api.isCurrentSession { SoftGroupRow("account") { Text("账号已切换，请关闭并重新打开此页面。") } }
                    }
                }
            }
        }.navigationTitle("运行工作流").adaptiveWorkspaceLayout()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(state.busy) }
            ToolbarItem(placement: .confirmationAction) {
                Button("运行") { confirmation = state.target(repo, api: api) }
                    .disabled(!ready || state.busy).accessibilityIdentifier("workflow-dispatch-confirm")
            }
        }
        .interactiveDismissDisabled(state.busy)
        .task {
            if state.ref.isEmpty { state.ref = initialBranch }
            await state.loadWorkflows(repo, api: api)
            await state.loadBranches(repo, api: api)
        }
        .task(id: schemaSelection) { confirmation = nil; await state.loadSchema(repo, api: api) }
        .onDisappear { state.invalidateSchema(); confirmation = nil }
        .confirmationDialog("确认启动工作流？", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible, presenting: confirmation) { target in
            Button("启动") { Task { await state.submit(target, api: api, accepted: accepted) } }
            Button("取消", role: .cancel) {}
        } message: { target in
            Text("仓库：\(target.repo)\n工作流：\(target.workflow.name)\n文件：\(target.workflow.path)\n分支 / ref：\(target.ref)\n\(target.inputsSummary)\n此操作将在 GitHub 上创建一次运行。")
        }
    }
}

struct WorkflowRunView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let run: WorkflowRun
    @StateObject private var store = CommunityPageStore<WorkflowJob>()
    @State private var canWrite = false
    @State private var action: WorkflowRunActionTarget?
    @State private var confirmationID: UUID?
    @State private var actionTask: Task<Void, Never>?
    @State private var busy = false
    @State private var message = ""
    @State private var cancellation = WorkflowCancellationState()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var freshRun: WorkflowRun?
    @State private var statusRevision = 0
    @State private var artifactCount: Int?
    @State private var statusError = ""
    @State private var statusLoading = false
    @State private var statusRequest = UUID()
    @State private var detailsExpanded = false
    private var displayedRun: WorkflowRun { freshRun ?? run }
    var body: some View {
        List {
            Section {
                SoftGroupRows(animateBackground: false) {
                    SoftGroupRow("heading") { WorkflowRunHeading(repo: repo, run: displayedRun) }
                    SoftGroupRow("metrics") { WorkflowRunMetrics(api: api, repo: repo, run: displayedRun, artifactCount: artifactCount) }
                    SoftGroupRow("branch") {
                        Label(displayedRun.head_branch ?? "分支未知", systemImage: "arrow.triangle.branch")
                            .accessibilityIdentifier("workflow-run-branch")
                    }
                    SoftGroupRow("details") {
                        Button { UIRules.withoutAnimation { detailsExpanded.toggle() } } label: {
                            HStack { Text("运行详情"); Spacer(); Image(systemName: detailsExpanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary) }
                                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityValue(detailsExpanded ? "已展开" : "已折叠")
                            .accessibilityIdentifier("workflow-run-details")
                    }
                    if detailsExpanded {
                        SoftGroupRow("actor") {
                            if let actor = displayedRun.actor {
                                CommunityAuthorLink(api: api, user: User(id: nil, login: actor.login, avatar_url: actor.avatar_url, name: nil, followers: nil, following: nil))
                            } else { Text("未知用户").foregroundStyle(.secondary) }
                        }
                        SoftGroupRow("trigger") { AppLabeledContent("触发方式", value: WorkflowTime.trigger(displayedRun.event)) }
                        SoftGroupRow("created") {
                            AppLabeledContent("创建时间", value: ChinaDate.dateTime(displayedRun.created_at))
                        }
                        if let start = WorkflowTime.date(displayedRun.run_started_at) {
                            SoftGroupRow("started") { AppLabeledContent("开始时间", value: ChinaDate.dateTime(start)) }
                        }
                        if let updated = WorkflowTime.date(displayedRun.updated_at) {
                            SoftGroupRow("updated") { AppLabeledContent("更新时间", value: ChinaDate.dateTime(updated)) }
                        }
                        SoftGroupRow("sha") {
                            Text(displayedRun.head_sha).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .accessibilityLabel("提交：" + displayedRun.head_sha).accessibilityIdentifier("workflow-run-sha")
                        }
                    }
                    if !statusError.isEmpty { SoftGroupRow("status-error") { Text(statusError).font(.caption).foregroundStyle(.secondary) } }
                    SoftGroupRow("timing-help") { Text("总耗时按最后更新时间估算；任务与步骤使用各自起止时间。").font(.caption).foregroundStyle(.secondary) }
                    SoftGroupRow("jobs-heading") { Text("任务").font(.subheadline).foregroundStyle(.secondary) }
                    for job in store.items {
                        SoftGroupRow("job-\(job.id)") {
                            NavigationLink { WorkflowJobView(api: api, repo: repo, run: run.id, job: job) } label: {
                                WorkflowJobRow(job: job)
                            }
                        }
                    }
                    if store.loaded && store.items.isEmpty { SoftGroupRow("empty") { Text("暂无任务") } }
                    CommunityPageFooter(store: store, next: { load() }).rows
                    if canWrite {
                        SoftGroupRow("management-heading") { Text("运行管理").font(.subheadline).foregroundStyle(.secondary) }
                        SoftGroupRow("operations") {
                            NativeActionMenu(title: "操作", symbol: nil, accessibilityIdentifier: "workflow-run-actions",
                                enabled: !busy && api.isCurrentSession, items: runActionItems)
                        }
                        if busy { SoftGroupRow("busy") { ProgressView("提交操作…") } }
                        if cancellation.waiting { SoftGroupRow("cancelling") { ProgressView("等待 GitHub 结束运行…") } }
                        if !cancellation.message.isEmpty { SoftGroupRow("cancellation-result") { Text(cancellation.message).font(.caption) } }
                        if !message.isEmpty { SoftGroupRow("result") { Text(message).font(.caption) } }
                    }
                }
            }
        }.navigationTitle("运行 #\(run.run_number)").adaptiveWorkspaceLayout().navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("刷新") { load(reset: true); statusRevision += 1 }.disabled(store.busy || busy) }
        .task(id: statusRevision) {
            await refreshRunStatus()
            do {
                let bytes = try await api.communityRead(GitHub.repoPath(repo) + "/actions/runs/\(run.id)/artifacts", query: [.init(name: "per_page", value: "1")])
                let value = try JSONDecoder().decode(WorkflowArtifacts.self, from: bytes)
                try Task.checkCancellation(); guard api.isCurrentSession else { return }; artifactCount = value.total_count
            } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { artifactCount = nil } }
        }
        .task(id: cancellation.waiting && scenePhase == .active) {
            guard cancellation.waiting, scenePhase == .active else { return }
            for _ in 0..<60 {
                do { try await Task.sleep(nanoseconds: 5_000_000_000); try Task.checkCancellation() }
                catch { return }
                guard api.isCurrentSession else { return }
                await refreshRunStatus()
                guard !Task.isCancelled, api.isCurrentSession else { return }
                if !cancellation.waiting { load(reset: true); statusRevision += 1; return }
            }
            cancellation.stopWaiting()
        }
        .task {
            if !store.loaded { load() }
            let access = try? await api.repository(repo)
            guard !Task.isCancelled, api.isCurrentSession else { return }; canWrite = access?.permissions?.push == true
        }.onDisappear { store.cancel(); action = nil; confirmationID = nil; actionTask?.cancel(); actionTask = nil }
        .confirmationDialog(action?.operation == .delete ? "永久删除此次运行？" : "确认操作此工作流运行？",
            isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }),
            titleVisibility: .visible, presenting: action) { target in
            Button(target.operation == .delete ? "永久删除运行 #\(target.run.run_number)" : target.operation.title,
                   role: target.operation == .delete ? .destructive : nil) { submit(target) }
            Button("取消", role: .cancel) { action = nil; confirmationID = nil }
        } message: { target in
            if target.operation == .delete {
                Text("\(target.repo) · #\(target.run.run_number)（ID \(target.run.id)）\n删除后，本次运行记录及其日志、构建产物将不可再访问，无法撤销。正在进行的运行须先取消。")
            } else if target.operation.isRerun {
                Text("\(target.repo) · #\(target.run.run_number)（ID \(target.run.id)）\n\(target.operation.title)。将消耗该仓库的 Actions 配额。\(target.operation == .rerunFailedJobs ? "重跑范围含 GitHub 判定的依赖任务，不是仅重跑失败步骤；取消或超时不保证存在可重跑的失败任务。" : "将重新运行此次运行的全部任务。")是否可用以 GitHub 校验为准（包括 30 天窗口等限制）。")
            } else {
                Text("\(target.repo) · #\(target.run.run_number)（ID \(target.run.id)）\n取消会终止当前运行；GitHub 接受请求后仍需等待运行结束。")
            }
        }
    }
    private var runActionItems: [NativeMenuItem] {
        var items: [NativeMenuItem] = [.submenu("重新运行", symbol: "arrow.clockwise", children: [
            runActionItem("rerun-failed", operation: .rerunFailedJobs, symbol: "exclamationmark.arrow.circlepath"),
            runActionItem("rerun-all", operation: .rerunAll, symbol: "arrow.clockwise")
        ])]
        if displayedRun.status != "completed" {
            items.append(runActionItem("cancel", operation: .cancel, symbol: "stop.circle"))
        }
        items.append(runActionItem("delete", operation: .delete, symbol: "trash"))
        return items
    }
    private func runActionItem(_ id: String, operation: WorkflowRunOperation, symbol: String) -> NativeMenuItem {
        NativeMenuItem(id: id, title: operation == .cancel && cancellation.requested ? "已请求取消" : operation.title,
            symbol: symbol, enabled: actionUnavailable(operation) == nil,
            destructive: operation == .delete || operation == .cancel, hint: actionUnavailable(operation)) { prepare(operation) }
    }
    private func actionUnavailable(_ operation: WorkflowRunOperation) -> String? {
        guard !busy, !cancellation.waiting else { return "正在处理操作或等待取消结果。" }
        guard canWrite, api.isCurrentSession else { return "请重新核实当前账号的写入权限。" }
        guard let freshRun, !statusLoading, statusError.isEmpty else { return "请先刷新运行状态。" }
        if operation == .cancel && cancellation.requested { return "已请求取消，请刷新核实。" }
        return operation.unavailability(status: freshRun.status, conclusion: freshRun.conclusion, createdAt: freshRun.created_at)
    }
    private func prepare(_ operation: WorkflowRunOperation) {
        guard actionUnavailable(operation) == nil, let freshRun else { return }
        let target = WorkflowRunActionTarget(repo: repo, run: freshRun, operation: operation, generation: AccountStore.generation)
        confirmationID = target.id; action = target
    }
    private func submit(_ target: WorkflowRunActionTarget) {
        guard confirmationID == target.id, !busy else { return }
        confirmationID = nil; action = nil
        actionTask = Task { await perform(target) }
    }
    private func load(reset: Bool = false) { store.load(reset: reset, api: api) { try await api.workflowJobs(repo, run: run.id, page: $0) } }
    private func refreshRunStatus() async {
        let request = UUID(); statusRequest = request; statusError = ""; statusLoading = true
        defer { if statusRequest == request { statusLoading = false } }
        do {
            let bytes = try await api.communityRead(GitHub.repoPath(repo) + "/actions/runs/\(run.id)")
            let value = try JSONDecoder().decode(WorkflowRun.self, from: bytes)
            try Task.checkCancellation(); guard api.isCurrentSession, statusRequest == request else { return }
            freshRun = value
            cancellation.observe(status: value.status, conclusion: value.conclusion)
        } catch {
            if api.isCurrentSession, statusRequest == request, !RefreshFailure.isCancellation(error) { statusError = "刷新状态失败：" + error.localizedDescription }
        }
    }
    private func perform(_ target: WorkflowRunActionTarget) async {
        guard !busy else { return }
        busy = true; message = ""; defer { busy = false; actionTask = nil }
        let action = target.operation.mutation(target.run.id)
        do {
            try Task.checkCancellation()
            guard api.isCurrentSession, target.generation == AccountStore.generation else { throw CancellationError() }
            let access = try await api.repository(target.repo)
            let bytes = try await api.communityRead(GitHub.repoPath(target.repo) + "/actions/runs/\(target.run.id)")
            let current = try JSONDecoder().decode(WorkflowRun.self, from: bytes)
            try Task.checkCancellation()
            try target.validate(current: current, generation: AccountStore.generation, sessionMatches: api.isCurrentSession,
                                canWrite: access.permissions?.push == true, cancellationWaiting: cancellation.waiting)
            freshRun = current
            canWrite = access.permissions?.push == true
            if case .cancelRun = action { guard cancellation.begin() else { return } }
            _ = try await api.communityMutate(target.repo, action: action)
            try Task.checkCancellation()
            guard api.isCurrentSession, target.generation == AccountStore.generation else { return }
            if case .deleteRun = action {
                NotificationCenter.default.post(name: .workflowRunDeleted, object: nil,
                    userInfo: ["repo": target.repo, "run": target.run.id, "generation": target.generation])
                dismiss()
            } else {
                if case .cancelRun = action { cancellation.accepted() }
                else { cancellation = WorkflowCancellationState(); message = "GitHub 已接受操作，请刷新核实新状态。" }
                freshRun = nil
                statusRevision += 1; load(reset: true)
            }
        } catch {
            if api.isCurrentSession, target.generation == AccountStore.generation, !Task.isCancelled {
                if case .cancelRun = action, cancellation.requested { cancellation.uncertain(error.localizedDescription) }
                else { message = error.localizedDescription }
                freshRun = nil; statusRevision += 1
            }
        }
    }
}

struct WorkflowArtifactsView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let run: Int
    @StateObject private var store = CommunityPageStore<WorkflowArtifact>()
    @State private var downloading = false
    @State private var result = ""
    @State private var downloadedArtifact: URL?
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
                    CommunityPageFooter(store: store, next: { load() }).rows
                }
            }
        }.navigationTitle("构建产物").downloadCompletionNotice($downloadedArtifact)
            .task { if !store.loaded { load() } }.onDisappear { store.cancel() }
    }
    private func load() {
        store.load(api: api) { page in
            let bytes = try await api.communityRead(GitHub.repoPath(repo) + "/actions/runs/\(run)/artifacts", query: CommunityRules.page(page))
            return try JSONDecoder().decode(WorkflowArtifacts.self, from: bytes).artifacts
        }
    }
    private func download(_ artifact: WorkflowArtifact) async {
        guard !downloading, !artifact.expired else { return }; downloading = true; result = ""; downloadedArtifact = nil; defer { downloading = false }
        do {
            let generation = AccountStore.generation
            try await DownloadStore.shared.requireAuthorization()
            guard api.isCurrentSession else { throw CancellationError() }
            DownloadStore.shared.begin(); defer { DownloadStore.shared.end() }
            let file = try await api.communityArtifact(repo, id: artifact.id, name: artifact.name)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let saved = try await DownloadStore.shared.persist(file, session: generation)
            guard api.isCurrentSession else { throw CancellationError() }; downloadedArtifact = saved
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
                SoftGroupRows(animateBackground: false) {
                    SoftGroupRow("summary") { WorkflowJobRow(job: displayedJob) }
                    if !error.isEmpty { SoftGroupRow("error") { Text(error).font(.caption) } }
                    SoftGroupRow("steps-heading") { Text("步骤").font(.subheadline).foregroundStyle(.secondary) }
                    for step in displayedJob.steps ?? [] {
                        SoftGroupRow("step-\(step.number)") {
                            WorkflowStepRow(step: step, expanded: expandedSteps.contains(step.number), toggle: {
                                UIRules.withoutAnimation {
                                    if !expandedSteps.insert(step.number).inserted { expandedSteps.remove(step.number) }
                                }
                                if expandedSteps.contains(step.number), step.conclusion != "skipped" { Task { await loadLogs() } }
                            }, output: AnyView(WorkflowInlineLog(output: logs.value?.steps[step.number], loading: logs.loading,
                                error: logs.error, skipped: step.conclusion == "skipped", retry: { Task { await loadLogs(refresh: true) } })))
                        }
                        if expandedSteps.contains(step.number), step.conclusion != "skipped", !logs.loading, logs.error.isEmpty,
                           let output = logs.value?.steps[step.number], !output.limited, !output.text.isEmpty {
                            SoftGroupRow("full-log-\(step.number)") {
                                NavigationLink("全屏查看此步骤日志") { WorkflowLogReader(rawText: output.text).navigationTitle("步骤日志") }
                                    .accessibilityIdentifier("workflow-step-full-log-\(step.number)")
                            }
                        }
                    }
                    SoftGroupRow("log") {
                        NavigationLink("查看任务日志") { WorkflowLogView(api: api, repo: repo, id: job.id) }
                            .accessibilityIdentifier("workflow-job-log")
                    }
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
        await logs.load(key: repo + ":\(run):\(job.id):\(current.run_attempt ?? 0):" + generation.uuidString, refresh: refresh,
            operation: {
                guard let attempt = current.run_attempt else { throw AppError(text: "尚未确认任务运行次数，请刷新任务后重试。") }
                return try await api.communityRunStepLogs(repo, run: run, attempt: attempt, job: current.name, steps: Set((current.steps ?? []).map(\.number)))
            },
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
                WorkflowLogReader(rawText: output.text).frame(height: 260)
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
          if let log { WorkflowLogReader(rawText: log) }
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
