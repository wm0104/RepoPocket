import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import UIKit

struct LocalSnapshot: Codable {
    var hashes: [String: String] = [:]
    var texts: [String: String] = [:]
    enum CodingKeys: String, CodingKey { case hashes, texts }
    init(hashes: [String: String] = [:], texts: [String: String] = [:]) {
        self.hashes = hashes; self.texts = texts
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Hashes are mandatory; legacy hash-only snapshots may omit preview texts.
        hashes = try c.decode([String: String].self, forKey: .hashes)
        texts = try c.decodeIfPresent([String: String].self, forKey: .texts) ?? [:]
    }
}
struct LocalChange: Identifiable {
    var id: String { path }
    let path: String
    let kind: String
    let before: String?
    let after: String?
    var relativePath: String { path.split(separator: "/").dropFirst().joined(separator: "/") }
}

enum LinkedWorkspaces {
    struct Entry: Codable { let id: String; var path: String; var bookmark: Data; let identity: String }
    private static let lock = NSRecursiveLock()
    private static var scopes: [String: URL] = [:]
    private static var scopedIDs: Set<String> = []
    private static func identity(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { throw AppError(text: "文件提供器未提供目录身份，无法安全关联") }
        return device.stringValue + ":" + inode.stringValue
    }
    private static func ownDocuments(_ url: URL) throws -> Bool {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let base = documents.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let target = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return target.count >= base.count && Array(target.prefix(base.count)) == base
    }
    private static func release(_ id: String) {
        if let url = scopes.removeValue(forKey: id), scopedIDs.remove(id) != nil { url.stopAccessingSecurityScopedResource() }
    }
    private static func storage() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LinkedWorkspaces.json")
    }
    private static func entries() throws -> [Entry] {
        let url = try storage()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
    }
    private static func save(_ entries: [Entry]) throws {
        try JSONEncoder().encode(entries).write(to: storage(), options: .atomic)
    }
    static func identifier(_ url: URL) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try entries().first { $0.path == url.standardizedFileURL.path }?.id
    }
    static func registeredPaths() throws -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return try entries().map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }
    static func detach(_ folder: URL) throws {
        lock.lock(); defer { lock.unlock() }
        var records = try entries()
        guard let entry = records.first(where: { $0.path == folder.standardizedFileURL.path }) else { throw AppError(text: "未找到此目录的关联记录") }
        let meta = try LocalStore.metadata(folder), remote = try LocalStore.bindingURL(folder)
        records.removeAll { $0.id == entry.id }
        try save(records)
        release(entry.id)
        // These two URLs are app-private metadata; the selected directory is untouched.
        try? FileManager.default.removeItem(at: meta)
        try? FileManager.default.removeItem(at: remote)
    }
    static func roots() throws -> [URL] {
        lock.lock(); defer { lock.unlock() }
        var records = try entries(), result: [URL] = []
        for i in records.indices {
            var stale = false
            let url = try URL(resolvingBookmarkData: records[i].bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            if scopes[records[i].id]?.standardizedFileURL != url.standardizedFileURL {
                let acquired = url.startAccessingSecurityScopedResource()
                guard try acquired || ownDocuments(url) else { throw AppError(text: "工作区授权失效，请重新选择文件夹：" + url.lastPathComponent) }
                release(records[i].id)
                scopes[records[i].id] = url
                if acquired { scopedIDs.insert(records[i].id) }
            }
            guard try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                  try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AppError(text: "关联工作区不可用，请重新选择原目录") }
            guard try identity(url) == records[i].identity else { throw AppError(text: "关联目录身份已变化，请重新确认原目录") }
            records[i].path = url.standardizedFileURL.path
            if stale { records[i].bookmark = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil) }
            result.append(url)
        }
        try save(records)
        return result
    }
    static func register(_ source: URL) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let url = source.standardizedFileURL
        var records = try entries()
        let existing = records.first { $0.path == url.path }
        let id = existing?.id ?? UUID().uuidString
        let acquired = url.startAccessingSecurityScopedResource()
        guard try acquired || ownDocuments(url) else { throw AppError(text: "无法保留文件夹授权，请重新选择原目录") }
        do {
            let bookmark = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            let baseline = try LocalStore.coordinatedSnapshot(url)
            let resourceIdentity = try identity(url)
            if let existing, existing.identity != resourceIdentity { throw AppError(text: "原路径已换成其他目录，请先刷新并重新选择原目录") }
            records.removeAll { $0.id == id }
            records.append(Entry(id: id, path: url.path, bookmark: bookmark, identity: resourceIdentity))
            try save(records)
            if existing == nil {
                do { try JSONEncoder().encode(baseline).write(to: LocalStore.metadata(url), options: .atomic) }
                catch { records.removeAll { $0.id == id }; try save(records); throw error }
            }
            if scopes[id] == nil {
                scopes[id] = url
                if acquired { scopedIDs.insert(id) }
            } else if acquired { url.stopAccessingSecurityScopedResource() }
            return url
        } catch { if acquired { url.stopAccessingSecurityScopedResource() }; throw error }
    }
    static func remove(_ folder: URL) throws {
        lock.lock(); defer { lock.unlock() }
        var records = try entries()
        guard let entry = records.first(where: { $0.path == folder.standardizedFileURL.path }) else { throw AppError(text: "目录没有授权关联，拒绝删除") }
        var stale = false
        let registered = try URL(resolvingBookmarkData: entry.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard registered.standardizedFileURL.path == folder.standardizedFileURL.path,
              try identity(folder) == entry.identity else { throw AppError(text: "原目录已移动或被替换，拒绝删除；请刷新后重试") }
        let meta = try LocalStore.metadata(folder), remote = try LocalStore.bindingURL(folder)
        guard FileManager.default.fileExists(atPath: meta.path) else { throw AppError(text: "基线不存在，拒绝删除") }
        let original = try folder.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
        let previousRecords = records
        records.removeAll { $0.id == entry.id }
        // Persist deregistration first: a metadata write failure must never follow
        // a successful irreversible removal and leave an unusable registered root.
        try save(records)
        var failure: Error?, coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: .forDeleting, error: &coordinationError) { target in
            do {
                let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileResourceIdentifierKey])
                guard target.standardizedFileURL == folder.standardizedFileURL, values.isDirectory == true, values.isSymbolicLink != true,
                      let original, let current = values.fileResourceIdentifier as? NSObject, original == current,
                      try identity(target) == entry.identity else { throw AppError(text: "删除目标已变化，拒绝删除") }
                try FileManager.default.removeItem(at: target)
            } catch { failure = error }
        }
        if let error = coordinationError ?? (failure as NSError?) {
            do { try save(previousRecords) }
            catch { throw AppError(text: "删除未完成且关联记录恢复失败；请保留原目录并重新关联：" + folder.path) }
            throw error
        }
        release(entry.id)
        try? FileManager.default.removeItem(at: meta)
        try? FileManager.default.removeItem(at: remote)
    }
}

enum LocalStore {
    static func matchingRoot(_ selected: URL?, in roots: [URL]) -> URL? {
        guard let selected else { return nil }
        let path = selected.resolvingSymlinksInPath().standardizedFileURL.path
        // Compare filesystem identity paths while retaining the bookmark URL and
        // its scope; /var and /private/var may describe the same iOS/macOS folder.
        return roots.first { $0.resolvingSymlinksInPath().standardizedFileURL.path == path }
    }
    static func root() throws -> URL {
        let fm = FileManager.default
        let url = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Repositories", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func metadata(_ folder: URL) throws -> URL {
        let fm = FileManager.default
        let url = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LocalBaselines", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let name = try LinkedWorkspaces.identifier(folder).map { "linked-" + $0 } ?? folder.lastPathComponent
        return url.appendingPathComponent(name + ".json")
    }
    static func snapshot(_ directory: URL) throws -> LocalSnapshot {
        if try LinkedWorkspaces.identifier(directory) != nil {
            return try coordinatedSnapshot(directory)
        }
        return try snapshotContents(directory)
    }
    static func coordinatedSnapshot(_ directory: URL) throws -> LocalSnapshot {
            var result: LocalSnapshot?, failure: Error?, coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: directory, options: .withoutChanges, error: &coordinationError) { readable in
                do { result = try snapshotContents(readable) } catch { failure = error }
            }
            if let error = coordinationError { throw error }
            if let error = failure { throw error }
            guard let result else { throw AppError(text: "文件提供器未返回工作目录") }
            return result
    }
    private static func snapshotContents(_ directory: URL) throws -> LocalSnapshot {
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw AppError(text: "工作区不是可读取的文件夹") }
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AppError(text: "工作区根目录不能是符号链接") }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        var snapshot = LocalSnapshot()
        var failure: Error?
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, error in failure = error; return false }) else { throw AppError(text: "无法扫描工作目录") }
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".git" { enumerator.skipDescendants(); continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); throw AppError(text: "不支持符号链接：" + url.lastPathComponent) }
            guard values.isRegularFile == true else { continue }
            let components = url.standardizedFileURL.pathComponents
            let base = root.pathComponents
            guard Array(components.prefix(base.count)) == base else { throw AppError(text: "扫描路径越界") }
            let path = components.dropFirst(base.count).joined(separator: "/")
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var small = Data()
            var total = 0
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk); total += chunk.count
                if total <= 64 * 1024 { small.append(chunk) }
            }
            snapshot.hashes[path] = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if total <= 64 * 1024, !small.contains(0), let text = String(data: small, encoding: .utf8) { snapshot.texts[path] = text }
        }
        if let failure = failure { throw failure }
        return snapshot
    }
    static func changes(_ folders: [URL]) throws -> [LocalChange] {
        var result: [LocalChange] = []
        for folder in folders {
            let baseline = try (try? binding(folder).snapshot) ?? JSONDecoder().decode(LocalSnapshot.self, from: Data(contentsOf: metadata(folder)))
            let current = try snapshot(folder)
            for path in Set(baseline.hashes.keys).union(current.hashes.keys).sorted() where baseline.hashes[path] != current.hashes[path] {
                result.append(LocalChange(path: folder.lastPathComponent + "/" + path, kind: baseline.hashes[path] == nil ? "新增" : (current.hashes[path] == nil ? "删除" : "修改"), before: baseline.texts[path], after: current.texts[path]))
            }
        }
        return result
    }
    static func removeWorkspace(_ folder: URL) throws {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let canonical = folder.resolvingSymlinksInPath().standardizedFileURL
        guard canonical != documents.resolvingSymlinksInPath().standardizedFileURL,
              canonical != documents.appendingPathComponent("Repositories", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL else {
            throw AppError(text: "不能删除 App 文档根目录或全部工作区根目录；请只选择具体项目")
        }
        if try LinkedWorkspaces.identifier(folder) != nil { try LinkedWorkspaces.remove(folder); return }
        let fm = FileManager.default
        let base = try root().standardizedFileURL
        guard folder.standardizedFileURL.deletingLastPathComponent() == base,
              folder.lastPathComponent != "." && !folder.lastPathComponent.hasPrefix(".delete-") else {
            throw AppError(text: "拒绝删除工作区目录外的路径")
        }
        guard try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AppError(text: "工作区目录无效") }
        let meta = try metadata(folder), remote = try bindingURL(folder)
        guard fm.fileExists(atPath: meta.path) else { throw AppError(text: "基线不存在，拒绝删除") }
        let quarantine = base.appendingPathComponent(".delete-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: quarantine, withIntermediateDirectories: false)
        let savedFolder = quarantine.appendingPathComponent("workspace", isDirectory: true)
        let savedMeta = quarantine.appendingPathComponent("baseline.json")
        let savedRemote = quarantine.appendingPathComponent("binding.remote")
        do {
            try fm.moveItem(at: folder, to: savedFolder)
            try fm.moveItem(at: meta, to: savedMeta)
            if fm.fileExists(atPath: remote.path) { try fm.moveItem(at: remote, to: savedRemote) }
        } catch {
            do {
                if fm.fileExists(atPath: savedRemote.path) { try fm.moveItem(at: savedRemote, to: remote) }
                if fm.fileExists(atPath: savedMeta.path) { try fm.moveItem(at: savedMeta, to: meta) }
                if fm.fileExists(atPath: savedFolder.path) { try fm.moveItem(at: savedFolder, to: folder) }
                try fm.removeItem(at: quarantine)
            } catch { throw AppError(text: "删除准备失败且恢复不完整，数据留在 \(quarantine.path)，请勿清理：\(error.localizedDescription)") }
            throw error
        }
        do { try fm.removeItem(at: quarantine) }
        catch { throw AppError(text: "清理未完成；剩余数据位于 \(quarantine.path)，请手动确认后处理：\(error.localizedDescription)") }
    }
    static func readableName(_ proposed: String) -> String {
        let cleaned = proposed.map { $0 == "/" || $0 == "\\" || $0 == ":" || $0.isNewline ? "-" : String($0) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." || cleaned.hasPrefix(".") ? "workspace" : String(cleaned.prefix(100))
    }
    static func availableFolder(_ proposed: String) throws -> URL {
        let base = try root(), name = readableName(proposed)
        var candidate = base.appendingPathComponent(name, isDirectory: true), number = 2
        func occupied(_ url: URL) throws -> Bool {
            let meta = try metadata(url), remote = try bindingURL(url)
            return FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: meta.path) || FileManager.default.fileExists(atPath: remote.path)
        }
        while try occupied(candidate) {
            candidate = base.appendingPathComponent(name + "-" + String(number), isDirectory: true); number += 1
        }
        return candidate
    }
    // Explicit user operation; no automatic directory migration during refresh.
    static func renameWorkspace(_ folder: URL, to proposed: String) throws -> URL {
        guard try LinkedWorkspaces.identifier(folder) == nil else { throw AppError(text: "关联原目录请在苹果“文件”中重命名，然后重新关联") }
        let fm = FileManager.default
        guard folder.standardizedFileURL.deletingLastPathComponent() == (try root()).standardizedFileURL,
              try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AppError(text: "拒绝重命名工作区外路径") }
        let destination = try availableFolder(proposed)
        let oldMeta = try metadata(folder), newMeta = try metadata(destination)
        let oldBinding = try bindingURL(folder), newBinding = try bindingURL(destination)
        var movedFolder = false, movedMeta = false, movedBinding = false
        do {
            try fm.moveItem(at: folder, to: destination); movedFolder = true
            try fm.moveItem(at: oldMeta, to: newMeta); movedMeta = true
            if fm.fileExists(atPath: oldBinding.path) { try fm.moveItem(at: oldBinding, to: newBinding); movedBinding = true }
            return destination
        } catch {
            do {
                if movedBinding { try fm.moveItem(at: newBinding, to: oldBinding) }
                if movedMeta { try fm.moveItem(at: newMeta, to: oldMeta) }
                if movedFolder { try fm.moveItem(at: destination, to: folder) }
            } catch { throw AppError(text: "重命名回滚失败；请保留 \(folder.path) 与 \(destination.path)，不要清理：\(error.localizedDescription)") }
            throw error
        }
    }
    static func importFolder(_ source: URL, name: String? = nil) throws -> URL {
        let fm = FileManager.default
        guard try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw AppError(text: "请选择真实文件夹；ZIP 请使用单独的 ZIP 导入按钮")
        }
        // Validate before copying so rejected links cannot be followed by a provider.
        _ = try snapshot(source)
        _ = try root()
        // Always use a fresh directory: never overwrite a previous local checkout.
        let destination = try availableFolder(name ?? source.lastPathComponent)
        do {
            try fm.copyItem(at: source, to: destination)
            let baseline = try snapshot(destination)
            try JSONEncoder().encode(baseline).write(to: metadata(destination), options: .atomic)
            return destination
        } catch { try? fm.removeItem(at: destination); throw error }
    }
}

struct WorkspaceView: View {
    @ObservedObject var api: GitHub
    @State private var roots: [URL] = []
    @State private var changes: [LocalChange] = []
    @State private var importRequest: WorkspaceImportRequest?
    @State private var busy = false
    @State private var message = ""
    @State private var folder: URL?
    @State private var binding: WorkspaceBinding?
    @State private var repo = ""
    @State private var branch = ""
    @State private var baselineRevision = ""
    @EnvironmentObject private var selectionStore: WorkspaceSelectionStore
    @State private var hasScanned = false
    private var selectionScope: WorkspaceSelectionScope? {
        guard let folder else { return nil }
        return WorkspaceSelectionScope(accountID: api.accountID, folder: folder, repository: binding?.repo ?? "", branch: binding?.branch ?? "")
    }
    private var selected: Set<String> {
        guard let selectionScope else { return [] }
        return selectionStore.session.selected(in: selectionScope)
    }
    @State private var commitMessage = ""
    @State private var scannedSnapshot: LocalSnapshot?
    @State private var scannedFolder: URL?
    private var commitBlockReason: String? {
        WorkspaceCommitEligibility.reason(binding: binding, selected: selected, scanned: scannedSnapshot,
            sameWorkspace: folder != nil && folder == scannedFolder, message: commitMessage)
    }
    @State private var confirming = false
    @State private var pull: WorkspacePull?
    @State private var pullChoices: [String: Bool] = [:]
    @State private var resolvingPull = false
    @State private var checkPending: WorkspacePull?
    @State private var pendingDelete: URL?
    @State private var pendingDetach: URL?
    @State private var confirmDetach = false
    @State private var confirmDelete = false
    @State private var confirmDirtyDelete = false
    @State private var deletionIsDirty = false
    @State private var confirmPull = false
    @State private var renameName = ""
    @State private var confirmingRename = false
    @State private var showRemoteImport = false
    @State private var showAssociation = false
    @State private var showDetails = false
    @State private var publishing = false
    private enum Field: Hashable { case remoteRepo, remoteBranch, associationRepo, associationBranch, baselineRevision, commitMessage }
    @FocusState private var focusedField: Field?
    var body: some View {
        NavigationStack { workspaceAlerts }
    }

    // Bound each opaque view expression without changing modifier order,
    // navigation ownership, or presentation identity.
    private var workspaceContent: some View {
        List {
            localSection
            associationManagementSection
            if let folder = folder {
                workspaceManagement(folder)
                changesSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("本地工作区")
        .adaptiveWorkspaceLayout()
        .refreshable { await scan() }
        .scrollDismissesKeyboard(.interactively)
        .onSubmit { focusedField = nil }
        .onChange(of: importRequest?.id) { _ in focusedField = nil }
        .onChange(of: folder) { _ in focusedField = nil }
        .onDisappear { focusedField = nil }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("下载远端建立可靠基线") { showRemoteImport = true }
                    Button("导入一个或多个文件夹") { importRequest = WorkspaceImportRequest(kind: .folder) }
                    Button("导入一个或多个 ZIP") { importRequest = WorkspaceImportRequest(kind: .zip) }
                } label: { Image(systemName: "plus") }.disabled(busy)
            }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focusedField = nil } } }
    }

    private var workspacePresentations: some View {
        workspaceContent
        .sheet(isPresented: $showRemoteImport) {
            NavigationStack { List { remoteSection }.navigationTitle("导入远端").toolbar { Button("关闭") { showRemoteImport = false }.disabled(busy) } }
        }
        .sheet(isPresented: $showAssociation) {
            NavigationStack { List { if let folder { bindingSection(folder) } }.navigationTitle("关联仓库 / 分支").toolbar { Button("关闭") { showAssociation = false }.disabled(busy) } }
        }
        .sheet(isPresented: $showDetails) {
            NavigationStack { List { if let folder { bindingSection(folder) } }.navigationTitle("工作区详情").toolbar { Button("关闭") { showDetails = false } } }
        }
        .sheet(isPresented: $publishing) { ReleaseEntryView(api: api, initialRepo: binding?.repo ?? "", initialBranch: binding?.branch ?? "") }
        .confirmationDialog("检查远端更新？此操作不会修改本地文件；检查完成后仍需确认才会拉取。", isPresented: $confirmPull, titleVisibility: .visible) {
            Button("检查更新") { Task { await checkRemote() } }
            Button("取消", role: .cancel) {}
        }
        .task { if !hasScanned { folder = selectionStore.session.rememberedFolder(accountID: api.accountID); await scan() } }
        .sheet(item: $importRequest) { request in
            WorkspaceDocumentPicker(request: request) { urls in
                importRequest = nil
                guard let urls else { return }
                Task { await importItems(urls, zip: request.isZIP) }
            }
            .id(request.id)
        }
        .sheet(isPresented: $resolvingPull, onDismiss: { discardPull() }) { conflictSheet }
    }

    private var workspaceConfirmations: some View {
        workspacePresentations
        .confirmationDialog("确认提交到 \(binding?.repo ?? "") · \(binding?.branch ?? "")？包含勾选的删除操作。", isPresented: $confirming, titleVisibility: .visible) {
            Button("确认提交 \(selected.count) 项") { Task { await commit() } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("永久删除所选实际目录及其全部内容？\n\(pendingDelete?.path ?? "")\n不会删除父目录、其他文件夹或 GitHub 远端。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("继续删除所选目录", role: .destructive) { inspectDeletion() }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
        .confirmationDialog("仅解除关联，保留原目录及全部文件：\n\(pendingDetach?.path ?? "")", isPresented: $confirmDetach, titleVisibility: .visible) {
            Button("解除关联（保留文件）") {
                guard let target = pendingDetach else { return }
                do {
                    try LinkedWorkspaces.detach(target)
                    if folder == target { folder = nil }
                    Task { await scan() }
                } catch { message = error.localizedDescription }
                pendingDetach = nil
            }
            Button("取消", role: .cancel) { pendingDetach = nil }
        }
        .confirmationDialog((deletionIsDirty ? "此目录有未提交更改，删除后无法恢复。" : "再次确认永久删除实际目录及全部内容。") + "\n" + (pendingDelete?.path ?? ""), isPresented: $confirmDirtyDelete, titleVisibility: .visible) {
            Button("永久删除未提交更改与工作区", role: .destructive) { deleteSelected() }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
    }

    private var workspaceAlerts: some View {
        workspaceConfirmations
        .alert("重命名实际工作区目录", isPresented: $confirmingRename) {
            TextField("可读目录名", text: $renameName)
            Button("重命名") { Task { await renameCurrentWorkspace() } }
            Button("取消", role: .cancel) {}
        } message: { Text("将同步移动文件及基线记录，保留勾选。不会修改远端；请勿同时在文件 App 移动目录。") }
        .alert("提示", isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) {
            Button("好", role: .cancel) { message = "" }
        } message: { Text(message) }
        .sheet(item: $checkPending, onDismiss: { discardCheck() }) { pending in
            NavigationStack {
                List {
                    if pending.binding.head == binding?.head { Text("远端无新提交，本地更改保持不变。").softGroupedRow(top: true, bottom: true) }
                    else {
                        Text("下列路径是远端相对当前基线的实际变更；拉取会按三方合并，冲突另行逐项确认。").softGroupedRow(top: true)
                        ForEach(WorkspaceMerge.remoteChanges(base: binding?.snapshot ?? LocalSnapshot(), remote: pending.binding.snapshot), id: \.path) { change in
                            LabeledContent(change.path, value: change.kind).softGroupedRow(bottom: change.path == WorkspaceMerge.remoteChanges(base: binding?.snapshot ?? LocalSnapshot(), remote: pending.binding.snapshot).last?.path)
                        }
                        if WorkspaceMerge.remoteChanges(base: binding?.snapshot ?? LocalSnapshot(), remote: pending.binding.snapshot).isEmpty { Text("提交改变，但文件内容未变。").softGroupedRow(bottom: true) }
                    }
                }
                .navigationTitle("远端更新检查")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("稍后") { discardCheck() } }
                    if pending.binding.head != binding?.head {
                        ToolbarItem(placement: .confirmationAction) { Button("确认拉取") { Task { await pullChecked() } }.disabled(busy) }
                    }
                }
            }.interactiveDismissDisabled(busy)
        }
    }
    private var remoteSection: some View {
Section("从远端建立工作区") {
                    TextField("仓库链接", text: $repo).focused($focusedField, equals: .remoteRepo).submitLabel(.done).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow(top: true)
                    TextField("分支（空白为默认分支）", text: $branch).focused($focusedField, equals: .remoteBranch).submitLabel(.done).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow()
                    Button("下载远端并建立可靠基线") { Task { await downloadRemote() } }.disabled(busy).softGroupedRow(bottom: true)
                }
    }

    private var localSection: some View {
Section("本地工作目录") {
                    Text("文件夹直接关联原目录，修改后刷新变更；ZIP 导入为内部副本。") .font(.caption).softGroupedRow(top: true, bottom: roots.isEmpty)
                    ForEach(roots, id: \.path) { root in
                        Button { folder = root; Task { await scan() } } label: {
                            VStack(alignment: .leading) {
                                Label(root.lastPathComponent, systemImage: folder == root ? "checkmark.circle.fill" : "folder")
                                if let linked = try? LocalStore.binding(root) {
                                    Text(linked.repo + " · " + linked.branch).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.disabled(busy)
                        .softGroupedRow(bottom: root == roots.last)
                        .contextMenu {
                            Button("删除本地工作区", role: .destructive) { pendingDelete = root; confirmDelete = true }
                        }
                    }
                }
    }

    private var associationManagementSection: some View {
        let paths = (try? LinkedWorkspaces.registeredPaths()) ?? []
        return Group {
            if !paths.isEmpty {
                Section("原目录授权") {
                    Menu("管理关联（保留文件）") {
                        ForEach(paths, id: \.path) { path in
                            Button(path.path) { pendingDetach = path; confirmDetach = true }
                        }
                    }.disabled(busy).softGroupedRow(top: true, bottom: true)
                }
            }
        }
    }

    private func workspaceManagement(_ folder: URL) -> some View {
        let linked = (try? LinkedWorkspaces.identifier(folder)) != nil
        return Section {
            if let binding { Text(binding.repo + " / " + binding.branch).font(.headline).softGroupedRow(top: true) }
            Menu("工作区…") {
                if !linked {
                    Button("检查远端更新") { focusedField = nil; confirmPull = true }.disabled(busy || binding == nil)
                }
                Button("关联仓库 / 分支") { showAssociation = true }
                if !linked {
                    Button("重命名实际目录") { renameName = folder.lastPathComponent; confirmingRename = true }
                }
                Button("工作区详情") { showDetails = true }
                Button("发布为发行版") { publishing = true }
                Button("删除本地工作区", role: .destructive) { pendingDelete = folder; confirmDelete = true }
            }.disabled(busy).softGroupedRow(top: binding == nil, bottom: !linked)
            if linked {
                Text("直接使用苹果‘文件’中的原目录。重命名请在‘文件’中操作后重新关联；关联目录暂不支持拉取覆盖。").font(.caption).softGroupedRow(bottom: true)
            }
        }
    }

    private func bindingSection(_ folder: URL) -> some View {
        let linked = (try? LinkedWorkspaces.identifier(folder)) != nil
        return Section("关联仓库 / 分支") {
                        Text("实际工作目录：" + folder.path)
                            .font(.caption).textSelection(.enabled).softGroupedRow(top: true)
                        Button("复制实际工作目录路径") { UIPasteboard.general.string = folder.path }.softGroupedRow()
                        Text("包含隐藏文件，仅扫描时忽略 .git；拒绝符号链接。ZIP：最多 20,000 项、单文件 512 MiB、总计 1 GiB。").font(.caption2).softGroupedRow()
                        Text("绝对路径：" + folder.path).font(.caption2).textSelection(.enabled).softGroupedRow()
                        if !linked { Button("重命名实际目录") {
                            renameName = binding?.repo.replacingOccurrences(of: "/", with: "-") ?? folder.lastPathComponent
                            focusedField = nil; confirmingRename = true
                        }.disabled(busy).softGroupedRow() }
                        if let binding = binding {
                            Text(binding.repo + " · " + binding.branch).softGroupedRow()
                            Text("基线 " + String(binding.head.prefix(12))).font(.caption).softGroupedRow()
                            if let d = binding.remoteAuthorDate { Text("最新提交 author：" + ChinaDate.dateTime(d)).font(.caption).softGroupedRow() }
                            if let d = binding.remoteCommitterDate { Text("最新提交 committer：" + ChinaDate.dateTime(d)).font(.caption).softGroupedRow() }
                            if let d = binding.lastChecked { Text("上次检查：" + ChinaDate.dateTime(d)).font(.caption).softGroupedRow() }
                            if let d = binding.lastPulled { Text("上次拉取：" + ChinaDate.dateTime(d)).font(.caption).softGroupedRow() }
                            if !linked { Button("检查更新") { focusedField = nil; confirmPull = true }
                                .buttonStyle(.borderless)
                                .disabled(busy).softGroupedRow() }
                            Button("删除本地工作区", role: .destructive) { pendingDelete = folder; confirmDelete = true }
                                .buttonStyle(.borderless)
                                .disabled(busy).softGroupedRow(bottom: true)
                        } else {
                            TextField("仓库链接", text: $repo).focused($focusedField, equals: .associationRepo).submitLabel(.done).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow()
                            TextField("分支（空白为默认分支）", text: $branch).focused($focusedField, equals: .associationBranch).submitLabel(.done).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow()
                            TextField("原始 ZIP 历史 commit（可选，如 9230587）", text: $baselineRevision).focused($focusedField, equals: .baselineRevision).submitLabel(.done).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow()
                            Button("验证副本并关联当前远端") { focusedField = nil; Task { await associate(folder) } }.disabled(busy).softGroupedRow()
                            Text("验证原始导入哈希，不使用编辑后的文件作基线。旧 ZIP 请填写确切历史 commit；关联保留当前编辑和删除。分支已前进时须手动检查／拉取后提交。") .font(.caption).softGroupedRow(bottom: true)
                        }
                    }
    }

    private var changesSection: some View {
Section("本地变更预览 / 勾选提交") {
                        if changes.isEmpty {
                            // One stable text row: busy does not replace/fade its font or identity.
                            Text("暂无变更")
                                .softGroupedRow(top: true)
                        }
                        if busy {
                            ProgressView("处理中，请保持前台…").softGroupedRow()
                        }
                        if binding == nil {
                            Text("本地新增、修改、删除均可先勾选；尚未建立可靠远端基线，提交暂不可用。可验证原始导入快照及对应历史 commit 来关联，保留当前编辑。无需让当前本地内容等于远端；远端前进后请检查并三方拉取，冲突逐项确认。")
                                .font(.caption).foregroundStyle(.secondary).softGroupedRow(top: !changes.isEmpty && !busy)
                        }
                        ForEach(changes) { change in
                            HStack {
                                Button {
                                    if let selectionScope { selectionStore.session.toggle(change.path, in: selectionScope) }
                                } label: {
                                    Image(systemName: selected.contains(change.path) ? "checkmark.circle.fill" : "circle")
                                        .frame(width: 44, height: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                .accessibilityLabel("勾选 " + change.relativePath)
                                .accessibilityValue(selected.contains(change.path) ? "已勾选" : "未勾选")
                                .accessibilityHint(busy ? "处理中，请稍候" : "轻点切换本地选择；远端提交资格单独检查")
                                .disabled(busy)
                                NavigationLink { LocalDiffView(change: change) } label: { VStack(alignment: .leading) { Text(change.relativePath); Text(change.kind).font(.caption) } }
                            }.softGroupedRow(top: change.id == changes.first?.id && binding != nil && !busy)
                        }
                        Button("刷新变更") { Task { await scan() } }.disabled(busy).softGroupedRow(bottom: selected.isEmpty)
                        if !selected.isEmpty {
                        TextField("提交说明", text: $commitMessage).focused($focusedField, equals: .commitMessage).submitLabel(.done).softGroupedRow()
                        Button("提交选中的 \(selected.count) 项") { confirming = true }.disabled(busy || commitBlockReason != nil).softGroupedRow()
                        if let commitBlockReason { Text(commitBlockReason).font(.caption).foregroundStyle(.secondary).softGroupedRow() }
                        Text("修改导入副本后，刷新变更。")
                            .font(.caption).foregroundStyle(.secondary).softGroupedRow(bottom: true)
                        }
                    }
    }

    private var conflictSheet: some View {
                NavigationStack {
                    List {
                        if let pending = pull, let binding = binding {
                            Text("同文件双改或删除/修改冲突不会自动覆盖。请逐项选择；取消不会改变工作区。二进制或大文本仅显示哈希。").softGroupedRow(top: true, bottom: true)
                            ForEach(pending.conflicts, id: \.self) { path in
                                Section(path) {
                                    ScrollView(.horizontal) { Text("基线：" + (binding.snapshot.texts[path] ?? binding.snapshot.hashes[path] ?? "已删除")).fixedSize(horizontal: true, vertical: false) }.softGroupedRow(top: true)
                                    ScrollView(.horizontal) { Text("本地：" + (pending.local.texts[path] ?? pending.local.hashes[path] ?? "已删除")).fixedSize(horizontal: true, vertical: false) }.softGroupedRow()
                                    ScrollView(.horizontal) { Text("远端：" + (pending.binding.snapshot.texts[path] ?? pending.binding.snapshot.hashes[path] ?? "已删除")).fixedSize(horizontal: true, vertical: false) }.softGroupedRow()
                                    Button { pullChoices[path] = false } label: { Label("保留本地", systemImage: pullChoices[path] == false ? "checkmark.circle.fill" : "circle") }.softGroupedRow()
                                    Button { pullChoices[path] = true } label: { Label("采用远端", systemImage: pullChoices[path] == true ? "checkmark.circle.fill" : "circle") }.softGroupedRow(bottom: true)
                                }.font(.system(.caption, design: .monospaced))
                            }
                            Button("安全应用全部选择") { Task { await applyResolvedPull() } }.disabled(busy || pending.conflicts.contains { pullChoices[$0] == nil }).softGroupedRow(top: true, bottom: true)
                        }
                    }.navigationTitle("拉取冲突对照")
                        .toolbar { Button("取消") { resolvingPull = false } }
                }.interactiveDismissDisabled(busy)
    }
    @MainActor private func importItems(_ urls: [URL], zip: Bool) async {
        guard !busy else { return }
        busy = true
        var failures: [String] = []
        for source in urls {
            do {
                let imported = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                    if !zip { return try LinkedWorkspaces.register(source) }
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    var failure: Error?
                    var destination: URL?
                    var coordinationError: NSError?
                    NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
                        do {
                            if zip {
                                let values = try readable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                                    throw AppError(text: "请选择 ZIP 文件，不是文件夹或符号链接")
                                }
                                let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                                defer { try? FileManager.default.removeItem(at: stage) }
                                try WorkspaceZIP.extract(readable, to: stage)
                                let children = try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: [.isDirectoryKey])
                                let content = children.count == 1 && (try? children[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? children[0] : stage
                                destination = try LocalStore.importFolder(content, name: children.count == 1 && content != stage ? content.lastPathComponent : source.deletingPathExtension().lastPathComponent)
                            }
                        } catch { failure = error }
                    }
                    if let error = coordinationError { throw error }
                    if let error = failure { throw error }
                    guard let destination = destination else { throw AppError(text: "文件提供器没有返回可读取内容；请先下载到‘我的 iPhone’，或改用 ZIP 导入") }
                    return destination
                }.value
                folder = imported
            } catch { failures.append(source.lastPathComponent + "：" + error.localizedDescription) }
        }
        busy = false
        await scan()
        if !failures.isEmpty {
            let advice = zip ? "请确认 ZIP 完整且未超过限制；无需再次压缩 ZIP。" : "请先将目录下载到本机；文件提供器无法读取时可尝试 ZIP 导入。"
            message = "以下项目导入失败（成功项目已保留）：\n" + failures.joined(separator: "\n") + "\n" + advice
        }
    }
    @MainActor private func checkRemote() async {
        guard let folder, let binding, !busy else { return }
        busy = true; defer { busy = false }
        do {
            discardCheck()
            let pending = try await api.preparePull(folder, binding: binding)
            var checked = binding
            checked.lastChecked = Date()
            try LocalStore.saveBinding(checked, folder: folder)
            self.binding = checked
            checkPending = pending
        } catch { if !RefreshFailure.isCancellation(error) { message = error.localizedDescription } }
    }
    private func discardCheck() {
        if let pending = checkPending { try? FileManager.default.removeItem(at: pending.remoteFolder) }
        checkPending = nil
    }
    @MainActor private func inspectDeletion() {
        guard let target = pendingDelete, !busy else { return }
        do {
            deletionIsDirty = try !LocalStore.changes([target]).isEmpty
            confirmDirtyDelete = true
        } catch { message = "无法确认未提交更改，拒绝删除：" + error.localizedDescription; pendingDelete = nil }
    }
    @MainActor private func deleteSelected() {
        guard let target = pendingDelete, !busy else { return }
        do {
            try LocalStore.removeWorkspace(target)
            if folder == target { folder = nil; binding = nil; changes = []; scannedSnapshot = nil; discardCheck(); discardPull() }
            pendingDelete = nil
            roots.removeAll { $0 == target }
            selectionStore.session.reconcileWorkspaces(Set(roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }), accountID: api.accountID)
            Task { await scan() }
        } catch { if !RefreshFailure.isCancellation(error) { message = error.localizedDescription }; pendingDelete = nil }
    }
    @MainActor private func downloadRemote() async {
        guard !busy else { return }
        busy = true
        do { folder = try await api.downloadWorkspace(repo: repo.trimmingCharacters(in: .whitespacesAndNewlines), branch: branch.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { if !RefreshFailure.isCancellation(error) { message = error.localizedDescription } }
        busy = false
        await scan()
    }
    @MainActor private func pullChecked() async {
        guard let pending = checkPending, let folder, let binding, !busy else { return }
        checkPending = nil
        await applyPendingPull(pending, folder: folder, binding: binding)
    }
    @MainActor private func applyPendingPull(_ pending: WorkspacePull, folder: URL, binding: WorkspaceBinding) async {
        busy = true
        do {
            guard try await api.workspaceHead(binding.repo, branch: binding.branch) == pending.binding.head else {
                throw AppError(text: "预览后远端分支已变化，请重新检查")
            }
            pullChoices = [:]
            if pending.conflicts.isEmpty {
                defer { try? FileManager.default.removeItem(at: pending.remoteFolder) }
                try LocalStore.applyPull(pending, folder: folder, original: binding, choices: [:])
                message = "拉取完成；远端基线已更新，未提交本地变更已保留。"
            } else { pull = pending; resolvingPull = true }
        } catch { try? FileManager.default.removeItem(at: pending.remoteFolder); if !RefreshFailure.isCancellation(error) { message = error.localizedDescription } }
        busy = false
        if pull == nil { await scan() }
    }
    @MainActor private func applyResolvedPull() async {
        guard let pull = pull, let folder = folder, let binding = binding, !busy else { return }
        busy = true
        do {
            guard try await api.workspaceHead(binding.repo, branch: binding.branch) == pull.binding.head else {
                throw AppError(text: "冲突选择期间远端分支已变化，请重新检查")
            }
            try LocalStore.applyPull(pull, folder: folder, original: binding, choices: pullChoices)
            resolvingPull = false
            discardPull()
            message = "冲突处理完成；采用最新远端作为基线，保留本地的内容仍显示为待提交。"
        } catch { if !RefreshFailure.isCancellation(error) { message = error.localizedDescription } }
        busy = false
        if self.pull == nil { await scan() }
    }
    private func discardPull() {
        if let pull = pull { try? FileManager.default.removeItem(at: pull.remoteFolder) }
        pull = nil; pullChoices = [:]
    }
    @MainActor private func renameCurrentWorkspace() async {
        guard let old = folder, !busy else { return }
        busy = true
        do {
            let new = try LocalStore.renameWorkspace(old, to: renameName)
            selectionStore.session.workspaceRenamed(from: old, to: new)
            folder = new; scannedFolder = nil; scannedSnapshot = nil
            changes = changes.map { LocalChange(path: new.lastPathComponent + "/" + $0.relativePath, kind: $0.kind, before: $0.before, after: $0.after) }
            roots = roots.map { $0 == old ? new : $0 }
            pendingDelete = nil; discardCheck(); discardPull()
        } catch { message = error.localizedDescription }
        busy = false
        await scan()
    }
    @MainActor private func associate(_ folder: URL) async {
        guard !busy else { return }
        busy = true
        let localScope = binding == nil ? selectionScope : nil
        do {
            binding = try await api.associateWorkspace(folder, repo: repo, branch: branch, revision: baselineRevision)
            if let localScope, let remoteScope = selectionScope {
                selectionStore.session.associateLocalSelection(from: localScope, to: remoteScope)
            }
        }
        catch { if !RefreshFailure.isCancellation(error) { message = error.localizedDescription } }
        busy = false
        await scan()
    }
    @MainActor private func commit() async {
        guard let folder = folder, let binding = binding, let scope = selectionScope, !busy, commitBlockReason == nil else { return }
        let generation = AccountStore.generation
        let committing = selected
        var succeeded = false
        busy = true
        do {
            let paths = Set(committing.map { String($0.dropFirst(folder.lastPathComponent.count + 1)) })
            guard let scanned = scannedSnapshot else { throw AppError(text: "请先刷新变更") }
            let persisted = try LocalStore.binding(folder)
            guard persisted.repo == binding.repo, persisted.branch == binding.branch,
                  persisted.head == binding.head, persisted.tree == binding.tree,
                  persisted.snapshot.hashes == binding.snapshot.hashes else {
                throw AppError(text: "磁盘关联与预览已不同，请刷新；未提交")
            }
            guard committing.isSubset(of: Set(changes.map { $0.path })) else { throw AppError(text: "选择已过期，请刷新") }
            let writes = try await Task.detached { try LocalStore.prepare(folder, paths: paths, expected: scanned) }.value
            let updated = try await api.commitWorkspace(binding, writes: writes, message: commitMessage)
            guard generation == AccountStore.generation, selectionScope == scope else { busy = false; return }
            do { try LocalStore.finish(folder, binding: updated, snapshot: scanned, paths: paths) }
            catch { throw AppError(text: "远端提交已成功，但本地基线保存失败。不要重复提交；请备份修改并重新导入。" + error.localizedDescription) }
            guard generation == AccountStore.generation, selectionScope == scope else { busy = false; return }
            selectionStore.session.commitSucceeded(committing, in: scope)
            succeeded = true
            self.binding = updated; commitMessage = ""; message = "已原子提交 \(writes.count) 项变更：" + updated.head
        } catch { if !RefreshFailure.isCancellation(error) { message = error.localizedDescription } }
        busy = false
        if succeeded { await scan() }
    }
    @MainActor private func scan() async {
        guard !busy else { return }
        let generation = AccountStore.generation
        let requestedFolder = folder
        busy = true; defer { busy = false }
        do {
            // Stage every result; failure cannot publish a partial list or prune selections.
            let result = try await Task.detached(priority: .userInitiated) { () throws -> ([URL], URL?, WorkspaceBinding?, [LocalChange], LocalSnapshot?) in
                let roots = try FileManager.default.contentsOfDirectory(at: LocalStore.root(), includingPropertiesForKeys: [.isDirectoryKey]).filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && FileManager.default.fileExists(atPath: (try? LocalStore.metadata($0).path) ?? "")
                } + (try LinkedWorkspaces.roots())
                let target = LocalStore.matchingRoot(requestedFolder, in: roots) ?? roots.first
                guard let target else { return (roots, nil, nil, [], nil) }
                let binding = try? LocalStore.binding(target)
                let before = try LocalStore.snapshot(target)
                let changes = try LocalStore.changes([target])
                let after = try LocalStore.snapshot(target)
                guard before.hashes == after.hashes else { throw AppError(text: "扫描期间文件已变化，请重试") }
                let latestBinding = try? LocalStore.binding(target)
                guard binding?.head == latestBinding?.head, binding?.repo == latestBinding?.repo, binding?.branch == latestBinding?.branch else {
                    throw AppError(text: "扫描期间工作区关联已变化，请重试")
                }
                return (roots, target, binding, changes, after)
            }.value
            try Task.checkCancellation()
            guard generation == AccountStore.generation, api.accountID == AccountStore.activeID, folder == requestedFolder else { return }
            roots = result.0; folder = result.1; binding = result.2
            changes = result.3; scannedSnapshot = result.4; scannedFolder = result.1; hasScanned = true
            selectionStore.session.reconcileWorkspaces(Set(roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }), accountID: api.accountID)
            selectionStore.session.remember(folder, accountID: api.accountID)
            if let selectionScope { selectionStore.session.scanSucceeded(Set(changes.map { $0.path }), in: selectionScope) }
        } catch { if !RefreshFailure.isCancellation(error) { message = error.localizedDescription } }
    }
}

struct LocalDiffView: View {
    let change: LocalChange
    var body: some View { LocalDiffPreview(change: change) }
}
