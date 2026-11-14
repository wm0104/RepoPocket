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
    @State private var authorExpanded = false
    private var authorIncomplete: Bool {
        authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            authorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var valid: Bool { generation == AccountStore.generation && api.isCurrentSession && store.projects.contains(where: { $0.id == project.id }) }
    private var selected: [LocalGitChange] { state.snapshot?.status.files.filter { state.selected.contains($0.path) && $0.blocked.isEmpty } ?? [] }
    private var busy: Bool { state.busy || importer.busy }
    private var showsProjectStatus: Bool { busy || !state.error.isEmpty || !note.isEmpty }
    private var commitBlockedReason: String? {
        if busy { return "正在核对或执行 Git 操作，请稍候。" }
        if !state.fresh { return "结果尚未核对，请下拉刷新后再提交。" }
        if state.snapshot?.status.mergePending == true { return "本地合并进行中，请从冲突解决入口逐文件解决并继续或中止。" }
        if state.snapshot?.status.staged.isEmpty == false { return "已有暂存内容，请进入「暂存与提交」面板核对、取消暂存或只提交暂存内容。" }
        if state.snapshot?.status.canCommit != true { return "已有冲突或未完成操作，请先完成冲突解决或安全恢复。" }
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
        if syncing == "fetch" { return "仅获取远端状态？" }
        return syncing == "push" ? "推送当前分支？" : "拉取远端当前分支？"
    }
    private var syncPresented: Binding<Bool> {
        Binding(get: { syncing != nil }, set: { if !$0 { syncing = nil } })
    }
    private var syncMessage: String {
        let remote = state.snapshot?.history.remote ?? ""
        let branch = state.snapshot?.status.branch ?? ""
        return "账号：\(api.login)\n\(remote)\n分支：\(branch)" + (syncing == "pull" ? "\n可快进则快进；分叉时执行本地合并。无冲突时使用已确认的本地作者生成提交；冲突时暂停并保存合并会话，须逐文件解决后明确继续或中止。不会自动推送。" : "") + (syncing == "push" ? "\n仅推送不会由 App 启动工作流；仓库配置的 push 或 PR 自动检查仍可能运行。" : "")
    }
    private var projectList: some View {
        List {
            if state.snapshot != nil || importer.busy || !importer.message.isEmpty || showsProjectStatus {
                Section {
                    if importer.busy || !importer.message.isEmpty {
                        SoftGroupRows {
                            if importer.busy { SoftGroupRow("import-progress") { ProgressView("正在导入整个选择，请保持前台…") } }
                            if !importer.message.isEmpty { SoftGroupRow("import-summary") { Text(importer.message).font(.caption).textSelection(.enabled) } }
                        }
                    }
                    if let snapshot = state.snapshot {
                        summarySection(snapshot)
                        if let pullSummary { pullResultSection(pullSummary) }
                        if snapshot.status.mergePending == true {
                            SoftGroupRows(spacingBefore: 10) {
                                SoftGroupRow("conflict-title") { Text("未完成的本地合并 · 优先处理").font(.caption).foregroundStyle(.secondary) }
                                SoftGroupRow("conflicts") {
                                    NavigationLink("检查冲突进度 / 继续 / 安全中止…") {
                                        LocalGitConflictView(project: project, metadata: store.metadata(project), internalRoot: store.internalRoot,
                                            generation: generation, isValid: { valid }) {
                                            state.filesChanged(); state.selected.removeAll(); resetHistoryPages(); build = nil; pullSummary = nil
                                        }
                                    }.disabled(busy || !valid).accessibilityIdentifier("localgit.conflict-session")
                                }
                                SoftGroupRow("conflict-info") { Text("合并暂存区由此会话管理；不要使用普通提交或暂存操作。退出后可从这里恢复，完成后不会自动推送。").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if !snapshot.status.files.isEmpty || !snapshot.status.canCommit { changesSection(snapshot) }
                        actionsSection(snapshot)
                        historySection(snapshot)
                    }
                    if showsProjectStatus {
                        SoftGroupRows(spacingBefore: state.snapshot == nil && !importer.busy && importer.message.isEmpty ? 0 : 10) {
                            if busy {
                                SoftGroupRow("busy") { ProgressView("Git 操作中…") }
                                SoftGroupRow("cancel") { Button("取消等待") { state.cancel(); importer.cancel(); note = "已取消等待。写入可能已完成，请下拉检查真实状态后再操作。" } }
                            }
                            if !state.error.isEmpty { SoftGroupRow("error") { Text(state.error).font(.caption).foregroundStyle(.red) } }
                            if !note.isEmpty { SoftGroupRow("note") { Text(note).font(.caption).foregroundStyle(.secondary) } }
                        }
                    }
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
        .toolbar {
            NativeActionMenu(title: "项目操作", accessibilityIdentifier: "localgit.project-actions", enabled: valid && !busy, items: [
                NativeMenuItem(id: "check", title: "检查变化", symbol: "arrow.clockwise", perform: { guard valid, !busy else { return }; Task { await check(force: true) } }),
                .submenu("添加到根目录", symbol: "plus", children: LocalGitAddAction.items { action in
                    guard valid, !busy else { return }
                    switch action {
                    case .newFile, .newFolder: sheet = .files(action)
                    case .importFiles: importer.picker = WorkspaceImportRequest(kind: .files)
                    case .importFolder: importer.picker = WorkspaceImportRequest(kind: .folder)
                    }
                }),
                NativeMenuItem(id: "info", title: "项目信息", symbol: "info.circle", enabled: state.snapshot != nil, perform: { guard valid, !busy, state.snapshot != nil else { return }; sheet = .info })
            ])
        }
        .modifier(LocalGitImportPresentation(importer: importer, project: project, internalRoot: store.internalRoot,
                                              directory: "", generation: generation, changed: imported))
        .onDisappear { visible = false; state.cancel(); importer.cancel(); resetHistoryPages() }
    }
    private var projectSheets: some View {
        projectList
        .sheet(item: $sheet, onDismiss: finishCommit) { route in
            switch route {
            case .diff(let path): LocalProjectDiffView(project:project,metadata:store.metadata(project),internalRoot:store.internalRoot,
                                 path:path,head:state.snapshot?.status.head ?? "")
            case .commit: commitForm
            case .files(let action):
                AppNavigationStack {
                    LocalProjectFilesView(api: api, project: project, internalRoot: store.internalRoot, imported: imported, initialAction: action) { state.filesChanged() }
                        .toolbar { Button("关闭") { sheet = nil } }
                }.appSheetCornerRadius()
            case .info:
                AppNavigationStack {
                    List {
                        if let snapshot = state.snapshot {
                            Section { SoftGroupRows {
                                SoftGroupRow("branch") { AppLabeledContent("当前分支", value: snapshot.status.branch) }
                                SoftGroupRow("head") { Text(snapshot.status.head).font(.caption.monospaced()).textSelection(.enabled) }
                                SoftGroupRow("remote") { Text(snapshot.history.remoteIssue ?? (snapshot.history.remote.isEmpty ? "未配置远端仓库" : snapshot.history.remote)).font(.caption).textSelection(.enabled) }
                            } }
                        }
                    }.navigationTitle("项目信息").adaptiveWorkspaceLayout().toolbar { Button("关闭") { sheet = nil } }
                }.appSheetCornerRadius()
            case .deb(let path): LocalProjectDebEditor(api: api, project: project, internalRoot: store.internalRoot, path: path) { imported([path]) }
            case .delete(let path): LocalProjectEditor(project: project, internalRoot: store.internalRoot, path: path, deleting: true) { imported([path]) }
            case .workflow(let repo, let branch):
                AppNavigationStack {
                    WorkflowDispatchView(api: api, repo: repo, initialBranch: branch) { ref in
                        note = "GitHub 已接受工作流启动请求，分支：" + ref + "。请到 Actions 查看运行结果。"
                    }
                }.appSheetCornerRadius()
            }
        }
    }
    private var commitForm: some View {
        AppNavigationStack {
                Form {
                    Section {
                        SoftGroupRows {
                            SoftGroupRow("branch-title") { Text("提交到本地分支：" + (state.snapshot?.status.branch ?? "")).font(.caption).foregroundStyle(.secondary) }
                            SoftGroupRow("message") { TextField("提交说明", text: $commitMessage) }
                            SoftGroupRow("author-summary") {
                                Button {
                                    UIRules.withoutAnimation { authorExpanded.toggle() }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("作者信息")
                                            Text(authorIncomplete ? "请补全作者姓名与邮箱" : authorName + " · " + authorEmail).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: authorExpanded || authorIncomplete ? "chevron.up" : "chevron.down").font(.caption)
                                    }
                                }.accessibilityValue(authorExpanded || authorIncomplete ? "已展开" : "已折叠")
                            }
                            if authorExpanded || authorIncomplete {
                                SoftGroupRow("author-name") { TextField("作者姓名", text: $authorName) }
                                SoftGroupRow("author-email") { TextField("作者邮箱（由你确认）", text: $authorEmail).textInputAutocapitalization(.never).autocorrectionDisabled() }
                            }
                            SoftGroupRow("selected-title") { Text("本次选中文件").font(.caption).foregroundStyle(.secondary) }
                            for row in selected {
                                SoftGroupRow("selected-" + row.path) { Text(row.path + " · " + row.label) }
                            }
                            SoftGroupRow("help") { Text("这里只创建本地提交，稍后可单独推送。未勾选文件保持原状。").font(.caption) }
                            SoftGroupRow("confirm") {
                                Button("确认创建本地提交") { pendingCommit = true; sheet = nil }
                                    .disabled(commitMessage.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || authorIncomplete)
                            }
                        }
                    }
                }.navigationTitle("确认本地提交").adaptiveWorkspaceLayout().toolbar { Button("取消") { sheet = nil } }
                .onAppear { authorExpanded = authorIncomplete }
        }
    }
    private func summarySection(_ snapshot: LocalGitSnapshot) -> some View {
        Group {
            SoftGroupRows(animateBackground: false, spacingBefore: importer.busy || !importer.message.isEmpty ? 10 : 0) {
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
                        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.disabled(busy || !state.fresh || !valid)
                        .accessibilityIdentifier("localgit.branches").accessibilityHint("管理、创建或切换本地分支")
                }
                SoftGroupRow("files") {
                    NavigationLink {
                        LocalProjectFilesView(api: api, project: project, internalRoot: store.internalRoot, imported: imported) {
                            state.filesChanged(); note = "文件已修改，正在检查变化。"
                            Task { await check(force: true) }
                        }
                    } label: {
                        Text("浏览与编辑项目文件").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.disabled(busy)
                }
                if snapshot.status.files.isEmpty && snapshot.status.canCommit { SoftGroupRow("clean") { Text("工作区干净").font(.caption).foregroundStyle(.secondary) } }
            }
        }
    }

    private func pullResultSection(_ summary: LocalGitPullSummary) -> some View {
        Group {
            SoftGroupRows(animateBackground: false, spacingBefore: 10) {
                SoftGroupRow("pull-title") { Text("本次拉取结果").font(.caption).foregroundStyle(.secondary) }
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
        Group {
            SoftGroupRows(animateBackground: false, spacingBefore: 10) {
                SoftGroupRow("changes-title") { Text("工作区变化 · \(snapshot.status.files.count)").font(.caption).foregroundStyle(.secondary) }
                if snapshot.status.files.isEmpty { SoftGroupRow("empty") { Text("没有内容变化") } }
                else {
                    SoftGroupRow("selection") {
                        HStack {
                            let paths = Set(snapshot.status.files.filter { $0.blocked.isEmpty }.map(\.path))
                            Button { state.toggleSelection(paths) } label: {
                                Text(!paths.isEmpty && paths.isSubset(of: state.selected) ? "取消全选" : "全选")
                                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                            }.disabled(busy || paths.isEmpty)
                            Spacer()
                            Text("已选 \(selected.count)").font(.caption).foregroundStyle(.secondary)
                        }.buttonStyle(.borderless)
                    }
                    for row in LocalGitChangeTree.rows(snapshot.status.files, expanded: expandedFolders) {
                        SoftGroupRow(row.id) { changeRow(row) }
                    }
                }
                if !snapshot.status.canCommit { SoftGroupRow("blocked") { Text(snapshot.status.mergePending == true ? "合并会话管理此暂存区，请进入冲突解决页继续或中止，不要使用普通暂存/提交。" : (!snapshot.status.staged.isEmpty && snapshot.status.repoState == 0 ? "已有暂存内容，请从下方「暂存与提交」进入同一面板核对已暂存与未暂存变化。" : "存在冲突或未完成操作，请先完成冲突解决或安全恢复；不会撤销原暂存。")).foregroundStyle(.red).font(.caption) } }
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
                    }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.borderless).disabled(busy).accessibilityIdentifier("localgit.folder." + row.path)
                    .accessibilityValue(expandedFolders.contains(row.path) ? "已展开" : "已折叠")
            } else if let file = row.files.first {
                Button { sheet = .diff(file.path) } label: {
                    LocalGitFileLabel(name: row.name, size: fileSizes[file.path], detail: file.blocked.isEmpty ? file.label : file.blocked)
                }.buttonStyle(.borderless).disabled(busy)
                if row.name.lowercased().hasSuffix(".deb"), file.kind != "deleted" {
                    Menu {
                        Button("编辑包信息") { sheet = .deb(file.path) }
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
        Group {
            SoftGroupRows(animateBackground: false, spacingBefore: 10) {
                if snapshot.status.repoState == 100 && snapshot.status.mergePending != true { SoftGroupRow("recover") { Button("检查并恢复中断操作") { syncing = "recover" }.disabled(busy) } }
                SoftGroupRow("stage") {
                    NavigationLink {
                        LocalGitStageView(api: api, project: project, metadata: store.metadata(project),
                            internalRoot: store.internalRoot, generation: generation, isValid: { valid },
                            changed: {
                                state.filesChanged(); state.selected.removeAll(); resetHistoryPages()
                                build = nil; pullSummary = nil
                            }, message: $commitMessage)
                    } label: {
                        Label("暂存与提交…", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(busy || !state.fresh || !valid || snapshot.status.repoState != 0 || snapshot.status.mergePending == true)
                    .accessibilityIdentifier("localgit.stage-panel")
                }
                if !snapshot.status.files.isEmpty && snapshot.status.staged.isEmpty {
                    SoftGroupRow("commit") {
                        Button("创建本地提交（\(selected.count) 个文件）") { if authorName.isEmpty { authorName = api.login }; sheet = .commit }
                            .disabled(commitBlockedReason != nil)
                    }
                    if let reason = commitBlockedReason { SoftGroupRow("reason") { Text(reason).font(.caption).foregroundStyle(.secondary) } }
                }
            }
            SoftGroupRows(animateBackground: false, spacingBefore: 10) {
                SoftGroupRow("sync-fetch") {
                    Button { syncing = "fetch" } label: {
                        HStack {
                            Label("获取", systemImage: "arrow.clockwise")
                            Spacer()
                            Text("仅更新远端状态").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.accessibilityLabel("获取远端状态，不修改工作文件")
                        .disabled(busy || !state.fresh || snapshot.history.remote.isEmpty)
                }
                SoftGroupRow("sync-pull") {
                    Button { syncing = "pull" } label: {
                        HStack {
                            Label("拉取", systemImage: "arrow.down")
                            Spacer()
                            Text("分叉时开始本地合并").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.accessibilityLabel("拉取远端，分叉时开始本地合并")
                        .disabled(busy || !state.fresh || snapshot.history.remote.isEmpty)
                }
                SoftGroupRow("sync-push") {
                    Button { syncing = "push" } label: {
                        HStack {
                            Label("推送", systemImage: "arrow.up")
                            Spacer()
                            Text("上传本地提交").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.accessibilityLabel("推送本地提交")
                        .disabled(busy || !state.fresh || snapshot.history.remote.isEmpty)
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
                        }
                    }
                    if snapshot.history.remoteMissing == true {
                        SoftGroupRow("configure-remote") {
                            NavigationLink("关联 GitHub 仓库…") {
                                LocalProjectRemoteView(api: api, project: project, metadata: store.metadata(project), internalRoot: store.internalRoot,
                                    status: snapshot.status, generation: generation, isValid: { valid }) {
                                    state.filesChanged()
                                    Task { await check(force: true) }
                                }
                            }.disabled(busy || !state.fresh || !valid)
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
        return Group {
            SoftGroupRows(animateBackground: false, spacingBefore: 10) {
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
                                LocalProjectCommitView(project: project, metadata: store.metadata(project), internalRoot: store.internalRoot, sha: commit.sha,
                                    workspace: LocalGitHistoryContext(api: api, status: snapshot.status, remote: snapshot.history.remote, generation: generation, isValid: { valid }) {
                                        state.filesChanged(); state.selected.removeAll(); resetHistoryPages()
                                        build = nil; pullSummary = nil
                                    })
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
                arguments:["expectedHead":current.status.head,"expectedRef":current.status.reference,"expectedRemote":current.history.remote,"token":token,
                           "authorName":authorName,"authorEmail":authorEmail,"message":"Merge origin into " + current.status.branch],generation:generation)
            try Task.checkCancellation(); guard valid else { throw CancellationError() }
            if action == "pull" { pullSummary = reply.pullSummary }
            if action == "push", let repository = try? RepositoryInput.parse(current.history.remote) {
                build = (repo: repository, branch: current.status.branch, sha: current.status.head)
                if runWorkflow { workflow = .workflow(repo: repository, branch: current.status.branch) }
            }
            note = reply.mergePending == true ? "拉取发现分叉冲突；真实合并会话已保存，请从冲突入口逐文件解决，再明确继续或安全中止。工作文件尚未修改，没有推送。" : (action == "recover" ? "恢复完成，文件和历史已重新检查。" : (action == "push" ? "推送完成。" : (action == "fetch" ? "获取完成，未修改工作文件或自动拉取/推送。" : "拉取完成。")));return try await snapshot()
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
        AppNavigationStack {
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
