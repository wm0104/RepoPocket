import SwiftUI

struct LocalProjectView: View {
    @ObservedObject var api: GitHub
    @ObservedObject var store: LocalGitRegistry
    let project: LocalGitProject
    @StateObject private var state = LocalProjectState()
    @StateObject private var importer = LocalGitImportState()
    @State private var expandedFolders = Set<String>()
    @State private var generation = AccountStore.generation
    @State private var accountID = AccountStore.activeID
    @State private var sheet: LocalProjectSheet?
    @State private var historyExpanded = false
    @State private var pendingCommit = false
    @State private var syncing: String?
    @State private var note = ""
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
            Button("确认") { guard let action = syncing else { return }; syncing = nil; sync(action) }
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
        return "账号：\(api.login)\n\(remote)\n分支：\(branch)"
    }
    private var projectList: some View {
        List {
            if let snapshot = state.snapshot {
                summarySection(snapshot)
                changesSection(snapshot)
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
                    if !importer.message.isEmpty { SoftGroupRow("import-result") { Text(importer.message).font(.caption).foregroundStyle(.secondary) } }
                    if !note.isEmpty { SoftGroupRow("note") { Text(note).font(.caption).foregroundStyle(.secondary) } }
                }
            }
        }.listStyle(.insetGrouped).navigationTitle(project.name).adaptiveWorkspaceLayout()
        .task { await check() }
        .refreshable { await check(force: true) }
        .toolbar { Menu {
            Button("导入文件") { importer.picker = WorkspaceImportRequest(kind: .files) }.disabled(busy)
            Button("导入文件夹") { importer.picker = WorkspaceImportRequest(kind: .folder) }.disabled(busy)
            Button("检查变化") { Task { await check(force: true) } }.disabled(busy)
        } label: { Image(systemName: "ellipsis.circle") } }
        .modifier(LocalGitImportPresentation(importer: importer, project: project, internalRoot: store.internalRoot,
                                              generation: generation, changed: imported))
        .onDisappear { state.cancel(); importer.cancel() }
    }
    private var projectSheets: some View {
        projectList
        .sheet(item: $sheet, onDismiss: finishCommit) { route in
            switch route {
            case .diff(let path): LocalProjectDiffView(project:project,metadata:store.metadata(project),internalRoot:store.internalRoot,
                                 path:path,head:state.snapshot?.status.head ?? "")
            case .commit: commitForm
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
        Section("当前分支") {
            SoftGroupRows {
                SoftGroupRow("branch") { Label(snapshot.status.branch, systemImage: "arrow.triangle.branch") }
                SoftGroupRow("head") { Text(String(snapshot.status.head.prefix(12))).font(.caption.monospaced()).textSelection(.enabled) }
                SoftGroupRow("tracking") {
                    if snapshot.history.tracking { Text("待推送 \(snapshot.history.ahead) · 远端领先 \(snapshot.history.behind)").font(.caption) }
                    else { Text("没有可比较的远端分支").font(.caption) }
                }
                if !snapshot.history.remote.isEmpty { SoftGroupRow("remote") { Text(snapshot.history.remote).font(.caption).textSelection(.enabled) } }
                SoftGroupRow("files") {
                    NavigationLink("浏览与编辑项目文件") { LocalProjectFilesView(project: project, internalRoot: store.internalRoot) {
                        state.filesChanged(); note = "文件已修改，正在检查变化。"
                        Task { await check(force: true) }
                    } }.disabled(busy)
                }
            }
        }
    }

    private func changesSection(_ snapshot: LocalGitSnapshot) -> some View {
        Section("工作区变化 · \(snapshot.status.files.count)") {
            SoftGroupRows(animateBackground: false) {
                if snapshot.status.files.isEmpty { SoftGroupRow("empty") { Text("没有内容变化") } }
                else {
                    SoftGroupRow("selection") {
                        HStack {
                            Button("全选") { state.selectAll() }.disabled(busy || snapshot.status.files.allSatisfy { !$0.blocked.isEmpty })
                            Spacer()
                            Text("已选 \(selected.count)").font(.caption).foregroundStyle(.secondary)
                            Button("取消全选") { state.selected.removeAll() }.disabled(busy || state.selected.isEmpty)
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
                    var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                    withTransaction(transaction) {
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name).lineLimit(2)
                        Text(file.blocked.isEmpty ? file.label : file.blocked).font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.borderless).disabled(busy)
            }
        }.padding(.leading, CGFloat(min(row.depth, 5)) * 16)
    }

    private func actionsSection(_ snapshot: LocalGitSnapshot) -> some View {
        Section {
            SoftGroupRows {
                SoftGroupRow("import-files") { Button("导入文件") { importer.picker = WorkspaceImportRequest(kind: .files) }.disabled(busy) }
                SoftGroupRow("import-folder") { Button("导入文件夹") { importer.picker = WorkspaceImportRequest(kind: .folder) }.disabled(busy) }
                if snapshot.status.repoState == 100 { SoftGroupRow("recover") { Button("检查并恢复中断操作") { syncing = "recover" }.disabled(busy) } }
                SoftGroupRow("commit") {
                    Button("创建本地提交（\(selected.count) 个文件）") { if authorName.isEmpty { authorName = api.login }; sheet = .commit }
                        .disabled(commitBlockedReason != nil)
                }
                if let reason = commitBlockedReason { SoftGroupRow("reason") { Text(reason).font(.caption).foregroundStyle(.secondary) } }
                SoftGroupRow("pull") { Button("拉取远端（仅快进）") { syncing = "pull" }.disabled(busy || !state.fresh || snapshot.history.remote.isEmpty) }
                SoftGroupRow("push") { Button("推送本地提交") { syncing = "push" }.disabled(busy || !state.fresh || snapshot.history.remote.isEmpty) }
            }
        }
    }

    private func historySection(_ snapshot: LocalGitSnapshot) -> some View {
        Section {
            SoftGroupRows(animateBackground: false) {
                SoftGroupRow("disclosure") {
                    Button {
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { historyExpanded.toggle() }
                    } label: {
                        HStack { Label("本地提交历史", systemImage: "clock.arrow.circlepath"); Spacer(); Text("\(snapshot.history.commits.count)").foregroundStyle(.secondary); Image(systemName: historyExpanded ? "chevron.up" : "chevron.down").font(.caption) }
                    }.buttonStyle(.plain).accessibilityValue(historyExpanded ? "已展开" : "已折叠")
                }
                if historyExpanded {
                    for commit in snapshot.history.commits {
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
                    SoftGroupRow("collapse") {
                        Button("收起提交记录") {
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { historyExpanded = false }
                        }
                    }
                }
            }
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
    private func snapshot() async throws -> LocalGitSnapshot {
        guard valid else { throw CancellationError() }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { throw LocalGitError(text:"设备当前温度较高，已暂停 Git 检查；降温后可手动重试。") }
        let status:LocalGitStatus = try await LocalGitEngine.shared.run("status",project:project,metadata:store.metadata(project),internalRoot:store.internalRoot,generation:generation)
        let history:LocalGitHistory = try await LocalGitEngine.shared.run("history",project:project,metadata:store.metadata(project),internalRoot:store.internalRoot,generation:generation)
        return LocalGitSnapshot(status:status,history:history)
    }
    private func check(force:Bool=false) async {
        guard !importer.busy else { return }
        await state.check(force:force,valid:{valid}) { try await snapshot() }
        if force, state.fresh, state.error.isEmpty { note = "检查完成，已显示当前文件变化。" }
    }
    private func imported() {
        guard valid else { return }
        state.filesChanged()
        Task { await check(force: true) }
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
    private func sync(_ action:String) {
        guard valid,let current=state.snapshot else{return}
        let token=CredentialStore.read(account:accountID)
        Task { await state.check(force:true,valid:{valid}) {
            let _:LocalGitReply = try await LocalGitEngine.shared.run(action,project:project,metadata:store.metadata(project),internalRoot:store.internalRoot,
                arguments:["expectedHead":current.status.head,"expectedRef":current.status.reference,"expectedRemote":current.history.remote,"token":token],generation:generation)
            note=action == "recover" ? "恢复完成，文件和历史已重新检查。" : (action == "push" ? "推送完成。" : "拉取完成。");return try await snapshot()
        } }
    }
}

struct LocalProjectDiffView:View {
    let project:LocalGitProject;let metadata:URL;let internalRoot:URL;let path:String;let head:String
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
                        if diff.truncated { Text("差异超过 256 KiB，未完整展示。").font(.caption).foregroundStyle(.secondary).padding() }
                        CommitPatchView(file: DesktopCommit.File(filename: path, previous_filename: nil, status: "modified", additions: 0, deletions: 0, patch: diff.binary ? nil : diff.text), workingTree: true)
                    }
                } else if failure.isEmpty { ProgressView("读取文件差异…") }
                else { VStack { Text(failure).foregroundStyle(.secondary); Button("重试") { Task { await load(refresh: true) } } }.padding() }
            }
                .navigationTitle((path as NSString).lastPathComponent).toolbar { Button("关闭"){dismiss()} }
                .task { await load() }
        }
    }
    private func load(refresh: Bool = false) async {
        await request.load(key: project.id.uuidString + ":" + path + ":" + head + ":" + generation.uuidString, refresh: refresh,
            operation: { try await LocalGitEngine.shared.run("diff", project: project, metadata: metadata, internalRoot: internalRoot, arguments: ["path":path,"expectedHead":head], generation: generation) },
            isValid: { generation == AccountStore.generation })
    }
}
