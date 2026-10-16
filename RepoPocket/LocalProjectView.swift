import SwiftUI

struct LocalProjectView: View {
    @ObservedObject var api: GitHub
    @ObservedObject var store: LocalGitRegistry
    let project: LocalGitProject
    @StateObject private var state = LocalProjectState()
    @State private var generation = AccountStore.generation
    @State private var accountID = AccountStore.activeID
    @State private var diffFile: LocalProjectFile?
    @State private var commitSheet = false
    @State private var pendingCommit = false
    @State private var syncing: String?
    @State private var note = ""
    @AppStorage("localGit.authorName") private var authorName = ""
    @AppStorage("localGit.authorEmail") private var authorEmail = ""
    @State private var commitMessage = ""
    private var valid: Bool { generation == AccountStore.generation && api.isCurrentSession && store.projects.contains(where: { $0.id == project.id }) }
    private var selected: [LocalGitChange] { state.snapshot?.status.files.filter { state.selected.contains($0.path) } ?? [] }
    var body: some View {
        List {
            if let snapshot = state.snapshot {
                Section("当前分支") {
                    Text(snapshot.status.branch)
                    Text(String(snapshot.status.head.prefix(12))).font(.caption.monospaced()).textSelection(.enabled)
                    if snapshot.history.tracking { Text("待推送 \(snapshot.history.ahead) · 远端领先 \(snapshot.history.behind)").font(.caption) }
                    else { Text("没有可比较的远端分支").font(.caption) }
                    if !snapshot.history.remote.isEmpty { Text(snapshot.history.remote).font(.caption).textSelection(.enabled) }
                    NavigationLink("浏览与编辑项目文件") { LocalProjectFilesView(project: project, internalRoot: store.internalRoot) { note = "文件已修改，请检查变化。" } }
                }
                Section("工作区变化 · \(snapshot.status.files.count)") {
                    if snapshot.status.files.isEmpty { Text("没有内容变化") }
                    ForEach(snapshot.status.files) { row in
                        HStack {
                            Button {
                                if state.selected.contains(row.path) { state.selected.remove(row.path) } else { state.selected.insert(row.path) }
                            } label: { Image(systemName: state.selected.contains(row.path) ? "checkmark.square.fill" : "square").frame(width: 44,height: 44) }
                                .buttonStyle(.borderless).disabled(state.busy || !row.blocked.isEmpty)
                            Button { diffFile = LocalProjectFile(path: row.path) } label: {
                                VStack(alignment: .leading,spacing: 4) {
                                    Text(row.path); Text(row.blocked.isEmpty ? row.label : row.blocked).font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.borderless).disabled(state.busy)
                        }
                    }
                    if !snapshot.status.canCommit { Text("已有暂存、冲突或未完成操作。请先在原工具处理，不会撤销原暂存。").foregroundStyle(.red).font(.caption) }
                }
                Section {
                    if snapshot.status.repoState == 100 { Button("检查并恢复中断操作") { syncing = "recover" }.disabled(state.busy) }
                    Button("创建本地提交（\(selected.count) 个文件）") { if authorName.isEmpty { authorName = api.login }; commitSheet = true }
                        .disabled(state.busy || !state.fresh || !snapshot.status.canCommit || selected.isEmpty)
                    Button("拉取远端（仅快进）") { syncing = "pull" }.disabled(state.busy || !state.fresh || snapshot.history.remote.isEmpty)
                    Button("推送本地提交") { syncing = "push" }.disabled(state.busy || !state.fresh || snapshot.history.remote.isEmpty)
                }
                Section("本地提交历史 · 最近 30 条") {
                    ForEach(snapshot.history.commits) { commit in
                        VStack(alignment: .leading,spacing: 4) {
                            Text(commit.message)
                            Text(String(commit.sha.prefix(7)) + " · " + commit.author).font(.caption).foregroundStyle(.secondary)
                            Text(Date(timeIntervalSince1970:commit.time).formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                if state.busy { ProgressView("Git 操作中…"); Button("取消等待") { state.cancel(); note = "已取消等待。写入可能已完成，请检查真实状态后再操作。" } }
                else { Button("检查变化") { Task { await check(force:true) } } }
                if !state.fresh && state.snapshot != nil { Text("当前结果未重新核对，请检查后再提交。").font(.caption).foregroundStyle(.secondary) }
                if !state.error.isEmpty { Text(state.error).font(.caption).foregroundStyle(.red) }
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        }.navigationTitle(project.name)
        .task { await check() }
        .onDisappear { state.cancel() }
        .sheet(item: $diffFile) { file in
            LocalProjectDiffView(project:project,metadata:store.metadata(project),internalRoot:store.internalRoot,
                                 path:file.path,head:state.snapshot?.status.head ?? "")
        }
        .sheet(isPresented:$commitSheet,onDismiss:finishCommit) {
            NavigationStack {
                Form {
                    Section("提交到本地分支：" + (state.snapshot?.status.branch ?? "")) {
                        TextField("提交说明",text:$commitMessage)
                        TextField("作者姓名",text:$authorName)
                        TextField("作者邮箱（由你确认）",text:$authorEmail).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Section("本次选中文件") { ForEach(selected) { Text($0.path + " · " + $0.label) } }
                    Text("这里只创建本地提交，稍后可单独推送。未勾选文件保持原状。").font(.caption)
                    Button("确认创建本地提交") { pendingCommit = true; commitSheet = false }
                        .disabled(commitMessage.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || authorName.isEmpty || authorEmail.isEmpty)
                }.navigationTitle("确认本地提交").toolbar { Button("取消") { commitSheet = false } }
            }
        }
        .confirmationDialog(syncing == "recover" ? "核对并继续中断操作？" : (syncing == "push" ? "推送当前分支？" : "拉取远端当前分支？"),isPresented:Binding(get:{syncing != nil},set:{if !$0 {syncing=nil}}),titleVisibility:.visible) {
            Button("确认") { guard let action=syncing else{return};syncing=nil;sync(action) }
        } message: { Text("账号：" + api.login + "\n" + (state.snapshot?.history.remote ?? "") + "\n分支：" + (state.snapshot?.status.branch ?? "")) }
    }
    private func snapshot() async throws -> LocalGitSnapshot {
        guard valid else { throw CancellationError() }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { throw LocalGitError(text:"设备当前温度较高，已暂停 Git 检查；降温后可手动重试。") }
        let status:LocalGitStatus = try await LocalGitEngine.shared.run("status",project:project,metadata:store.metadata(project),internalRoot:store.internalRoot,generation:generation)
        let history:LocalGitHistory = try await LocalGitEngine.shared.run("history",project:project,metadata:store.metadata(project),internalRoot:store.internalRoot,generation:generation)
        return LocalGitSnapshot(status:status,history:history)
    }
    private func check(force:Bool=false) async { await state.check(force:force,valid:{valid}) { try await snapshot() } }
    private func finishCommit() {
        guard pendingCommit,valid,let current=state.snapshot else{return};pendingCommit=false
        let files=selected.map { ["path":$0.path,"fingerprint":$0.fingerprint] }
        Task { await state.check(force:true,valid:{valid}) {
            let _:LocalGitReply = try await LocalGitEngine.shared.run("commit",project:project,metadata:store.metadata(project),internalRoot:store.internalRoot,
                arguments:["expectedHead":current.status.head,"files":files,"message":commitMessage,"authorName":authorName,"authorEmail":authorEmail],generation:generation)
            note="本地提交已创建，可单独推送。"; return try await snapshot()
        } }
    }
    private func sync(_ action:String) {
        guard valid,let current=state.snapshot else{return}
        let token=CredentialStore.read(account:accountID)
        Task { await state.check(force:true,valid:{valid}) {
            let _:LocalGitReply = try await LocalGitEngine.shared.run(action,project:project,metadata:store.metadata(project),internalRoot:store.internalRoot,
                arguments:["expectedHead":current.status.head,"expectedRemote":current.history.remote,"token":token],generation:generation)
            note=action == "recover" ? "恢复完成，文件和历史已重新检查。" : (action == "push" ? "推送完成。" : "拉取完成。");return try await snapshot()
        } }
    }
}

struct LocalProjectDiffView:View {
    let project:LocalGitProject;let metadata:URL;let internalRoot:URL;let path:String;let head:String
    @Environment(\.dismiss) private var dismiss
    @State private var text="";@State private var attempted=false
    var body:some View {
        NavigationStack {
            ScrollView { Text(text).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding() }
                .navigationTitle((path as NSString).lastPathComponent).toolbar { Button("关闭"){dismiss()} }
                .task {
                    guard !attempted else{return};attempted=true
                    do {
                        let diff:LocalGitDiff = try await LocalGitEngine.shared.run("diff",project:project,metadata:metadata,internalRoot:internalRoot,arguments:["path":path,"expectedHead":head])
                        text=diff.binary ? "二进制或较大文件，不显示文本差异。" : diff.text
                        if diff.truncated {text += "\n差异超过 256 KiB，未完整展示。"}
                    } catch {text=error.localizedDescription}
                }
        }
    }
}
