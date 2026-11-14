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
    @State private var editingItem: PendingRepoItem?
    @State private var initialFileLoaded = false
    @State private var alertText = ""
    @State private var repo: String
    @State private var branch: String
    @State private var queue: [PendingRepoItem] = []
    @State private var choosingItem: UUID?
    @State private var choosingDelete = false
    @State private var confirmQueueDelete = false
    @State private var pendingDeletion: PendingRepoItem?
    @State private var targetPicker: RepositoryTarget?
    @State private var destinationFolder: String?
    @State private var destination: UploadDestination?
    @State private var targetGeneration = UUID()
    @State private var branchExpanded = false
    @State private var optionsExpanded = false
    @State private var pendingReplacement: PendingRepoItem?
    @State private var confirmReplacement = false

    private struct UploadDestination {
        let target: RepositoryTarget
        let files: [String: String]
        let directories: Set<String>
    }

    init(api: GitHub, initialRepo: String = "", directory: String = "", initialBranch: String = "", initialFile: URL? = nil, openedFromFolder: Bool = false) {
        self.api = api
        self.initialFile = initialFile
        self.directory = directory
        self.openedFromFolder = openedFromFolder
        _repo = State(initialValue: initialRepo)
        _branch = State(initialValue: initialBranch)
        _destinationFolder = State(initialValue: openedFromFolder && !initialRepo.isEmpty ? directory : nil)
    }
    @State private var note = "Upload via RepoPocket"
    @State private var picking = false
    @State private var pickingInbox = false
    @State private var inboxSelection: [URL] = []
    @State private var busy = false
    @State private var confirmCommit = false
    @State private var progress: Double = 0
    @State private var reviewError = ""
    @State private var reviewFingerprint: String?
    var body: some View {
        AppNavigationStack {
            Form {
                Section {
                    fileSection
                    commitSection
                    if busy {
                        if progress > 0 { ProgressView(value: progress).tint(.accentColor).softGroupedRow() }
                        else { ProgressView("正在处理…").softGroupedRow() }
                        Label("请保持前台，勿锁屏。", systemImage: "iphone").font(.caption).foregroundColor(.secondary).softGroupedRow(bottom: true)
                    }
                }
            }
            .appGroupedFormStyle()
            .adaptiveWorkspaceLayout()
            .navigationTitle("上传到仓库")
            .appScrollDismissesKeyboard(.never)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("关闭") { dismiss() }.disabled(busy)

            }
            .sheet(isPresented: $pickingInbox, onDismiss: {
                let files = inboxSelection; inboxSelection = []
                guard !files.isEmpty else { return }
                Task { await select(.success(files)); ShareSelectionCleanup.remove(files) }
            }) {
                ShareInboxView(multiple: true) { files in inboxSelection = files; pickingInbox = false }
            }
            .interactiveDismissDisabled(busy)
            .alert("提示", isPresented: Binding(get: { !alertText.isEmpty }, set: { if !$0 { alertText = "" } })) {
                Button("好", role: .cancel) { alertText = "" }
            } message: { Text(alertText) }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in Task { await select(result) } }
            .sheet(isPresented: $confirmCommit) {
                AppNavigationStack {
                    List {
                        Section {
                            SoftGroupRows {
                                SoftGroupRow("review-title") { Text("最终提交预览").font(.caption).foregroundStyle(.secondary) }
                                SoftGroupRow("review-repo") { AppLabeledContent("仓库", value: repo) }
                                SoftGroupRow("review-branch") { AppLabeledContent("分支", value: branch.isEmpty ? "默认分支（以已选目标 HEAD 校验）" : branch) }
                                SoftGroupRow("review-message") { Text(note) }
                                for item in queue {
                                    SoftGroupRow(item.id.uuidString) {
                                        VStack(alignment: .leading) {
                                            Text((item.local == nil ? "删除：" : item.sha == nil ? "新增：" : "替换：") + (item.path ?? "未选择"))
                                            if let sha = item.sha { Text("原 SHA：" + sha).font(.caption) }
                                            if let head = item.head { Text("HEAD：" + head).font(.caption) }
                                        }
                                    }
                                }
                                if busy { SoftGroupRow("review-busy") { ProgressView("正在核验 / 提交…") } }
                                if !reviewError.isEmpty { SoftGroupRow("review-error") { Text(reviewError).foregroundColor(.red) } }
                                SoftGroupRow("review-retry") { Button("检查并重试") { Task { await preflightCommit() } }.disabled(busy) }
                                SoftGroupRow("review-confirm") {
                                    Button("确认提交以上全部项目") { Task { await commit() } }
                                        .disabled(busy || reviewFingerprint == nil || !api.isCurrentSession)
                                }
                            }
                        }
                    }
                    .navigationTitle("确认原子提交")
                    .toolbar { Button("取消") { confirmCommit = false }.disabled(busy) }
                    .task { await preflightCommit() }
                }.interactiveDismissDisabled(busy)
            }
            .sheet(item: $targetPicker, onDismiss: {
                if pendingDeletion != nil { confirmQueueDelete = true }
                if pendingReplacement != nil { confirmReplacement = true }
            }) { target in
                AppNavigationStack {
                    TargetPickerView(api: api, repo: target.repo, branch: target.head, path: target.path, filesOnly: choosingDelete, foldersOnly: choosingItem == nil && !choosingDelete) { folder, entry in
                        guard !busy else { return }
                        busy = true
                        let generation = targetGeneration
                        Task { @MainActor in
                            defer { busy = false; targetPicker = nil }
                            do {
                                let head = try await api.workspaceHead(target.repo, branch: target.branch)
                                guard targetPicker?.id == target.id, generation == targetGeneration, api.isCurrentSession else { throw CancellationError() }
                                guard head == target.head else { throw AppError(text: "选择期间远端已变化，请重新选择") }
                                if choosingDelete {
                                    guard let entry else { return }
                                    pendingDeletion = PendingRepoItem(local: nil, size: 0, path: entry.path, sha: entry.sha, head: head)
                                    // Confirmation is presented only after the picker sheet dismisses.
                                } else if let index = queue.firstIndex(where: { $0.id == choosingItem }) {
                                    if let entry {
                                        var replacement = queue[index]
                                        replacement.select(folder: folder, replacementPath: entry.path, sha: entry.sha, head: head)
                                        pendingReplacement = replacement
                                    } else {
                                        let selected = try await readDestination(folder: folder)
                                        guard targetPicker?.id == target.id else { throw CancellationError() }
                                        try selectTarget(at: index, destination: selected)
                                    }
                                } else {
                                    let selected = try await readDestination(folder: folder)
                                    guard targetPicker?.id == target.id else { throw CancellationError() }
                                    destinationFolder = folder; destination = selected
                                    try inheritMissingTargets(selected)
                                }
                            } catch { if !RefreshFailure.isCancellation(error) { alertText = error.localizedDescription } }
                        }
                    }.disabled(busy)
                    .toolbar { Button("取消") { targetPicker = nil }.disabled(false) }
                }
            }
            .confirmationDialog("加入远端删除？", isPresented: $confirmQueueDelete, titleVisibility: .visible) {
                Button("确认加入删除", role: .destructive) { if let item = pendingDeletion { if let id = choosingItem { removePending(id) }; queue.append(item) }; pendingDeletion = nil }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: { Text(pendingDeletion?.path ?? "") }
            .confirmationDialog("替换现有文件？", isPresented: $confirmReplacement, titleVisibility: .visible) {
                Button("确认替换", role: .destructive) {
                    if let replacement = pendingReplacement { Task { await acceptReplacement(replacement) } }
                    pendingReplacement = nil
                }
                Button("取消", role: .cancel) { pendingReplacement = nil }
            } message: { Text(pendingReplacement?.path ?? "") }
            .sheet(item: $editingItem) { item in
                DebEditorView(api: api, initialFile: item.local, onUseForUpload: { generated in
                    try adoptGeneratedDeb(generated, replacing: item.id)
                })
            }
            .task {
                guard !initialFileLoaded else { return }; initialFileLoaded = true
                if let initialFile { await select(.success([initialFile])) }
            }

            .task(id: repo) { await loadWriteAccess() }
            .onChange(of: repo) { _ in canWrite = false; accessGeneration = UUID(); invalidateTarget() }
            .onChange(of: branch) { _ in invalidateTarget() }
            .onChange(of: busy) { UIApplication.shared.isIdleTimerDisabled = $0 }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
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
        Group {
            Text("本地文件").font(.caption).foregroundStyle(.secondary).softGroupedRow(top: true)
            Button("待上传文件") { pickingInbox = true }.disabled(busy).softGroupedRow()
            Button { picking = true } label: { Label("选择文件", systemImage: "folder.badge.plus").padding(.vertical, 4) }.disabled(busy).softGroupedRow()
        }
    }
    private func removePending(_ id: UUID) {
        if let item = queue.first(where: { $0.id == id }), let url = item.local { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        queue.removeAll { $0.id == id }
    }
    private var commitSection: some View {
        SoftGroupRows(top: false, bottom: !busy) {
            SoftGroupRow("target-title") { Text("提交到仓库").font(.caption).foregroundStyle(.secondary) }
            SoftGroupRow("repo") {
                if openedFromFolder && !repo.isEmpty { AppLabeledContent("仓库", value: repo) }
                else { TextField("仓库链接", text: $repo).textInputAutocapitalization(.never).autocorrectionDisabled() }
            }
            SoftGroupRow("directory") {
                Button {
                    choosingItem = nil; choosingDelete = false
                    Task { await openTargetPicker() }
                } label: {
                    AppLabeledContent("默认目录", value: destinationFolder.map { $0.isEmpty ? "/" : $0 } ?? "请选择")
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.disabled(repo.isEmpty).accessibilityIdentifier("upload-directory")
            }
            SoftGroupRow("branch") {
                Button { UIRules.withoutAnimation { branchExpanded.toggle() } } label: {
                    HStack {
                        Text("分支"); Spacer()
                        Text(destination?.target.branch ?? (branch.isEmpty ? "默认分支" : branch)).foregroundStyle(.secondary)
                        Image(systemName: branchExpanded ? "chevron.up" : "chevron.down").font(.caption)
                    }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("upload-branch")
            }
            if branchExpanded {
                SoftGroupRow("branch-input") { TextField("留空使用默认分支", text: $branch).textInputAutocapitalization(.never).autocorrectionDisabled() }
            }
            if !queue.isEmpty {
                SoftGroupRow("queue-title") { Text("待提交 · \(queue.count) 个项目").font(.caption).foregroundStyle(.secondary) }
                for item in queue {
                    SoftGroupRow(item.id.uuidString) {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.local?.lastPathComponent ?? "远端删除").font(.headline)
                                Text(item.path ?? (automaticReplacement(item) == nil ? "请选择上传目录" : "同名文件已存在，需确认替换"))
                                    .font(.caption).foregroundStyle(item.path == nil ? .secondary : .primary).textSelection(.enabled)
                                    .accessibilityIdentifier("upload-target-" + (item.local?.lastPathComponent ?? item.id.uuidString))
                            }
                            Spacer(minLength: 8)
                            NativeActionMenu(title: "文件操作：" + (item.local?.lastPathComponent ?? "远端删除"),
                                accessibilityIdentifier: "upload-file-actions-" + item.id.uuidString,
                                enabled: !busy, items: pendingActions(item))
                                .frame(width: 44, height: 44)
                        }
                    }
                    if let replacement = automaticReplacement(item) {
                        SoftGroupRow(item.id.uuidString + "-replace") {
                            Button("确认替换同名文件…") { pendingReplacement = replacement; confirmReplacement = true }
                        }
                    }
                }
            }
            SoftGroupRow("options") {
                Button { UIRules.withoutAnimation { optionsExpanded.toggle() } } label: {
                    HStack { Text("更多选项"); Spacer(); Image(systemName: optionsExpanded ? "chevron.up" : "chevron.down").font(.caption) }
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if optionsExpanded {
                SoftGroupRow("message") { TextField("提交说明", text: $note) }
                SoftGroupRow("delete") { Button("添加远端删除") { choosingItem = nil; choosingDelete = true; Task { await openTargetPicker() } }.disabled(repo.isEmpty || !canWrite) }
            }
            if !canWrite { SoftGroupRow("permission") { Text("未确认仓库写权限，暂不能提交。").font(.caption).foregroundStyle(.secondary) } }
            SoftGroupRow("preview") {
                Button("预览提交") {
                    reviewFingerprint = nil; reviewError = ""; confirmCommit = true
                }.accessibilityIdentifier("upload-preview")
            }
        }.disabled(busy).transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
    private func pendingActions(_ item: PendingRepoItem) -> [NativeMenuItem] {
        var actions = [NativeMenuItem(id: "target", title: item.local == nil ? "重新选择删除文件" : "更改位置", symbol: "folder", enabled: !repo.isEmpty, perform: {
            choosingItem = item.id; choosingDelete = item.local == nil
            Task { await openTargetPicker() }
        })]
        if item.local?.pathExtension.lowercased() == "deb" {
            actions.append(NativeMenuItem(id: "deb", title: "编辑包信息", symbol: "shippingbox", perform: { beginEditing(item) }))
        }
        actions.append(NativeMenuItem(id: "remove", title: "移除此待处理项", symbol: "trash", destructive: true, perform: { removePending(item.id) }))
        return actions
    }
    private func beginEditing(_ item: PendingRepoItem) {
        guard item.local?.pathExtension.lowercased() == "deb" else { return }
        editingItem = item
    }
    private func adoptGeneratedDeb(_ source: URL, replacing id: UUID? = nil) throws {
        var pendingDir: URL?
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw AppError(text: "生成文件不是普通文件。") }
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
            _ = try RepoQueue.addingUploadBytes(size.int64Value, to: queuedUploadBytes(excluding: id))
            if let id {
                guard let index = queue.firstIndex(where: { $0.id == id }) else { throw AppError(text: "原队列项已移除，未添加重复项") }
                let old = queue[index].local
                queue[index].replaceLocal(copy, size: size.int64Value)
                pendingDir = nil
                if let old { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
                reviewFingerprint = nil
                return
            }
            queue.append(PendingRepoItem(local: copy, size: size.int64Value))
            pendingDir = nil; reviewFingerprint = nil
            Task { await prepareInheritedTargets() }
        } catch {
            if let pendingDir { try? FileManager.default.removeItem(at: pendingDir) }
            throw error
        }
    }

    private func queuedUploadBytes(excluding id: UUID? = nil) throws -> Int64 {
        var total: Int64 = 0
        for item in queue where item.id != id {
            if let file = item.local {
                let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? Int64.max
                total = try RepoQueue.addingUploadBytes(size, to: total)
            }
        }
        return total
    }
    @MainActor private func openTargetPicker() async {
        busy = true; defer { busy = false }
        do {
            let generation = targetGeneration, requestedRepo = repo, requestedBranch = branch
            let resolved = try await api.resolvedBranch(requestedRepo, branch: requestedBranch)
            let head = try await api.workspaceHead(requestedRepo, branch: resolved)
            guard generation == targetGeneration, requestedRepo == repo, requestedBranch == branch, api.isCurrentSession else { throw CancellationError() }
            let item = queue.first { $0.id == choosingItem }
            let folder = item?.path.map { ($0 as NSString).deletingLastPathComponent } ?? destinationFolder ?? ""
            targetPicker = RepositoryTarget(repo: requestedRepo, branch: resolved, path: folder, head: head)
        } catch { if !RefreshFailure.isCancellation(error) { alertText = error.localizedDescription } }
    }
    private func invalidateTarget() {
        targetGeneration = UUID(); destination = nil; destinationFolder = nil
        pendingReplacement = nil; pendingDeletion = nil; targetPicker = nil
        for i in queue.indices { queue[i].path = nil; queue[i].sha = nil; queue[i].head = nil }
    }
    @MainActor private func readDestination(folder: String) async throws -> UploadDestination {
        let generation = targetGeneration, requestedRepo = repo, requestedBranch = branch
        let name = try RepositoryInput.parse(requestedRepo)
        let resolved = try await api.resolvedBranch(name, branch: requestedBranch)
        let head = try await api.workspaceHead(name, branch: resolved)
        let tree = try await api.uploadDestinationTree(name, head: head)
        guard folder.isEmpty || tree.directories.contains(folder) else { throw AppError(text: "目标目录已不存在，请重新选择上传位置") }
        guard generation == targetGeneration, requestedRepo == repo, requestedBranch == branch, api.isCurrentSession else { throw CancellationError() }
        guard try await api.workspaceHead(name, branch: resolved) == head else { throw AppError(text: "核验期间远端已变化，请重试选择目标") }
        guard generation == targetGeneration, api.isCurrentSession else { throw CancellationError() }
        return UploadDestination(target: RepositoryTarget(repo: name, branch: resolved, path: folder, head: head), files: tree.files, directories: tree.directories)
    }
    private func inheritMissingTargets(_ selected: UploadDestination) throws {
        for i in queue.indices where queue[i].local != nil && queue[i].path == nil {
            _ = try queue[i].inheritTarget(folder: selected.target.path, head: selected.target.head, files: selected.files, directories: selected.directories)
        }
    }
    @MainActor private func prepareInheritedTargets() async {
        guard let folder = destinationFolder else { return }
        busy = true; defer { busy = false }
        do {
            let selected = try await readDestination(folder: folder)
            destination = selected
            try inheritMissingTargets(selected)
        } catch { if !RefreshFailure.isCancellation(error) { alertText = error.localizedDescription } }
    }
    private func automaticReplacement(_ item: PendingRepoItem) -> PendingRepoItem? {
        guard item.path == nil, let local = item.local, let destination else { return nil }
        let path = (destination.target.path.isEmpty ? "" : destination.target.path + "/") + local.lastPathComponent
        guard let sha = destination.files[path] else { return nil }
        var replacement = item
        replacement.select(folder: destination.target.path, replacementPath: path, sha: sha, head: destination.target.head)
        return replacement
    }
    private func selectTarget(at index: Int, destination selected: UploadDestination) throws {
        let inherited = try queue[index].inheritTarget(folder: selected.target.path, head: selected.target.head, files: selected.files, directories: selected.directories)
        if !inherited, let file = queue[index].local {
            let path = (selected.target.path.isEmpty ? "" : selected.target.path + "/") + file.lastPathComponent
            if let sha = selected.files[path] {
                var replacement = queue[index]
                replacement.select(folder: selected.target.path, replacementPath: path, sha: sha, head: selected.target.head)
                pendingReplacement = replacement
            }
        }
    }
    @MainActor private func acceptReplacement(_ replacement: PendingRepoItem) async {
        let generation = targetGeneration, requestedRepo = repo, requestedBranch = branch
        busy = true; defer { busy = false }
        do {
            let resolved = try await api.resolvedBranch(requestedRepo, branch: requestedBranch)
            let head = try await api.workspaceHead(requestedRepo, branch: resolved)
            guard generation == targetGeneration, api.isCurrentSession else { throw CancellationError() }
            guard head == replacement.head, let path = replacement.path, let sha = replacement.sha,
                  let index = queue.firstIndex(where: { $0.id == replacement.id }) else { throw AppError(text: "目标已变化，请重新确认替换") }
            queue[index].select(folder: (path as NSString).deletingLastPathComponent, replacementPath: path, sha: sha, head: head)
        } catch { if !RefreshFailure.isCancellation(error) { alertText = error.localizedDescription } }
    }
    private func select(_ result: Result<[URL], Error>) async {
        busy = true; progress = 0
        defer { busy = false }
        do {
            let sources = try result.get()
            do {
                var pending: [PendingRepoItem] = []
                var total = try queuedUploadBytes()
                var accepted = false
                var notices: [String] = []
                defer {
                    if !accepted {
                        for item in pending { if let file = item.local { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
                    }
                }
                for source in sources {
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
                    guard attrs[.type] as? FileAttributeType == .typeRegular else { throw AppError(text: "请选择普通文件：" + source.lastPathComponent) }
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? Int64.max
                    _ = try RepoQueue.addingUploadBytes(size, to: total)
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let copy = folder.appendingPathComponent(source.lastPathComponent)
                    do { try FileManager.default.copyItem(at: source, to: copy) } catch { try? FileManager.default.removeItem(at: folder); throw error }
                    do {
                        let checked = try await Task.detached(priority: .userInitiated) { try DebControlEditor.prepareForUpload(copy) }.value
                        defer { if checked.file != copy { try? FileManager.default.removeItem(at: checked.file.deletingLastPathComponent()) } }
                        if checked.file != copy { try FileManager.default.removeItem(at: copy); try FileManager.default.copyItem(at: checked.file, to: copy) }
                        let actual = (try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber)?.int64Value ?? Int64.max
                        total = try RepoQueue.addingUploadBytes(actual, to: total)
                        pending.append(PendingRepoItem(local: copy, size: actual))
                        if let notice = checked.notice { notices.append(notice) }
                    } catch { try? FileManager.default.removeItem(at: folder); throw error }
                }
                queue.append(contentsOf: pending)
                accepted = true
                if !notices.isEmpty { alertText = notices.joined(separator: "\n") }
                await prepareInheritedTargets()
                return
            }
        } catch { alertText = error.localizedDescription }
    }
    @MainActor private func preflightCommit() async {
        guard !busy else { return }
        busy = true; reviewError = ""; reviewFingerprint = nil
        defer { busy = false }
        do { reviewFingerprint = try await checkedFingerprint() }
        catch { if !RefreshFailure.isCancellation(error) { reviewError = error.localizedDescription } }
    }
    @MainActor private func checkedFingerprint() async throws -> String {
        guard api.isCurrentSession else { throw CancellationError() }
        if let reason = RepoQueue.readiness(queue, repo: repo, message: note) { throw AppError(text: reason) }
        try await api.requireWriteAccess(repo)
        let resolved = try await api.resolvedBranch(repo, branch: branch)
        let head = try await api.workspaceHead(repo, branch: resolved)
        let tree = try await api.uploadDestinationTree(repo, head: head)
        try RepoQueue.validate(queue, head: head, files: tree.files, directories: tree.directories)
        guard api.isCurrentSession else { throw CancellationError() }
        let capturedItems = queue, capturedRepo = repo, capturedNote = note
        return try await Task.detached(priority: .userInitiated) {
            try RepoQueue.reviewFingerprint(capturedItems, repo: capturedRepo, branch: resolved, message: capturedNote)
        }.value
    }
    @MainActor private func commit() async {
        guard !busy, let authorized = reviewFingerprint else { return }
        busy = true; progress = 0; reviewError = ""
        defer { busy = false }
        do {
            guard try await checkedFingerprint() == authorized else { throw AppError(text: "文件或目标已变化，请重新检查并确认。") }
            try await api.commitQueue(repo: repo, branch: branch, items: queue, message: note)
            for item in queue { if let url = item.local { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
            queue = []; progress = 1; confirmCommit = false; alertText = "队列已在一次非强制 Git 提交中完成。"
        } catch {
            reviewFingerprint = nil
            if !RefreshFailure.isCancellation(error) { reviewError = error.localizedDescription }
        }
    }
}
