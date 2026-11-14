import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct UploadView: View {
    @ObservedObject var api: GitHub
    @Environment(\.dismiss) private var dismiss
    let directory: String
    let openedFromFolder: Bool
    let initialFile: URL?
    @State private var canWrite = false
    @State private var accessGeneration = UUID()
    @State private var showDebEditor = false
    @State private var editingQueueID: UUID?
    @State private var editorFile: URL?
    @State private var submitAfterDismiss = false
    @State private var initialFileLoaded = false
    @State private var alertText = ""
    @State private var mode = 0
    @State private var repo: String
    @State private var branch: String
    @State private var replacementPath: String?
    @State private var queue: [PendingRepoItem] = []
    @State private var choosingItem: UUID?
    @State private var choosingDelete = false
    @State private var confirmQueueDelete = false
    @State private var pendingDeletion: PendingRepoItem?
    @State private var targetPicker: RepositoryTarget?

    init(api: GitHub, initialRepo: String = "", directory: String = "", initialBranch: String = "", initialFile: URL? = nil, openedFromFolder: Bool = false) {
        self.api = api
        self.initialFile = initialFile
        self.directory = directory
        self.openedFromFolder = openedFromFolder
        _repo = State(initialValue: initialRepo)
        _branch = State(initialValue: initialBranch)
    }
    @State private var note = "Upload via RepoPocket"
    @State private var local: URL?
    @State private var bytes: Int64 = 0
    @State private var picking = false
    @State private var pickingInbox = false
    @State private var inboxSelection: [URL] = []
    @State private var busy = false
    @State private var confirmCommit = false
    @State private var confirmRelease = false
    @State private var makeNewRepo = false
    @State private var sharedReleaseEntry = false
    @State private var newName = ""
    @State private var isPrivate = false
    @State private var tag = "v1.0"
    @State private var title = ""
    @State private var release: Release?
    @State private var releaseRepo = ""
    @State private var asset: Asset?
    @State private var progress: Double = 0
    @State private var trollName = ""
    @State private var trollVersion = "1.0"
    @State private var trollDescription = ""
    @State private var trollBundleID = ""
    @State private var trollAuthor = ""
    @State private var trollPreview = false
    @State private var releases: [Release] = []
    @State private var downloadNotice = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("提交 / 发布方式", selection: $mode) {
                        Text("仓库提交").tag(0)
                        Text("发行版").tag(1)
                        Text("TrollFools").tag(2)
                    }.pickerStyle(.segmented).disabled(busy).softGroupedRow(top: true, bottom: true)
                }
                if mode != 1 { fileSection }
                if mode == 0 { commitSection } else if mode == 1 { releaseSection } else { trollSection }
                if busy { Section {
                    if progress > 0 { ProgressView(value: progress).tint(.accentColor).softGroupedRow(top: true) }
                    else { ProgressView("正在处理…").softGroupedRow(top: true) }
                    Label("请保持前台，勿锁屏。", systemImage: "iphone").font(.caption).foregroundColor(.secondary).softGroupedRow(bottom: true)
                } }
                if let r = release {
                    Section("已创建的发布") {
                        Text(releaseRepo + " · " + r.tag_name).softGroupedRow(top: true)
                        Text(r.draft ? "草稿（尚未公开）" : "已发布").softGroupedRow()
                        if let a = asset {
                            Text("附件：" + a.name).softGroupedRow()
                            Button("保存附件") { Task { await saveAsset(a, repo: releaseRepo) } }.disabled(busy).softGroupedRow()
                            if !downloadNotice.isEmpty { Text(downloadNotice).font(.caption).foregroundStyle(.secondary).softGroupedRow() }
                            if r.draft {
                                Button("公开此 Release") { Task { await publish() } }.disabled(busy).softGroupedRow()
                            } else if let url = URL(string: a.browser_download_url) {
                                ShareLink("分享下载链接", item: url).softGroupedRow()
                            }
                        }
                        if let url = URL(string: r.html_url) { Link("在 GitHub 查看", destination: url).softGroupedRow() }
                        Text("Release 附件不自动加入源索引。").font(.caption).softGroupedRow(bottom: true)
                    }
                }
            }
            .formStyle(.grouped)
            .adaptiveWorkspaceLayout()
            .navigationTitle("提交 / 发布")
            .scrollDismissesKeyboard(.never)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if openedFromFolder { Button("关闭") { dismiss() }.disabled(busy) }

            }
            .sheet(isPresented: $pickingInbox, onDismiss: {
                let files = inboxSelection; inboxSelection = []
                guard !files.isEmpty else { return }
                Task { await select(.success(files)); ShareSelectionCleanup.remove(files) }
            }) {
                ShareInboxView(multiple: mode == 0) { files in inboxSelection = files; pickingInbox = false }
            }
            .sheet(isPresented: $sharedReleaseEntry) { ReleaseEntryView(api: api, initialRepo: repo, initialBranch: branch) }
            .interactiveDismissDisabled(busy)
            .alert("提示", isPresented: Binding(get: { !alertText.isEmpty }, set: { if !$0 { alertText = "" } })) {
                Button("好", role: .cancel) { alertText = "" }
            } message: { Text(alertText) }
            .fileImporter(isPresented: $picking, allowedContentTypes: mode == 2 ? [UTType(filenameExtension: "dylib") ?? .data] : [.item], allowsMultipleSelection: mode == 0) { result in Task { await select(result) } }
            .sheet(isPresented: $confirmCommit, onDismiss: {
                if submitAfterDismiss { submitAfterDismiss = false; Task { await commit() } }
            }) {
                NavigationStack {
                    List {
                        Section("最终提交预览") {
                            LabeledContent("仓库", value: repo).softGroupedRow(top: true)
                            LabeledContent("分支", value: branch.isEmpty ? "默认分支（以已选目标 HEAD 校验）" : branch).softGroupedRow()
                            Text(note).softGroupedRow(bottom: queue.isEmpty)
                            ForEach(queue) { item in
                                VStack(alignment: .leading) {
                                    Text((item.local == nil ? "删除：" : item.sha == nil ? "新增：" : "替换：") + (item.path ?? "未选择"))
                                    if let sha = item.sha { Text("原 SHA：" + sha).font(.caption) }
                                }.softGroupedRow(bottom: item.id == queue.last?.id)
                            }
                        }
                        Button("确认提交以上全部项目") {
                            busy = true; progress = 0
                            submitAfterDismiss = true; confirmCommit = false
                        }.softGroupedRow(top: true, bottom: true)
                    }
                    .navigationTitle("确认原子提交")
                    .toolbar { Button("取消") { confirmCommit = false } }
                }.interactiveDismissDisabled(submitAfterDismiss)
            }
            .confirmationDialog(makeNewRepo ? "在你的账号下新建仓库 \(newName)，创建草稿 Release 并上传附件？" : "在 \(repo) 创建草稿 Release 并上传附件？", isPresented: $confirmRelease, titleVisibility: .visible) {
                Button("确认创建并上传") { Task { await createAndUpload() } }
            }
            .sheet(isPresented: $trollPreview) {
                NavigationStack {
                    Form {
                        LabeledContent("仓库", value: repo).softGroupedRow(top: true)
                        LabeledContent("分支", value: branch.isEmpty ? "默认分支" : branch).softGroupedRow()
                        LabeledContent("插件文件", value: "downloads/" + (local?.lastPathComponent ?? "")).softGroupedRow()
                        LabeledContent("名称", value: trollName).softGroupedRow()
                        LabeledContent("版本", value: trollVersion).softGroupedRow()
                        LabeledContent("描述", value: trollDescription.isEmpty ? trollName : trollDescription).softGroupedRow()
                        LabeledContent("Bundle ID", value: trollBundleID.isEmpty ? "未填写" : trollBundleID).softGroupedRow()
                        LabeledContent("作者", value: trollAuthor.isEmpty ? "未填写" : trollAuthor).softGroupedRow()
                        Text("一次 Git 提交同步插件与索引；保留其他条目和外链。").softGroupedRow(bottom: true)
                    }
                    .navigationTitle("TrollFools 发布预览")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { trollPreview = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("确认发布") { trollPreview = false; Task { await trollPublish() } }.disabled(busy) }
                    }
                }
            }
            .sheet(item: $targetPicker, onDismiss: { if pendingDeletion != nil { confirmQueueDelete = true } }) { target in
                NavigationStack {
                    TargetPickerView(api: api, repo: target.repo, branch: target.head, path: target.path, filesOnly: choosingDelete) { folder, entry in
                        busy = true
                        Task { @MainActor in
                            defer { busy = false; targetPicker = nil }
                            do {
                                let head = try await api.workspaceHead(target.repo, branch: target.branch)
                                guard head == target.head else { throw AppError(text: "选择期间远端已变化，请重新选择") }
                                if choosingDelete {
                                    guard let entry else { return }
                                    pendingDeletion = PendingRepoItem(local: nil, size: 0, path: entry.path, sha: entry.sha, head: head)
                                    // Confirmation is presented only after the picker sheet dismisses.
                                } else if let index = queue.firstIndex(where: { $0.id == choosingItem }) {
                                    queue[index].select(folder: folder, replacementPath: entry?.path, sha: entry?.sha, head: head)
                                }
                            } catch { alertText = error.localizedDescription }
                        }
                    }
                    .toolbar { Button("取消") { targetPicker = nil } }
                }
            }
            .confirmationDialog("加入远端删除？", isPresented: $confirmQueueDelete, titleVisibility: .visible) {
                Button("确认加入删除", role: .destructive) { if let item = pendingDeletion { if let id = choosingItem { removePending(id) }; queue.append(item) }; pendingDeletion = nil }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: { Text(pendingDeletion?.path ?? "") }
            .sheet(isPresented: $showDebEditor) {
                DebEditorView(api: api, initialFile: editorFile) { generated in
                    adoptGeneratedDeb(generated, replacing: editingQueueID)
                    showDebEditor = false
                }
            }
            .task {
                guard !initialFileLoaded else { return }; initialFileLoaded = true
                if let initialFile { adoptGeneratedDeb(initialFile) }
            }

            .task(id: repo) { await loadWriteAccess() }
            .onChange(of: repo) { _ in canWrite = false; accessGeneration = UUID(); invalidateTarget() }
            .onChange(of: branch) { _ in invalidateTarget() }
            .onChange(of: busy) { UIApplication.shared.isIdleTimerDisabled = $0 }
        }
    }
    private func loadWriteAccess() async {
        let token = UUID(); accessGeneration = token; canWrite = false
        guard !repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await api.requireWriteAccess(repo)
            guard token == accessGeneration, api.isCurrentSession else { return }
            canWrite = true
        } catch { /* Unknown or denied permissions leave writes disabled. */ }
    }
    private var fileSection: some View {
        Section("本地文件") {
            Button("待上传文件") { pickingInbox = true }.disabled(busy).softGroupedRow(top: true)
            Button { picking = true } label: { Label("选择文件", systemImage: "folder.badge.plus").padding(.vertical, 4) }.disabled(busy).softGroupedRow(bottom: local == nil)
            if let file = local {
                Label(file.lastPathComponent, systemImage: file.pathExtension.lowercased() == "deb" ? "shippingbox.fill" : "doc.fill").font(.headline).softGroupedRow()
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)).font(.caption).monospacedDigit().foregroundColor(.secondary).softGroupedRow()
                Button("移除已选文件", role: .destructive) { clearSelection() }.disabled(busy).softGroupedRow(bottom: !(bytes > 10 * 1024 * 1024 && mode == 0))
                if bytes > 10 * 1024 * 1024 && mode == 0 { Text("超过 10 MiB，请选 Release 发布。").foregroundColor(.orange).softGroupedRow(bottom: true) }
            }
        }
    }
    private func removePending(_ id: UUID) {
        if let item = queue.first(where: { $0.id == id }), let url = item.local { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        queue.removeAll { $0.id == id }
    }
    private var commitSection: some View {
        Section("提交到仓库") {
            if openedFromFolder {
                LabeledContent("仓库", value: repo).softGroupedRow(top: true)
                LabeledContent("目录", value: directory.isEmpty ? "/" : directory).softGroupedRow()
            } else {
                TextField("仓库链接", text: $repo).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow(top: true)
            }
            Text("普通提交可多选、继续追加；每项选择目标，删除仅在最后确认后提交。发行版支持多附件；TrollFools 为单插件。") .font(.caption).softGroupedRow()
            ForEach(queue) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.local?.lastPathComponent ?? "远端删除").font(.headline)
                    Text(item.path ?? "尚未选择目标").font(.caption).textSelection(.enabled)
                }.softGroupedRow()
                Button(item.local == nil ? "重新选择删除文件" : "选择 / 更改目标") {
                    choosingItem = item.id; choosingDelete = item.local == nil
                    Task { await openTargetPicker() }
                }.disabled(repo.isEmpty).softGroupedRow()
                if item.local?.pathExtension.lowercased() == "deb" {
                    Button("编辑包信息") { beginEditing(item) }.disabled(busy).softGroupedRow()
                }
                Button("移除此待处理项", role: .destructive) { removePending(item.id) }.softGroupedRow()
            }
            Button("添加远端删除") { choosingItem = nil; choosingDelete = true; Task { await openTargetPicker() } }.disabled(repo.isEmpty || !canWrite).softGroupedRow()
            TextField("提交说明", text: $note).softGroupedRow()
            DisclosureGroup("分支") {
                TextField("留空使用默认分支", text: $branch).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .softGroupedRow()
            }.softGroupedRow()
            Button("检查提交权限") { Task { await checkAccess() } }.disabled(repo.isEmpty).softGroupedRow()
            Button("预览提交") {
                if let reason = RepoQueue.readiness(queue, repo: repo, message: note) { alertText = reason }
                else { confirmCommit = true }
            }.disabled(busy || !canWrite).softGroupedRow(bottom: true)
        }.disabled(busy)
    }
    private var trollSection: some View {
        Section("发布 TrollFools 插件") {
            TextField("仓库链接", text: $repo).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow(top: true)
            TextField("插件名字（必填）", text: $trollName).softGroupedRow()
            TextField("版本", text: $trollVersion).textInputAutocapitalization(.never).softGroupedRow()
            TextField("描述（留空使用名字）", text: $trollDescription).softGroupedRow()
            TextField("Bundle ID（选填）", text: $trollBundleID).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow()
            TextField("作者（选填）", text: $trollAuthor).softGroupedRow()
            DisclosureGroup("分支") { TextField("留空使用默认分支", text: $branch).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow() }.softGroupedRow()
            Text("上传插件并更新索引").font(.caption).softGroupedRow()
            DisclosureGroup("索引说明") { Text("单次 Git 提交更新 downloads/ 与 trollpackages.json；保留既有条目及外链。section：插件（已有值保留）。").font(.caption).softGroupedRow() }.softGroupedRow()
            Button("预览并发布插件") { trollPreview = true }.disabled(busy || !canWrite || local == nil || repo.isEmpty || trollName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || trollVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).softGroupedRow(bottom: true)
        }.disabled(busy)
    }

    private var releaseSection: some View {
        Section("发行版") {
            TextField("仓库链接（可留空后选择）", text: $repo).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow(top: true)
            Button("发布") { sharedReleaseEntry = true }.disabled(busy).softGroupedRow()
            NavigationLink { ReleaseManagementDestination(api: api, repo: repo) } label: { Text("发行版管理") }
                .disabled(busy || repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .softGroupedRow(bottom: true)
        }
    }
    static func inferredTrollVersion(from filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        guard let range = stem.range(of: #"(?:^|[-_ ])v?(\d+(?:\.\d+){1,3})(?:$|[-_ ])"#, options: .regularExpression) else { return "1.0" }
        let match = String(stem[range]).trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        return match.hasPrefix("v") ? String(match.dropFirst()) : match
    }
    private func beginEditing(_ item: PendingRepoItem) {
        guard item.local?.pathExtension.lowercased() == "deb" else { return }
        editingQueueID = item.id; editorFile = item.local; showDebEditor = true
    }
    private func adoptGeneratedDeb(_ source: URL, replacing id: UUID? = nil) {
        var pendingDir: URL?
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            pendingDir = dir
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = dir.appendingPathComponent(source.lastPathComponent)
            do { try FileManager.default.copyItem(at: source, to: copy) }
            catch { try? FileManager.default.removeItem(at: dir); throw error }
            let checked = try DebControlEditor.prepareForUpload(copy)
            defer { if checked.file != copy { try? FileManager.default.removeItem(at: checked.file.deletingLastPathComponent()) } }
            if checked.file != copy { try FileManager.default.removeItem(at: copy); try FileManager.default.copyItem(at: checked.file, to: copy) }
            let size = try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber
            guard let size else { throw AppError(text: "读取新 deb 文件大小失败") }
            if id != nil || mode == 0 { guard size.int64Value <= 10 * 1024 * 1024 else { throw AppError(text: "新 deb 超过 10 MiB，请使用 Release") } }
            if let id {
                guard let index = queue.firstIndex(where: { $0.id == id }) else { throw AppError(text: "原队列项已移除，未添加重复项") }
                let old = queue[index].local
                queue[index].replaceLocal(copy, size: size.int64Value)
                pendingDir = nil
                if let old { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
                alertText = "已原位替换队列 deb；原目标路径、SHA 与 HEAD 保留。"
                return
            }
            clearSelection()
            local = copy; bytes = size.int64Value
            pendingDir = nil
            if bytes > 10 * 1024 * 1024 { mode = 1 }
            if mode == 2 { mode = 0 }
            // Never infer repository root; the user must explicitly choose a target.
            if mode != 0 { invalidateTarget() }
            if mode == 0 { queue.append(PendingRepoItem(local: copy, size: bytes)); local = nil; bytes = 0 }
            alertText = "新 deb 已选中。提交仓库前请选择目标目录；也可选择 Release 附件。"
        } catch {
            if let pendingDir { try? FileManager.default.removeItem(at: pendingDir) }
            alertText = error.localizedDescription
        }
    }
    private func clearSelection() {
        if let old = local { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
        local = nil; bytes = 0; progress = 0
        // Only clears the local selection; never deletes a remote file or uploaded asset.
    }
    private func openTargetPicker() async {
        busy = true; defer { busy = false }
        do {
            let resolved = try await api.resolvedBranch(repo, branch: branch)
            let head = try await api.workspaceHead(repo, branch: resolved)
            targetPicker = RepositoryTarget(repo: repo, branch: resolved, path: "", head: head)
        } catch { alertText = error.localizedDescription }
    }
    private func invalidateTarget() {
        for i in queue.indices { queue[i].path = nil; queue[i].sha = nil; queue[i].head = nil }
    }
    private func checkAccess() async {
        busy = true; defer { busy = false }
        do { alertText = try await api.inspectAccess(repo) }
        catch { alertText = error.localizedDescription }
    }
    @MainActor
    private func select(_ result: Result<[URL], Error>) async {
        busy = true; progress = 0
        defer { busy = false }
        do {
            let sources = try result.get()
            if mode == 0 {
                for source in sources {
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
                    guard attrs[.type] as? FileAttributeType == .typeRegular else { throw AppError(text: "请选择普通文件：" + source.lastPathComponent) }
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    guard size <= 10 * 1024 * 1024 else { throw AppError(text: source.lastPathComponent + " 超过 10 MiB，未加入队列；请切换 Release 再选择该文件") }
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let copy = folder.appendingPathComponent(source.lastPathComponent)
                    do { try FileManager.default.copyItem(at: source, to: copy) } catch { try? FileManager.default.removeItem(at: folder); throw error }
                    do {
                        let checked = try await Task.detached(priority: .userInitiated) { try DebControlEditor.prepareForUpload(copy) }.value
                        defer { if checked.file != copy { try? FileManager.default.removeItem(at: checked.file.deletingLastPathComponent()) } }
                        if checked.file != copy { try FileManager.default.removeItem(at: copy); try FileManager.default.copyItem(at: checked.file, to: copy) }
                        let actual = (try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber)?.int64Value ?? Int64.max
                        guard actual <= 10 * 1024 * 1024 else { throw AppError(text: "修复后文件超过 10 MiB，请使用 Release") }
                        queue.append(PendingRepoItem(local: copy, size: actual))
                        if let notice = checked.notice { alertText = notice }
                    } catch { try? FileManager.default.removeItem(at: folder); throw error }
                }
                return
            }
            guard let source = sources.first else { return }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let trollMode = mode == 2
            let prepared = try await Task.detached(priority: .userInitiated) { () throws -> (URL, Int64, String?) in
                let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular else { throw AppError(text: "请选择单个普通文件，不是文件夹。") }
                if trollMode && !source.lastPathComponent.lowercased().hasSuffix(".dylib") { throw AppError(text: "TrollFools 发布只能选择 .dylib 文件。") }
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? Int64.max
                if trollMode {
                    guard size > 0, size <= RepoQueue.maximumTrollPluginBytes else { throw AppError(text: "TrollFools 插件必须大于 0 且不超过 20 MiB。") }
                } else {
                    guard size > 0, size < 2 * 1024 * 1024 * 1024 else { throw AppError(text: "Release 单附件必须大于 0 且小于 2 GiB。") }
                }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(source.lastPathComponent)
                do { try FileManager.default.copyItem(at: source, to: target) }
                catch { try? FileManager.default.removeItem(at: folder); throw error }
                do {
                    let checked = try DebControlEditor.prepareForUpload(target)
                    defer { if checked.file != target { try? FileManager.default.removeItem(at: checked.file.deletingLastPathComponent()) } }
                    if checked.file != target { try FileManager.default.removeItem(at: target); try FileManager.default.copyItem(at: checked.file, to: target) }
                    let actual = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? Int64.max
                    if trollMode {
                        guard actual > 0, actual <= RepoQueue.maximumTrollPluginBytes else { throw AppError(text: "修复后的插件超过 20 MiB。") }
                    } else {
                        guard actual > 0, actual < 2 * 1024 * 1024 * 1024 else { throw AppError(text: "Release 附件过大") }
                    }
                    return (target, actual, checked.notice)
                } catch { try? FileManager.default.removeItem(at: folder); throw error }
            }.value
            if let old = local { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
            local = prepared.0; bytes = prepared.1
            if let notice = prepared.2 { alertText = notice }
            if mode == 2 {
                trollName = prepared.0.deletingPathExtension().lastPathComponent
                trollVersion = Self.inferredTrollVersion(from: prepared.0.lastPathComponent)
                trollDescription = trollName
            }

        } catch { alertText = error.localizedDescription }
    }
    private func commit() async {
        busy = true; progress = 0; defer { busy = false }
        do {
            try await api.commitQueue(repo: repo, branch: branch, items: queue, message: note)
            for item in queue { if let url = item.local { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
            queue = []; progress = 1; alertText = "队列已在一次非强制 Git 提交中完成。"
        } catch { alertText = error.localizedDescription }
    }
    private func trollPublish() async {
        guard let file = local else { return }
        busy = true; progress = 0; defer { busy = false }
        do {
            let result = try await api.trollPublish(repo: repo, branch: branch, file: file, pluginName: trollName, version: trollVersion, description: trollDescription, bundleID: trollBundleID, author: trollAuthor)
            progress = 1; alertText = "TrollFools 插件与索引已原子提交。提交 SHA：\(result.commitSHA)"
            clearSelection()
        } catch { alertText = error.localizedDescription }
    }
    private func loadReleases() async {
        busy = true; defer { busy = false }
        do { releases = try await api.releases(repo) }
        catch { alertText = error.localizedDescription }
    }
    private func createAndUpload() async {
        guard let file = local else { return }
        busy = true; progress = 0; asset = nil; defer { busy = false }
        do {
            var destination = repo
            if makeNewRepo {
                let created = try await api.createRepository(name: newName, isPrivate: isPrivate)
                destination = created.full_name
                repo = destination
                // Do not recreate a successfully created repository if a later step fails.
                makeNewRepo = false
            }
            let createdRelease = try await api.createRelease(destination, tag: tag, title: title)
            release = createdRelease; releaseRepo = destination
            asset = try await api.upload(createdRelease, file: file) { value in
                Task { @MainActor in progress = value }
            }
            progress = 1; alertText = "附件上传成功，Release 仍是草稿。确认后点“公开此 Release”。"
        } catch { alertText = error.localizedDescription }
    }
    private func uploadSelected() async {
        guard let file = local, let r = release else { return }
        busy = true; progress = 0; defer { busy = false }
        do {
            asset = try await api.upload(r, file: file) { value in Task { @MainActor in progress = value } }
            progress = 1; alertText = r.draft ? "上传成功，草稿可公开发布。" : "上传成功，附件已加入公开 Release。"
        } catch { alertText = error.localizedDescription }
    }
    private func saveAsset(_ asset: Asset, repo: String) async {
        guard !busy, api.isCurrentSession else { return }
        downloadNotice = ""
        let generation = AccountStore.generation
        busy = true; defer { busy = false }
        do {
            try await DownloadStore.shared.requireAuthorization()
            guard api.isCurrentSession else { throw CancellationError() }
            DownloadStore.shared.begin(); defer { DownloadStore.shared.end() }
            let temporary = try await api.downloadAsset(repo, asset: asset)
            defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
            guard (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.intValue == asset.size else { throw AppError(text: "附件大小不符，请重试。") }
            _ = try await DownloadStore.shared.persist(temporary, session: generation)
            guard api.isCurrentSession else { throw CancellationError() }
            downloadNotice = "已下载并保存到 " + DownloadStore.shared.label
        } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { alertText = error.localizedDescription } }
    }
    private func publish() async {
        guard let r = release else { return }
        busy = true; defer { busy = false }
        do { release = try await api.publish(releaseRepo, release: r); alertText = "Release 已发布，可分享下载链接。" }
        catch { alertText = error.localizedDescription }
    }
}
