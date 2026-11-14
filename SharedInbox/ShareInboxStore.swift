import Foundation

struct ShareInboxItem: Codable, Identifiable {
    let id: UUID
    let name: String
    let size: Int64
    let created: Date
}

enum ShareInboxError: LocalizedError {
    case unavailable, invalidFile, invalidItem
    var errorDescription: String? {
        switch self {
        case .unavailable: return "共享文件夹不可用，请确认使用支持分享扩展的安装方式。"
        case .invalidFile: return "只能导入普通文件；文件夹请先压缩为 ZIP。"
        case .invalidItem: return "文件已移除或路径无效，请刷新列表。"
        }
    }
}

/// Only owns UUID children under its private inbox. Source URLs are never mutated.
struct ShareInboxStore {
    static let group = "group.com.wm0104.RepoPocket.shared"
    let root: URL
    static func live() throws -> ShareInboxStore {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw ShareInboxError.unavailable }
        return ShareInboxStore(root: container.appendingPathComponent("Library/Application Support/ShareInbox", isDirectory: true))
    }
    private func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    private func regular(_ file: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard (try FileManager.default.attributesOfItem(atPath: root.path))[.type] as? FileAttributeType == .typeDirectory else { throw ShareInboxError.invalidItem }
    }
    func importFile(_ source: URL, name: String? = nil, cancelled: () -> Bool = { false }) throws -> ShareInboxItem {
        let fm = FileManager.default
        let name = name ?? source.lastPathComponent
        guard safeName(name), source.isFileURL else { throw ShareInboxError.invalidFile }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard regular(source) else { throw ShareInboxError.invalidFile }
        try prepare()
        let id = UUID()
        let stage = root.appendingPathComponent(".staging-" + id.uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        var published = false
        defer { if !published { try? fm.removeItem(at: stage) } }
        let content = stage.appendingPathComponent("content", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: false)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
            do {
                if cancelled() { throw CancellationError() }
                guard regular(coordinated) else { throw ShareInboxError.invalidFile }
                try fm.copyItem(at: coordinated, to: content.appendingPathComponent(name))
            } catch { copyError = error }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
        if cancelled() { throw CancellationError() }
        let file = content.appendingPathComponent(name)
        guard regular(file) else { throw ShareInboxError.invalidFile }
        let size = (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        let item = ShareInboxItem(id: id, name: name, size: size, created: Date())
        try JSONEncoder().encode(item).write(to: stage.appendingPathComponent("metadata.json"), options: .atomic)
        if cancelled() { throw CancellationError() }
        try fm.moveItem(at: stage, to: root.appendingPathComponent(id.uuidString, isDirectory: true))
        published = true
        return item
    }
    func file(_ item: ShareInboxItem) throws -> URL {
        let folder = root.appendingPathComponent(item.id.uuidString, isDirectory: true)
        let content = folder.appendingPathComponent("content", isDirectory: true)
        guard safeName(item.name),
              (try? FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType) == .typeDirectory,
              (try? FileManager.default.attributesOfItem(atPath: content.path)[.type] as? FileAttributeType) == .typeDirectory else { throw ShareInboxError.invalidItem }
        let file = content.appendingPathComponent(item.name)
        guard regular(file), file.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path == root.resolvingSymlinksInPath().path else { throw ShareInboxError.invalidItem }
        return file
    }
    func items() throws -> [ShareInboxItem] {
        try prepare()
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { folder -> ShareInboxItem? in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  (try? FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType) == .typeDirectory,
                  let data = try? Data(contentsOf: folder.appendingPathComponent("metadata.json")),
                  let item = try? JSONDecoder().decode(ShareInboxItem.self, from: data), item.id == id,
                  (try? file(item)) != nil else { return nil }
            return item
        }.sorted { $0.created > $1.created }
    }
    func remove(_ item: ShareInboxItem) throws {
        _ = try file(item)
        try FileManager.default.removeItem(at: root.appendingPathComponent(item.id.uuidString, isDirectory: true))
    }
    /// A picker exports disposable copies, so deleting an inbox row cannot invalidate an upload.
    func stage(_ items: [ShareInboxItem]) throws -> [URL] {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("ShareSelection-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        do {
            return try items.map { item in
                let folder = stage.appendingPathComponent(item.id.uuidString, isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                let target = folder.appendingPathComponent(item.name)
                try fm.copyItem(at: file(item), to: target)
                return target
            }
        } catch { try? fm.removeItem(at: stage); throw error }
    }
}
