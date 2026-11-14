import Foundation
import CryptoKit

struct PendingRepoItem: Identifiable {
    let id = UUID()
    var local: URL?
    var size: Int64
    var path: String?
    var sha: String?
    var head: String?
    mutating func replaceLocal(_ url: URL, size: Int64) {
        // Preserve identity and explicit destination/SHA/head; repo/branch changes invalidate separately.
        local = url; self.size = size
    }
    mutating func select(folder: String, replacementPath: String?, sha: String?, head: String) {
        path = replacementPath ?? local.map { (folder.isEmpty ? "" : folder + "/") + $0.lastPathComponent }
        self.sha = sha; self.head = head
    }
    mutating func inheritTarget(folder: String, head: String, files: [String: String], directories: Set<String>) throws -> Bool {
        guard local != nil else { return false }
        var candidate = self
        candidate.select(folder: folder, replacementPath: nil, sha: nil, head: head)
        guard let path = candidate.path, files[path] == nil else { return false }
        try RepoQueue.validate([candidate], head: head, files: files, directories: directories)
        self = candidate
        return true
    }
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

    static func validate(_ items: [PendingRepoItem], head: String, files: [String: String], directories: Set<String>) throws {
        guard !items.isEmpty else { throw AppError(text: "队列为空") }
        var seen = Set<String>()
        var totalBytes: Int64 = 0
        for item in items {
            guard let path = item.path, item.head == head else { throw AppError(text: "目标或远端已变化，请重新选择每项目标") }
            guard !path.contains("\\"), !path.contains(":"), !path.contains("\0"), path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" }) else { throw AppError(text: "无效目标：" + path) }
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(key).inserted else { throw AppError(text: "重复目标：" + path) }
            guard files[path] == item.sha, item.local != nil || item.sha != nil else { throw AppError(text: "目标 SHA 已变化或未经明确选择替换：" + path) }
            if item.local != nil {
                totalBytes = try addingUploadBytes(item.size, to: totalBytes)
            }
            let otherPaths = Array(files.keys) + Array(directories) + items.compactMap(\.path)
            guard !directories.contains(path), !otherPaths.contains(where: { other in
                let o = other.precomposedStringWithCanonicalMapping.lowercased()
                return (o != key && (o.hasPrefix(key + "/") || (key.hasPrefix(o + "/") && !directories.contains(other)))) || (o == key && other != path)
            }) else { throw AppError(text: "文件/目录或大小写冲突：" + path) }
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
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
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
