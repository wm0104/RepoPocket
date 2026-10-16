import SwiftUI

struct LocalProjectImportView: View {
    @ObservedObject var api: GitHub
    @ObservedObject var store: LocalGitRegistry
    @Environment(\.dismiss) private var dismiss
    @State private var clone = false
    @State private var folder: LocalGitProject?
    @State private var picker: WorkspaceImportRequest?
    @State private var remote = ""
    @State private var branch = "main"
    @State private var revision = ""
    @State private var childName = ""
    @State private var preview: LocalGitStatus?
    @State private var busy = false
    @State private var message = ""
    @State private var job: Task<Void, Never>?
    @State private var generation = AccountStore.generation
    private var folderButtonTitle: String {
        if folder != nil { return "重新选择文件夹" }
        return clone ? "选择保存位置" : "选择原文件夹"
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("克隆到新子文件夹", isOn: $clone)
                    Button(folderButtonTitle) { picker = WorkspaceImportRequest(kind: .folder) }
                    if let folder { Label("已选：" + folder.name, systemImage: "folder").foregroundStyle(.secondary) }
                    if clone { Text("选择存放仓库的文件夹，克隆时会在里面新建子文件夹。").font(.caption).foregroundStyle(.secondary) }
                }.disabled(busy || preview != nil)
                if let folder {
                    if clone || folder.usesPrivateGit {
                        Section("GitHub 仓库") {
                            Text("当前账号：" + api.login).font(.caption)
                            TextField("owner/repository", text: $remote).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("分支", text: $branch).textInputAutocapitalization(.never).autocorrectionDisabled()
                            if clone { TextField("新子文件夹名称", text: $childName) }
                            else { TextField("已知基准 SHA（留空使用当前远端提交）", text: $revision).textInputAutocapitalization(.never).autocorrectionDisabled() }
                        }.disabled(busy || preview != nil)
                    }
                    if let preview {
                        Section("确认关联") {
                            Text("分支：" + preview.branch)
                            Text("基准：" + preview.head).font(.caption).textSelection(.enabled)
                            Text("以下是原文件相对此基准的变化。ZIP 的下载时版本无法自动确认；删除和回退也会显示在这里。").font(.caption)
                            ForEach(preview.files) { row in Label(row.path + " · " + row.label, systemImage: row.kind == "deleted" ? "minus.circle" : "doc") }
                            if preview.files.isEmpty { Text("没有内容变化") }
                            if !preview.staged.isEmpty || preview.repoState != 0 { Text("已有暂存或未完成 Git 操作，请先在原工具处理。") }
                            Button("确认关联原目录") { do { try store.attach(folder); dismiss() } catch { message = error.localizedDescription } }.disabled(!preview.canCommit)
                        }
                    } else {
                        Section {
                            Button(clone ? "克隆到新子文件夹" : "检查并预览关联") { start() }
                        }.disabled(busy)
                    }
                }
                if busy { ProgressView("处理中，请保持前台…") }
                if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
                Text("不会复制原目录或覆盖现有文件。首次获取仓库需要网络；后续可离线检查和本地提交。").font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("添加本地项目")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { job?.cancel(); dismiss() } } }
            .sheet(item: $picker) { request in
                WorkspaceDocumentPicker(request: request, allowsMultipleSelection: false) { urls in
                    // Consume the delegate's URL while its grant is available.
                    // Files may dismiss itself without SwiftUI's onDismiss.
                    if let url = urls?.first { acceptPicker(url) }
                    picker = nil
                }.id(request.id)
            }
            .onDisappear { job?.cancel() }
        }
    }
    private func acceptPicker(_ url: URL) {
        do { folder = try store.prepare(url); preview = nil; message = "" }
        catch { message = error.localizedDescription }
    }
    private func start() {
        guard !busy, let folder else { return }
        busy = true; message = ""
        let metadata = store.metadata(folder), internalRoot = store.internalRoot
        job = Task { @MainActor in
            defer { busy = false }
            var associationFailed = false
            do {
                guard generation == AccountStore.generation, api.isCurrentSession else { throw CancellationError() }
                if clone {
                    let url = try LocalGitRules.remote(remote)
                    let new = try await LocalGitEngine.shared.clone(parent: folder, metadata: metadata, internalRoot: internalRoot,
                        name: childName, remote: url, branch: branch, token: CredentialStore.read(account: api.accountID), generation: generation)
                    try Task.checkCancellation(); guard generation == AccountStore.generation else { throw CancellationError() }
                    try store.attach(new); dismiss(); return
                }
                let exists = FileManager.default.fileExists(atPath: metadata.path)
                let value: LocalGitStatus
                if folder.usesPrivateGit && !exists {
                    let url = try LocalGitRules.remote(remote)
                    let name = String(url.dropFirst("https://github.com/".count).dropLast(4))
                    let baseline = revision.isEmpty ? try await api.workspaceHead(name, branch: branch) : revision
                    associationFailed = true
                    value = try await LocalGitEngine.shared.run("associate", project: folder, metadata: metadata, internalRoot: internalRoot,
                        arguments: ["remote":url,"branch":branch,"selectedCommit":baseline,"token":CredentialStore.read(account:api.accountID)], generation:generation)
                    associationFailed = false
                } else {
                    value = try await LocalGitEngine.shared.run("inspect", project:folder,metadata:metadata,internalRoot:internalRoot,generation:generation)
                }
                try Task.checkCancellation(); guard generation == AccountStore.generation else { throw CancellationError() }
                try store.retain(folder); preview = value
            } catch {
                if associationFailed {
                    // Keep the failed private metadata; retry in a fresh location.
                    self.folder = LocalGitProject(id:folder.id,name:folder.name,bookmark:folder.bookmark,
                        identity:folder.identity,metadataID:UUID(),usesPrivateGit:true)
                }
                if !(error is CancellationError) { message = error.localizedDescription }
            }
        }
    }
}
