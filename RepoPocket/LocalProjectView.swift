import SwiftUI

struct LocalProjectView: View {
    @ObservedObject var api: GitHub
    @ObservedObject var store: LocalGitRegistry
    let project: LocalGitProject
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var externalRefreshPending = false
    @StateObject private var state = LocalProjectState()
    @StateObject private var importer = LocalGitImportState()
    @State private var importTarget: String?
    @State private var choosingImportTarget = false
    @State private var expandedFolders = Set<String>()
    @State private var fileSizes: [String: Int64] = [:]
    @State private var generation = AccountStore.generation
    @State private var accountID = AccountStore.activeID
    @State private var sheet: LocalProjectSheet?
    @State private var historyExpanded = false
    @State private var historyPages: [LocalGitCommit] = []
    @State private var historyPageKey = ""
    @State private var historyError = ""
    @State private var historyTask: Task<Void, Never>?
    @State private var historyRequestID: UUID?
    @State private var pendingCommit = false
    @State private var syncing: String?
    @State private var note = ""
    @State private var build: (repo: String, branch: String, sha: String)?
    @State private var pullSummary: LocalGitPullSummary?
    @State private var pullFilesExpanded = false
    @AppStorage("localGit.authorName") private var authorName = ""
    @AppStorage("localGit.authorEmail") private var authorEmail = ""
    @State private var commitMessage = ""
    private var valid: Bool { generation == AccountStore.generation && api.isCurrentSession && store.projects.contains(where: { $0.id == project.id }) }
    private var selected: [LocalGitChange] { state.snapshot?.status.files.filter { state.selected.contains($0.path) && $0.blocked.isEmpty } ?? [] }
    private var busy: Bool { state.busy || importer.busy }
    private var commitBlockedReason: String? {
        if busy { return "正在核对或执行 Git 操作，请稍候。" }
        if !state.fresh { return "结果尚未核对，请下拉刷新后再提交。" }
        if state.snapshot?.status.canCommit != true { return "已有暂存、冲突或未完成操作，请先在原工具处理。" }
        if selected.count > 1000 { return "单次最多提交 1000 个文件，请减少勾选数量。" }
        if selected.isEmpty { return "请先勾选要提交的文件。" }
        return nil
    }
    var body: some View {
        projectSheets.confirmationDialog(syncTitle, isPresented: syncPresented, titleVisibility: .visible) {
            if syncing == "push" {
                Button("仅推送") { syncing = nil; sync("push") }
                Button("推送后运行工作流…") { syncing = nil; sync("push", runWorkflow: true) }
            } else {
                Button("确认") { guard let action = syncing else { return }; syncing = nil; sync(action) }
            }
            Button("取消", role: .cancel) { syncing = nil }
        } message: { Text(syncMessage) }
    }
    private var syncTitle: String {
        if syncing == "recover" { return "核对并继续中断操作？" }
        return syncing == "push" ? "推送当前分支？" : "拉取远端当前分支？"
    }
    private var syncPresented: Binding<Bool> {
        Binding(get: { syncing != nil }, set: { if !$0 { syncing = nil } })
    }
    private var syncMessage: String {
        let remote = state.snapshot?.history.remote ?? ""
        let branch = state.snapshot?.status.branch ?? ""
        return "账号：\(api.login)\n\(remote)\n分支：\(branch)" + (syncing == "push" ? "\n仅推送不会由 App 启动工作流；仓库配置的 push 或 PR 自动检查仍可能运行。" : "")
    }
    private var projectList: some View {
        List {
            if importer.busy || !importer.message.isEmpty {
                Section { SoftGroupRows {
                    if importer.busy { SoftGroupRow("import-progress") { ProgressView("正在导入整个选择，请保持前台…") } }
                    if !importer.message.isEmpty { SoftGroupRow("import-summary") { Text(importer.message).font(.caption).textSelection(.enabled) } }
                } }
            }
            if let snapshot = state.snapshot {
                summarySection(snapshot)
                if let pullSummary { pullResultSection(pullSummary) }
                if !snapshot.status.files.isEmpty || !snapshot.status.canCommit { changesSection(snapshot) }
                actionsSection(snapshot)
                historySection(snapshot)
            }
            Section {
                SoftGroupRows {
                    if busy {
                        SoftGroupRow("busy") { ProgressView("Git 操作中…") }
                        SoftGroupRow("cancel") { Button("取消等待") { state.cancel(); importer.cancel(); note = "已取消等待。写入可能已完成，请下拉检查真实状态后再操作。" } }
                    }
                    if !state.error.isEmpty { SoftGroupRow("error") { Text(state.error).font(.caption).foregroundStyle(.red) } }
                    if !note.isEmpty { SoftGroupRow("note") { Text(note).font(.caption).foregroundStyle(.secondary) } }
                }
            }
        }.listStyle(.insetGrouped).navigationTitle(project.name).adaptiveWorkspaceLayout()
        .task { visible = true; await check(); refreshExternalChanges() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { externalRefreshPending = true; refreshExternalChanges() }
        }
        .onChange(of: busy) { if !$0 { refreshExternalChanges() } }
        .onChange(of: sheet?.id) { if $0 == nil { refreshExternalChanges() } }
        .onChange(of: syncing) { if $0 == nil { refreshExternalChanges() } }
        .refreshable { await check(force: true) }
        .toolbar { Menu {
            Button("项目信息") { sheet = .info }.disabled(state.snapshot == nil || busy)
            Button("导入位置：" + ((importTarget ?? "").isEmpty ? "根目录" : (importTarget ?? ""))) { choosingImportTarget = true }.disabled(busy)
            Button("导入文件") { importer.picker = WorkspaceImportRequest(kind: .files) }.disabled(busy)
            Button("导入文件夹") { importer.picker = WorkspaceImportRequest(kind: .folder) }.disabled(busy)
            Button("检查变化") { Task { await check(force: true) } }.disabled(busy)
        } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("localgit.project-actions").accessibilityLabel("项目操作") }
        .modifier(LocalGitImportPresentation(importer: importer, project: project, internalRoot: store.internalRoot,
                                              directory: importTarget ?? "", generation: generation, changed: imported))
        .sheet(isPresented: $choosingImportTarget) {
            NavigationStack {
                LocalGitDirectoryPicker(project: project, internalRoot: store.internalRoot, directory: "") { picked in
                    importTarget = picked
                    choosingImportTarget = false
                }
                .toolbar { Button("关闭") { choosingImportTarget = false } }
            }.appSheetCornerRadius()
        }
        .onDisappear { visible = false; state.cancel(); importer.cancel(); resetHistoryPages() }
    }
    private var projectSheets: some View {
        projectList
        .sheet(item: $sheet, onDismiss: finishCommit) { route in
            switch route {
            case .diff(let path): LocalProjectDiffView(project:project,metadata:store.metadata(project),internalRoot:store.internalRoot,
                                 path:path,head:state.snapshot?.status.head ?? "")
            case .commit: commitForm
            case .info:
                NavigationStack {
                    List {
                        if let snapshot = state.snapshot {
                            Section { SoftGroupRows {
                                SoftGroupRow("branch") { LabeledContent("当前分支", value: snapshot.status.branch) }
                                SoftGroupRow("head") { Text(snapshot.status.head).font(.caption.monospaced()).textSelection(.enabled) }
                                SoftGroupRow("remote") { Text(snapshot.history.remoteIssue ?? (snapshot.history.remote.isEmpty ? "未配置远端仓库" : snapshot.history.remote)).font(.caption).textSelection(.enabled) }
                                if snapshot.history.remoteMissing == true {
                                    SoftGroupRow("configure-remote") {
                                        NavigationLink("关联 GitHub 仓库…") {
                                            LocalProjectRemoteView(api: api, project: project, metadata: store.metadata(project), internalRoot: store.internalRoot,
                                                status: snapshot.status, generation: generation, isValid: { valid }) {
                                                sheet = nil; state.filesChanged()
                                                Task { await check(force: true) }
                                            }
                                        }
                                    }
                                }
                            } }
                        }
                    }.navigationTitle("项目信息").adaptiveWorkspaceLayout().toolbar { Button("关闭") { sheet = nil } }
                }.appSheetCornerRadius()
            case .deb(let path): LocalProjectDebEditor(api: api, project: project, internalRoot: store.internalRoot, path: path) { imported([path]) }
            case .delete(let path): LocalProjectEditor(project: project, internalRoot: store.internalRoot, path: path, deleting: true) { imported([path]) }
            case .workflow(let repo, let branch):
                NavigationStack {
                    WorkflowDispatchView(api: api, repo: repo, initialBranch: branch) { ref in
                        note = "GitHub 已接受工作流启动请求，分支：" + ref + "。请到 Actions 查看运行结果。"
                    }
                }.appSheetCornerRadius()
            }
        }
    }
    private var commitForm: some View {
        NavigationStack {
                Form {
                    Section("提交到本地分支：" + (state.snapshot?.status.branch ?? "")) {
                        TextField("提交说明",text:$commitMessage).softGroupedRow(top: true)
                        TextField("作者姓名",text:$authorName).softGroupedRow()
                        TextField("作者邮箱（由你确认）",text:$authorEmail).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow(bottom: true)
                    }
                    Section("本次选中文件") { ForEach(selected) { row in Text(row.path + " · " + row.label).softGroupedRow(top: row.id == selected.first?.id, bottom: row.id == selected.last?.id) } }
                    Section {
                        SoftGroupRows {
                            SoftGroupRow("help") { Text("这里只创建本地提交，稍后可单独推送。未勾选文件保持原状。").font(.caption) }
                            SoftGroupRow("confirm") {
                                Button("确认创建本地提交") { pendingCommit = true; sheet = nil }
                                    .disabled(commitMessage.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }.navigationTitle("确认本地提交").adaptiveWorkspaceLayout().toolbar { Button("取消") { sheet = nil } }
        }
    }
    private func summarySection(_ snapshot: LocalGitSnapshot) -> some View {
        Section {
            SoftGroupRows(animateBackground: false) {
                SoftGroupRow("branches") {
                    NavigationLink {
                        LocalGitBranchManagement(project: project, metadata: store.metadata(project),
                            internalRoot: store.internalRoot, generation: generation, isValid: { valid }) {
                            state.filesChanged(); state.selected.removeAll()
                            build = nil; pullSummary = nil
                            note = "分支操作已结束，请重新检查当前分支与文件。"
                        }
                    } label: {
                        HStack {
                            Label(snapshot.status.branch, systemImage: "arrow.triangle.branch")
                            Spacer()
                            if snapshot.history.tracking {
                                Text(snapshot.history.ahead == 0 && snapshot.history.behind == 0 ? "已同步" : "待推送 \(snapshot.history.ahead) · 远端领先 \(snapshot.history.behind)")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else { Text("没有可比较的远端分支").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.disabled(busy || !state.fresh || !valid)
                        .accessibilityIdentifier("localgit.branches").accessibilityHint("管理、创建或切换本地分支")
                }
                SoftGroupRow("files") {
                    NavigationLink("浏览与编辑项目文件") { LocalProjectFilesView(api: api, project: project, internalRoot: store.internalRoot, imported: imported) {
                        state.filesChanged(); note = "文件已修改，正在检查变化。"
                        Task { await check(force: true) }
                    } }.disabled(busy)
                }
            }
        } footer: {
            if snapshot.status.files.isEmpty && snapshot.status.canCommit { Text("工作区干净") }
        }
    }

    private func pullResultSection(_ summary: LocalGitPullSummary) -> some View {
        Section("本次拉取结果") {
            SoftGroupRows(animateBackground: false) {
                SoftGroupRow("summary") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(summary.commits == 0 ? "远端没有新提交" : "新增 \(summary.commits) 个提交")
                        if summary.commits > 0 {
                            Text("新增 \(summary.added) · 修改 \(summary.modified) · 删除 \(summary.deleted) 个文件")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if summary.totalFiles > 0 {
                    SoftGroupRow("disclosure") {
                        Button {
                            UIRules.withoutAnimation { pullFilesExpanded.toggle() }
                        } label: {
                            HStack {
                                Text(pullFilesExpanded ? "收起文件列表" : "查看文件列表")
                                Spacer()
                                Text("\(summary.totalFiles)").foregroundStyle(.secondary)
                                Image(systemName: pullFilesExpanded ? "chevron.up" : "chevron.down").font(.caption)
                            }
                        }.buttonStyle(.plain).accessibilityValue(pullFilesExpanded ? "已展开" : "已折叠")
                    }
                    if summary.beforeSHA == nil || summary.afterSHA == nil {
                        SoftGroupRow("missing-revisions") {
                            Text("此记录缺少拉取前后提交，只能显示摘要；下次成功拉取后可点按文件查看差异。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if pullFilesExpanded {
                        for file in summary.files.prefix(1000) {
                            SoftGroupRow("file:" + file.path) {
                                if let beforeSHA = summary.beforeSHA, let afterSHA = summary.afterSHA {
                                    NavigationLink {
                                        LocalProjectDiffView(project: project, metadata: store.metadata(project), internalRoot: store.internalRoot,
                                                             path: file.path, head: "", beforeSHA: beforeSHA, afterSHA: afterSHA, isValid: { valid })
                                    } label: { pullFileLabel(file) }
                                } else { pullFileLabel(file) }
                            }
                        }
                        if summary.truncated {
                            SoftGroupRow("truncated") {
                                Text("文件列表仅显示前 \(summary.files.count) 项，共 \(summary.totalFiles) 项。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }.transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private func pullFileLabel(_ file: LocalGitPullSummary.File) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(file.label).foregroundStyle(.secondary)
            Text(file.path).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.caption)
    }

    private func changesSection(_ snapshot: LocalGitSnapshot) -> some View {
        Section("工作区变化 · \(snapshot.status.files.count)") {
            SoftGroupRows(animateBackground: false) {
                if snapshot.status.files.isEmpty { SoftGroupRow("empty") { Text("没有内容变化") } }
                else {
                    SoftGroupRow("selection") {
                        HStack {
                            let paths = Set(snapshot.status.files.filter { $0.blocked.isEmpty }.map(\.path))
                            Button(!paths.isEmpty && paths.isSubset(of: state.selected) ? "取消全选" : "全选") { state.toggleSelection(paths) }.disabled(busy || paths.isEmpty)
                            Spacer()
                            Text("已选 \(selected.count)").font(.caption).foregroundStyle(.secondary)
                        }.buttonStyle(.borderless)
                    }
                    for row in LocalGitChangeTree.rows(snapshot.status.files, expanded: expandedFolders) {
                        SoftGroupRow(row.id) { changeRow(row) }
                    }
                }
                if !snapshot.status.canCommit { SoftGroupRow("blocked") { Text("已有暂存、冲突或未完成操作。请先在原工具处理，不会撤销原暂存。").foregroundStyle(.red).font(.caption) } }
            }
        }.transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
    private func changeRow(_ row: LocalGitChangeRow) -> some View {
        let all = !row.selectable.isEmpty && row.selectable.isSubset(of: state.selected)
        let some = !row.selectable.isDisjoint(with: state.selected)
        return HStack {
            Button { state.toggleSelection(row.selectable) } label: {
                Image(systemName: all ? "checkmark.square.fill" : (some ? "minus.square.fill" : "square")).frame(width: 44, height: 44)
            }.buttonStyle(.borderless).disabled(busy || row.selectable.isEmpty)
                .accessibilityLabel(row.name + (row.folder ? " 全选" : " 选择"))
                .accessibilityValue(all ? "已选" : (some ? "部分已选" : "未选"))
            if row.folder {
                Button {
                    UIRules.withoutAnimation {
                        if !expandedFolders.insert(row.path).inserted { expandedFolders.remove(row.path) }
                    }
                } label: {
                    HStack {
                        Label(row.name, systemImage: "folder")
                        Spacer()
                        Text("\(row.files.count)").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: expandedFolders.contains(row.path) ? "chevron.up" : "chevron.down").font(.caption)
                    }
                }.buttonStyle(.borderless).disabled(busy).accessibilityIdentifier("localgit.folder." + row.path)
                    .accessibilityValue(expandedFolders.contains(row.path) ? "已展开" : "已折叠")
            } else if let file = row.files.first {
                Button { sheet = .diff(file.path) } label: {
                    LocalGitFileLabel(name: row.name, size: fileSizes[file.path], detail: file.blocked.isEmpty ? file.label : file.blocked)
                }.buttonStyle(.borderless).disabled(busy)
                if row.name.lowercased().hasSuffix(".deb"), file.kind != "deleted" {
                    Menu {
                        Button("编辑包信息") { sheet = .deb(file.path) }
                        Button("查看变化") { sheet = .diff(file.path) }
                    } label: { Image(systemName: "ellipsis").padding(8) }.disabled(busy)
                        .accessibilityLabel("更多操作：" + row.name)
                }
            }
        }
        .padding(.leading, CGFloat(min(row.depth, 5)) * 16)
        .contextMenu {
            if !row.folder, let file = row.files.first, file.kind != "deleted" {
                Button("删除文件", role: .destructive) { sheet = .delete(file.path) }.disabled(busy || !valid)
            }
        }
    }

    private func actionsSection(_ snapshot: LocalGitSnapshot) -> some View {
        Section {
            SoftGroupRows(animateBackground: false) {
                if snapshot.status.repoState == 100 { SoftGroupRow("recover") { Button("检查并恢复中断操作") { syncing = "recover" }.disabled(busy) } }
                if !snapshot.status.files.isEmpty {
                    SoftGroupRow("commit") {
                        Button("创建本地提交（\(selected.count) 个文件）") { if authorName.isEmpty { authorName = api.login }; sheet = .commit }
                            .disabled(commitBlockedReason != nil)
                    }
                    if let reason = commitBlockedReason { SoftGroupRow("reason") { Text(reason).font(.caption).foregroundStyle(.secondary) } }
                }
                SoftGroupRow("sync") {
                    HStack(spacing: 0) {
                        Button { syncing = "pull" } label: {
                            VStack(spacing: 4) {
                                Label("拉取", systemImage: "arrow.down")
                                Text("远端 · 仅快进").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }.accessibilityLabel("拉取远端（仅快进）")
                        Divider().frame(height: 32)
                        Button { syncing = "push" } label: {
                            VStack(spacing: 4) {
                                Label("推送", systemImage: "arrow.up")
                                Text("本地提交").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }.accessibilityLabel("推送本地提交")
                    }.buttonStyle(.borderless).disabled(busy || !state.fresh || snapshot.history.remote.isEmpty)
                }
                SoftGroupRow("merge") {
                    NavigationLink("合并本地分支…") {
                        LocalGitMergeSourcePicker(project: project, metadata: store.metadata(project), internalRoot: store.internalRoot,
                            generation: generation, isValid: { valid }) {
                            state.filesChanged(); state.selected.removeAll(); resetHistoryPages()
                            build = nil; pullSummary = nil
                            note = "本地合并操作已结束，请重新检查当前分支与文件；不会自动推送。"
                        }
                    }.disabled(busy || !state.fresh || !valid)
                        .accessibilityIdentifier("localgit.merge")
                }
                if snapshot.history.remote.isEmpty {
                    SoftGroupRow("remote-unavailable") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(snapshot.history.remoteIssue ?? "没有可用的 GitHub HTTPS 远端，暂时不能拉取或推送；本地提交不受影响。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("查看远端设置…") { sheet = .info }.disabled(busy || !state.fresh || !valid)
                        }
                    }
                }
                if let build, valid {
                    SoftGroupRow("build") {
                        NavigationLink("查看本次构建") { WorkflowRunsView(api: api, repo: build.repo, branch: build.branch, headSHA: build.sha) }
                            .disabled(busy)
                    }
                }
            }
        }.transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private func historySection(_ snapshot: LocalGitSnapshot) -> some View {
        let key = historyIdentity(snapshot)
        let commits = snapshot.history.commits + (historyPageKey == key ? historyPages : [])
        return Section {
            SoftGroupRows(animateBackground: false) {
                SoftGroupRow("disclosure") {
                    Button {
                        UIRules.withoutAnimation { historyExpanded.toggle() }
                    } label: {
                        HStack { Label("本地提交历史", systemImage: "clock.arrow.circlepath"); Spacer(); Text(snapshot.history.totalCount.map { String($0) } ?? "总数未知").foregroundStyle(.secondary); Image(systemName: historyExpanded ? "chevron.up" : "chevron.down").font(.caption) }
                    }.buttonStyle(.plain).accessibilityValue(historyExpanded ? "已展开" : "已折叠")
                }
                if historyExpanded {
                    SoftGroupRow("history-scope") {
                        Text(snapshot.history.shallow == true ? "浅克隆：仅统计当前 HEAD 可达且本地已有的提交。" : "仅统计当前 HEAD 可达的本地提交。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    for commit in commits {
                        SoftGroupRow(commit.id) {
                            NavigationLink {
                                LocalProjectCommitView(project: project, metadata: store.metadata(project), internalRoot: store.internalRoot, sha: commit.sha)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(commit.message).font(.subheadline.weight(.medium)).lineLimit(2)
                                    Text(commit.author + " · " + String(commit.sha.prefix(7))).font(.caption).foregroundStyle(.secondary)
                                    Text(LocalGitDate.string(commit.time)).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                    if let total = snapshot.history.totalCount, commits.count < total {
                        SoftGroupRow("history-more") {
                            if historyTask != nil {
                                HStack { ProgressView("读取历史…"); Spacer(); Button("取消") { resetHistoryPages() } }
                            } else {
                                Button("加载更多（已显示 \(commits.count) / \(total)）") { loadMoreHistory(snapshot) }
                                    .disabled(busy || !state.fresh || !valid)
                            }
                        }
                    }
                    if !historyError.isEmpty {
                        SoftGroupRow("history-error") { Text(historyError).font(.caption).foregroundStyle(.red) }
                    }
                    SoftGroupRow("collapse") {
                        Button("收起提交记录") {
                            UIRules.withoutAnimation { historyExpanded = false }
                        }
                    }
                }
            }
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .onChange(of: key) { _ in resetHistoryPages() }
        .onChange(of: historyExpanded) { expanded in if !expanded { resetHistoryPages() } }
        .onChange(of: busy) { value in if value { resetHistoryPages() } }
    }
    private func historyIdentity(_ snapshot: LocalGitSnapshot) -> String {
        [generation.uuidString, accountID, project.id.uuidString, project.identity,
         snapshot.status.head, snapshot.status.reference].joined(separator: "|")
    }
    private func resetHistoryPages() {
        historyTask?.cancel()
        historyTask = nil
        historyRequestID = nil
        historyPages = []
        historyPageKey = ""
        historyError = ""
    }
    private func loadMoreHistory(_ snapshot: LocalGitSnapshot) {
        guard valid, !busy, state.fresh, historyTask == nil,
              let total = snapshot.history.totalCount else { return }
        let key = historyIdentity(snapshot)
        if historyPageKey != key { resetHistoryPages(); historyPageKey = key }
        let offset = snapshot.history.commits.count + historyPages.count
        guard offset < total else { return }
        let requestID = UUID()
        historyRequestID = requestID
        historyError = ""
        historyTask = Task {
            defer {
                if historyRequestID == requestID { historyTask = nil; historyRequestID = nil }
            }
            do {
                let page: LocalGitHistory = try await LocalGitEngine.shared.run("history", project: project,
                    metadata: store.metadata(project), internalRoot: store.internalRoot,
                    arguments: ["expectedHead": snapshot.status.head, "expectedRef": snapshot.status.reference,
                                "offset": offset, "limit": 30], generation: generation)
                try Task.checkCancellation()
                guard valid, !busy, state.fresh, historyRequestID == requestID,
                      let current = state.snapshot, historyIdentity(current) == key else { return }
                guard page.head == snapshot.status.head, page.reference == snapshot.status.reference,
                      page.totalCount == total, page.offset == offset,
                      page.commits.count == min(30, total - offset),
                      Set((snapshot.history.commits + historyPages + page.commits).map(\.sha)).count == offset + page.commits.count else {
                    throw LocalGitError(text: "本地历史已变化或分页不完整，请下拉刷新后重试。")
                }
                historyPages.append(contentsOf: page.commits)
            } catch is CancellationError {
                // The next snapshot owns the history after cancellation.
            } catch {
                guard valid, historyRequestID == requestID,
                      let current = state.snapshot, historyIdentity(current) == key else { return }
                historyPages = []
                historyError = "读取更多本地历史失败：" + error.localizedDescription
            }
        }
    }
    private func snapshot() async throws -> LocalGitSnapshot {
        resetHistoryPages()
        guard valid else { throw CancellationError() }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { throw LocalGitError(text:"设备当前温度较高，已暂停 Git 检查；降温后可手动重试。") }
        let status:LocalGitStatus = try await LocalGitEngine.shared.run("status",project:project,metadata:store.metadata(project),internalRoot:store.internalRoot,generation:generation)
        let history:LocalGitHistory = try await LocalGitEngine.shared.run("history",project:project,metadata:store.metadata(project),internalRoot:store.internalRoot,
            arguments:["expectedHead":status.head,"expectedRef":status.reference],generation:generation)
        let files = status.files
        fileSizes = try await LocalGitEngine.shared.file(project: project, internalRoot: store.internalRoot, generation: generation) { root in
            var sizes: [String: Int64] = [:]
            for file in files where file.kind != "deleted" {
                if let url = try? LocalGitFileAccess.path(root: root, relative: file.path),
                   let info = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = info[.size] as? NSNumber { sizes[file.path] = size.int64Value }
            }
            return sizes
        }
        return LocalGitSnapshot(status:status,history:history)
    }
    private func refreshExternalChanges() {
        guard externalRefreshPending, visible, scenePhase == .active, !busy, sheet == nil,
              !pendingCommit, syncing == nil, valid else { return }
        externalRefreshPending = false
        state.filesChanged()
        Task { await check(force: true) }
    }
    private func check(force:Bool=false) async {
        guard !importer.busy else { return }
        await state.check(force:force,valid:{valid}) { try await snapshot() }
        if force, state.fresh, state.error.isEmpty { note = "检查完成，已显示当前文件变化。" }
    }
    private func imported(_ paths: [String]) {
        guard valid else { return }
        state.filesChanged()
        Task {
            await check(force: true)
            guard valid, let snapshot = state.snapshot else { return }
            let eligible = Set(snapshot.status.files.filter { $0.blocked.isEmpty }.map(\.path))
            state.selected.formUnion(Set(paths).intersection(eligible))
        }
    }
    private func finishCommit() {
        guard pendingCommit,valid,let current=state.snapshot else{return};pendingCommit=false
        let files=selected.map { ["path":$0.path,"fingerprint":$0.fingerprint] }
        Task { await state.check(force:true,valid:{valid}) {
            let _:LocalGitReply = try await LocalGitEngine.shared.run("commit",project:project,metadata:store.metadata(project),internalRoot:store.internalRoot,
                arguments:["expectedHead":current.status.head,"expectedRef":current.status.reference,"files":files,"message":commitMessage,"authorName":authorName,"authorEmail":authorEmail],generation:generation)
            note="本地提交已创建，可单独推送。"; return try await snapshot()
        } }
    }
    private func sync(_ action:String, runWorkflow: Bool = false) {
        guard valid,!busy,let current=state.snapshot else{return}
        let token=CredentialStore.read(account:accountID)
        Task {
            var workflow: LocalProjectSheet?
            await state.check(force:true,valid:{valid}) {
            note = ""
            if action == "push" { build = nil }
            if action == "pull" { pullSummary = nil; pullFilesExpanded = false }
            let reply:LocalGitReply = try await LocalGitEngine.shared.run(action,project:project,metadata:store.metadata(project),internalRoot:store.internalRoot,
                arguments:["expectedHead":current.status.head,"expectedRef":current.status.reference,"expectedRemote":current.history.remote,"token":token],generation:generation)
            try Task.checkCancellation(); guard valid else { throw CancellationError() }
            if action == "pull" { pullSummary = reply.pullSummary }
            if action == "push", let repository = try? RepositoryInput.parse(current.history.remote) {
                build = (repo: repository, branch: current.status.branch, sha: current.status.head)
                if runWorkflow { workflow = .workflow(repo: repository, branch: current.status.branch) }
            }
            note=action == "recover" ? "恢复完成，文件和历史已重新检查。" : (action == "push" ? "推送完成。" : "拉取完成。");return try await snapshot()
            }
            guard valid, !Task.isCancelled, state.fresh, state.error.isEmpty, !state.busy else { return }
            if let workflow { sheet = workflow }
        }
    }
}

struct LocalProjectDiffView:View {
    let project:LocalGitProject;let metadata:URL;let internalRoot:URL;let path:String;let head:String
    var beforeSHA: String? = nil
    var afterSHA: String? = nil
    var isValid: () -> Bool = { true }
    @State private var diffTask: Task<LocalGitDiff, Error>?
    @State private var visible = false
    private var pinned: Bool { beforeSHA != nil && afterSHA != nil }
    @Environment(\.dismiss) private var dismiss
    @StateObject private var request = RepositoryPageLoadState<LocalGitDiff>()
    @State private var generation = AccountStore.generation
    private var diff: LocalGitDiff? { request.value }
    private var failure: String { request.error }
    var body:some View {
        NavigationStack {
            Group {
                if let diff {
                    VStack(spacing: 0) {
                        if pinned {
                            Text("本次拉取前 → 拉取后（不包含后续工作区修改）").font(.caption).foregroundStyle(.secondary).padding(8)
                            Text(String((beforeSHA ?? "").prefix(12)) + " → " + String((afterSHA ?? "").prefix(12)))
                                .font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if diff.truncated { Text("文件或差异超过 256 KiB 预览限制，未完整展示；请使用桌面 Git 查看。").font(.caption).foregroundStyle(.secondary).padding() }
                        else if diff.binary { Text("二进制或非 UTF-8 文件已变化，无法展示文本差异。").font(.caption).foregroundStyle(.secondary).padding() }
                        CommitPatchView(file: DesktopCommit.File(filename: path, previous_filename: diff.previousFilename, status: diff.status ?? "modified", additions: diff.additions ?? 0, deletions: diff.deletions ?? 0, patch: diff.binary || diff.truncated ? nil : diff.text), workingTree: !pinned, comparisonLabel: pinned ? "显示本次拉取前后的文件变化" : nil)
                    }
                } else if failure.isEmpty { ProgressView("读取文件差异…") }
                else { VStack { Text(failure).foregroundStyle(.secondary); Button("重试") { Task { await load(refresh: true) } } }.padding() }
            }
                .navigationTitle((path as NSString).lastPathComponent).toolbar { Button("关闭"){dismiss()} }
                .task { visible = true; await load() }
                .onDisappear { visible = false; diffTask?.cancel() }
        }
    }
    private func load(refresh: Bool = false) async {
        let arguments: [String: Any]
        if let beforeSHA, let afterSHA { arguments = ["path":path,"beforeSHA":beforeSHA,"afterSHA":afterSHA] }
        else { arguments = ["path":path,"expectedHead":head] }
        await request.load(key: project.id.uuidString + ":" + path + ":" + (beforeSHA ?? head) + ":" + (afterSHA ?? "") + ":" + generation.uuidString, refresh: refresh,
            operation: {
                guard visible, isValid() else { throw CancellationError() }
                let task = Task<LocalGitDiff, Error> {
                    try await LocalGitEngine.shared.run(pinned ? "pullDiff" : "diff", project: project, metadata: metadata,
                                                       internalRoot: internalRoot, arguments: arguments, generation: generation)
                }
                diffTask = task
                defer { diffTask = nil }
                return try await task.value
            },
            isValid: { visible && generation == AccountStore.generation && isValid() })
    }
}
