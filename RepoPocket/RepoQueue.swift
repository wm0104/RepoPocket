import Foundation
import CryptoKit

struct PendingRepoItem: Identifiable {
    let id = UUID()
    var local: URL?
    var size: Int64
    var path: String?
    var sha: String?
    var head: String?
    mutating func select(folder: String, replacementPath: String?, sha: String?, head: String) {
        path = replacementPath ?? local.map { (folder.isEmpty ? "" : folder + "/") + $0.lastPathComponent }
        self.sha = sha; self.head = head
    }
    mutating func inheritTarget(folder: String, head: String, index: UploadPathIndex) throws -> Bool {
        guard local != nil else { return false }
        var candidate = self
        candidate.select(folder: folder, replacementPath: nil, sha: nil, head: head)
        guard let path = candidate.path, index.fileSHA(at: path) == nil else { return false }
        try RepoQueue.validate([candidate], head: head, index: index)
        self = candidate
        return true
    }
}

struct UploadPathIndex {
    struct Entry {
        let path: String
        let sha: String?
        let mode: String?
    }
    private var entries: [String: Entry] = [:]
    private var ambiguous = Set<String>()

    fileprivate static func prefixes(of path: String, uploadTarget: Bool = true) throws -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\0"), !uploadTarget || (!path.contains("\\") && !path.contains(":")),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && (!uploadTarget || $0.lowercased() != ".git") }) else {
            throw AppError(text: "无效目标：" + path)
        }
        var prefixes: [String] = []
        var prefix = ""
        for component in components {
            if !prefix.isEmpty { prefix += "/" }
            prefix += component
            prefixes.append(prefix)
        }
        return prefixes
    }

    fileprivate func entry(at path: String, directory: Bool) throws -> Entry? {
        let key = path.lowercased()
        guard let existing = entries[key] else { return nil }
        guard !ambiguous.contains(key), existing.path.utf8.elementsEqual(path.utf8), (existing.sha == nil) == directory else {
            throw AppError(text: "文件、目录或名称编码冲突：" + path)
        }
        return existing
    }

    mutating func insert(path: String, sha: String?, mode: String? = nil) throws {
        try insert(Self.prefixes(of: path, uploadTarget: false), sha: sha, mode: mode, remote: true)
    }
    fileprivate mutating func insert(_ prefixes: [String], sha: String?, mode: String?, remote: Bool = false) throws {
        for (offset, path) in prefixes.enumerated() {
            let directory = offset < prefixes.count - 1 || sha == nil
            let key = path.lowercased()
            if let existing = entries[key] {
                if directory, existing.sha == nil, existing.path.utf8.elementsEqual(path.utf8) { continue }
                guard remote else { throw AppError(text: "文件、目录或名称编码冲突：" + path) }
                ambiguous.insert(key)
            } else {
                entries[key] = Entry(path: path, sha: directory ? nil : sha, mode: directory ? nil : mode)
            }
        }
    }
    func fileSHA(at path: String) -> String? { (try? entry(at: path, directory: false))?.sha }
    func fileMode(at path: String) -> String? { (try? entry(at: path, directory: false))?.mode }
    func containsDirectory(_ path: String) -> Bool { (try? entry(at: path, directory: true)) != nil }
}

enum RepoQueue {
    // maximumBytes parameters are inclusive; ordinary uploads must be strictly below 100 MiB.
    static let maximumFileBytes: Int64 = 100 * 1024 * 1024 - 1
    static let maximumTotalUploadBytes: Int64 = maximumFileBytes

    static func addingUploadBytes(_ size: Int64, to total: Int64) throws -> Int64 {
        guard size >= 0, size <= maximumFileBytes else { throw AppError(text: "普通提交单文件必须小于 100 MiB，请使用 Release。") }
        guard total >= 0, total <= maximumTotalUploadBytes,
              size <= maximumTotalUploadBytes - total else { throw AppError(text: "普通提交总原始文件大小必须小于 100 MiB，请使用 Release。") }
        return total + size
    }

    static func readiness(_ items: [PendingRepoItem], repo: String, message: String) -> String? {
        if repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写目标仓库" }
        if items.isEmpty { return "请先添加待提交文件或远端删除" }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写提交说明" }
        var totalBytes: Int64 = 0
        for item in items {
            let label = item.local?.lastPathComponent ?? item.path ?? "远端删除"
            if item.path == nil || item.head == nil { return label + "：请先选择目标（仓库/分支变化后需重新选择）" }
            if let file = item.local {
                if !FileManager.default.fileExists(atPath: file.path) { return label + "：本地临时文件已不存在，请重新选择" }
                do { totalBytes = try addingUploadBytes(item.size, to: totalBytes) }
                catch { return label + "：" + error.localizedDescription }
            }
        }
        return nil
    }

    static func validate(_ items: [PendingRepoItem], head: String, index: UploadPathIndex) throws {
        guard !items.isEmpty else { throw AppError(text: "队列为空") }
        var queued = UploadPathIndex()
        var totalBytes: Int64 = 0
        for item in items {
            guard let path = item.path, item.head == head else { throw AppError(text: "目标或远端已变化，请重新选择每项目标") }
            let prefixes = try UploadPathIndex.prefixes(of: path)
            for parent in prefixes.dropLast() { _ = try index.entry(at: parent, directory: true) }
            let remote = try index.entry(at: path, directory: false)
            guard remote?.sha == item.sha, item.local != nil || item.sha != nil else {
                throw AppError(text: "目标 SHA 已变化或未经明确选择替换：" + path)
            }
            try queued.insert(prefixes, sha: item.sha ?? "", mode: nil)
            if item.local != nil { totalBytes = try addingUploadBytes(item.size, to: totalBytes) }
        }
    }
    static func treeEntries(_ writes: [(String, String?, String)]) -> [[String: Any]] {
        writes.map { ["path": $0.0, "sha": $0.1.map { $0 as Any } ?? NSNull(), "mode": $0.2, "type": "blob"] }
    }
}

struct StreamingBlobHash {
    private var git = Insecure.SHA1()
    private var sha256 = SHA256()
    private(set) var count = 0
    let expectedSize: Int
    init(size: Int) { expectedSize = size; git.update(data: Data("blob \(size)\0".utf8)) }
    mutating func update(_ chunk: Data) throws {
        count += chunk.count
        guard count <= expectedSize else { throw AppError(text: "下载大小超出预期") }
        git.update(data: chunk); sha256.update(data: chunk)
    }
    func finish(expectedGit: String) throws -> String {
        guard count == expectedSize, git.finalize().map({ String(format: "%02x", $0) }).joined() == expectedGit else { throw AppError(text: "下载 blob 大小/SHA1 校验失败") }
        return sha256.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension LocalStore {
    static func snapshotFileSHA256(_ url: URL) throws -> String {
        var hash = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension RepoQueue {
    static func reviewFingerprint(_ items: [PendingRepoItem], repo: String, branch: String, message: String) throws -> String {
        var fields = [repo, branch, message]
        for item in items {
            fields += [item.id.uuidString, item.path ?? "", item.sha ?? "", item.head ?? "", String(item.size)]
            if let file = item.local {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.int64Value == item.size else {
                    throw AppError(text: "本地文件类型或大小已变化，请重新选择并确认。")
                }
                fields.append(try LocalStore.snapshotFileSHA256(file))
            }
        }
        // Length framing avoids collisions between paths, messages and content hashes.
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }

}
