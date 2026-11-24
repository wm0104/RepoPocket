import Foundation
import CryptoKit

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
