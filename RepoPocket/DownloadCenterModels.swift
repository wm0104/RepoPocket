import Foundation

/// Stable API identities only. Redirect locations and credentials are never persisted.
enum DownloadSource: Codable, Equatable {
    case file(repo: String, path: String, ref: String, name: String)
    case archive(repo: String, ref: String)
    case releaseAsset(repo: String, id: Int, name: String)
    case artifact(repo: String, id: Int, name: String)
    case local(name: String)

    var name: String {
        switch self {
        case .file(_, _, _, let name), .releaseAsset(_, _, let name), .local(let name): return DownloadRules.safeName(name)
        case .archive(let repo, _): return DownloadRules.safeName(repo.replacingOccurrences(of: "/", with: "-") + ".zip")
        case .artifact(_, _, let name): return DownloadRules.safeName(name) + ".zip"
        }
    }
    var repository: String {
        switch self {
        case .file(let repo, _, _, _), .archive(let repo, _), .releaseAsset(let repo, _, _), .artifact(let repo, _, _): return repo
        case .local: return "RepoPocket 应用更新"
        }
    }
}

struct DownloadRecord: Codable, Identifiable, Equatable {
    enum State: String, Codable { case connecting, downloading, saving, completed, failed, cancelled, interrupted }
    let id: UUID
    let source: DownloadSource
    let created: Date
    var state: State = .connecting
    var received: Int64 = 0
    var total: Int64?
    var fileName: String?
    var fileSize: Int64?
    var message = ""
    var active: Bool { state == .connecting || state == .downloading || state == .saving }
    var retryable: Bool {
        if case .local = source { return false }
        return state == .failed || state == .cancelled || state == .interrupted
    }
    var title: String {
        switch state {
        case .connecting: return "正在连接…"
        case .downloading: return "正在下载"
        case .saving: return "正在保存…"
        case .completed: return "已完成"
        case .failed: return "下载失败"
        case .cancelled: return "已取消"
        case .interrupted: return "已中断，点重试重新下载"
        }
    }
}

struct DownloadHistory {
    let root: URL
    let accountID: String
    var folder: URL { root.appendingPathComponent("github.com-" + accountID, isDirectory: true) }
    private var manifest: URL { folder.appendingPathComponent("history.json") }
    private func prepare() throws {
        guard accountID == "legacy" || (!accountID.isEmpty && accountID.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })) else {
            throw NSError(domain: "DownloadHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: "下载账号标识无效。"])
        }
        try DownloadRules.rejectSymlinks(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    func load() throws -> [DownloadRecord] {
        try prepare()
        try DownloadRules.rejectSymlinks(manifest)
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        var records = try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: manifest))
        for index in records.indices {
            if records[index].active { records[index].state = .interrupted }
            records[index].fileSize = records[index].state == .completed ? fileSize(records[index]) : nil
        }
        try save(records)
        return records
    }
    func save(_ records: [DownloadRecord]) throws {
        try prepare()
        try DownloadRules.rejectSymlinks(manifest)
        try JSONEncoder().encode(records).write(to: manifest, options: .atomic)
    }
    func file(_ record: DownloadRecord) throws -> URL {
        try prepare()
        guard record.state == .completed, let name = record.fileName, DownloadRules.safeName(name) == name else {
            throw NSError(domain: "DownloadHistory", code: 2, userInfo: [NSLocalizedDescriptionKey: "下载文件不可用。"])
        }
        let file = DownloadRules.destinationFolder(in: folder).appendingPathComponent(name)
        try DownloadRules.rejectSymlinks(file)
        guard (try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular else {
            throw NSError(domain: "DownloadHistory", code: 3, userInfo: [NSLocalizedDescriptionKey: "下载文件已移除，请重新下载。"])
        }
        return file
    }
    func fileSize(_ record: DownloadRecord) -> Int64? {
        guard let file = try? file(record),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value, size >= 0 else { return nil }
        return size
    }
    func delete(_ record: DownloadRecord, from records: [DownloadRecord]) throws -> [DownloadRecord] {
        guard records.contains(record), !record.active else { throw CancellationError() }
        let remaining = records.filter { $0.id != record.id }
        var original: URL?
        var staged: URL?
        if record.state == .completed {
            guard let name = record.fileName, DownloadRules.safeName(name) == name else { throw CancellationError() }
            let target = DownloadRules.destinationFolder(in: folder).appendingPathComponent(name)
            try DownloadRules.rejectSymlinks(target)
            if FileManager.default.fileExists(atPath: target.path) {
                let trash = folder.appendingPathComponent(".delete-" + UUID().uuidString)
                try FileManager.default.moveItem(at: file(record), to: trash)
                original = target; staged = trash
            }
        }
        do {
            try save(remaining)
            if let staged { try FileManager.default.removeItem(at: staged) }
        } catch {
            if let staged, let original, FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.moveItem(at: staged, to: original)
            }
            // Keep the original record if saving/deleting fails, rather than lose its file.
            try? save(records)
            throw error
        }
        return remaining
    }
}
