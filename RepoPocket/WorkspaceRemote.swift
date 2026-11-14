import Foundation
import CryptoKit

struct WorkspaceBinding: Codable {
    let repo: String
    let branch: String
    var head: String
    var tree: String
    var modes: [String: String]
    var snapshot: LocalSnapshot
    // Persisted phone-side audit times; optional for pre-0.4 bindings.
    var remoteAuthorDate: Date?
    var remoteCommitterDate: Date?
    var lastChecked: Date?
    var lastPulled: Date?
    enum CodingKeys: String, CodingKey { case repo, branch, head, tree, modes, snapshot, remoteAuthorDate, remoteCommitterDate, lastChecked, lastPulled }
    init(repo: String, branch: String, head: String, tree: String, modes: [String: String], snapshot: LocalSnapshot, remoteAuthorDate: Date? = nil, remoteCommitterDate: Date? = nil, lastChecked: Date? = nil, lastPulled: Date? = nil) {
        self.repo = repo; self.branch = branch; self.head = head; self.tree = tree; self.modes = modes; self.snapshot = snapshot
        self.remoteAuthorDate = remoteAuthorDate; self.remoteCommitterDate = remoteCommitterDate; self.lastChecked = lastChecked; self.lastPulled = lastPulled
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decode(String.self, forKey: .repo); branch = try c.decode(String.self, forKey: .branch); head = try c.decode(String.self, forKey: .head); tree = try c.decode(String.self, forKey: .tree); modes = try c.decode([String:String].self, forKey: .modes); snapshot = try c.decode(LocalSnapshot.self, forKey: .snapshot)
        remoteAuthorDate = try c.decodeIfPresent(Date.self, forKey: .remoteAuthorDate); remoteCommitterDate = try c.decodeIfPresent(Date.self, forKey: .remoteCommitterDate); lastChecked = try c.decodeIfPresent(Date.self, forKey: .lastChecked); lastPulled = try c.decodeIfPresent(Date.self, forKey: .lastPulled)
    }
}

enum WorkspaceCommitEligibility {
    static func reason(binding: WorkspaceBinding?, selected: Set<String>, scanned: LocalSnapshot?, sameWorkspace: Bool, message: String) -> String? {
        guard let binding, !binding.repo.isEmpty, !binding.branch.isEmpty, !binding.head.isEmpty, !binding.tree.isEmpty else { return "提交不可用：请先建立可靠远端基线；本地勾选不受影响。" }
        guard sameWorkspace, scanned != nil else { return "提交不可用：请刷新当前工作区变更。" }
        guard !selected.isEmpty else { return "提交不可用：请勾选本地变更。" }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "提交不可用：请填写提交说明。" }
        return nil
    }
}

enum WorkspaceAssociationDiagnostics {
    static func mismatch(local: [String: String], remote: [String: String], repo: String, branch: String, head: String) -> String? {
        guard local != remote else { return nil }
        let missing = remote.keys.filter { local[$0] == nil }.sorted()
        let extra = local.keys.filter { remote[$0] == nil }.sorted()
        let changed = remote.keys.filter { local[$0] != nil && local[$0] != remote[$0] }.sorted()
        let samples = (missing.prefix(3).map { "缺少：" + $0 } + extra.prefix(3).map { "多出：" + $0 } + changed.prefix(3).map { "内容不同：" + $0 }).joined(separator: "\n")
        return "仓库已找到：\(repo)\n分支：\(branch) · 当前提交：\(head.prefix(12))\n关联未建立：本地副本与该提交不同（缺少 \(missing.count)、多出 \(extra.count)、内容不同 \(changed.count)）。\n\(samples)\n仓库输入正确不代表副本版本一致。请确认分支和文件夹层级；若已编辑，请保留副本，不要覆盖。可用‘下载远端并建立可靠基线’另建工作区。"
    }
}

struct WorkspaceWrite {
    let path: String
    let bytes: Data?
}
struct WorkspaceBlob: Decodable { let content: String; let encoding: String; let size: Int }
struct GitObject: Decodable { let sha: String }
struct GitReference: Decodable { let object: GitObject }
struct GitCommitInfo: Decodable {
    let sha: String
    let tree: GitObject
    struct Person: Decodable { let date: Date? }
    let author: Person?
    let committer: Person?
}
struct GitTreeInfo: Decodable {
    struct Item: Decodable { let path: String; let mode: String; let type: String; let sha: String; let size: Int? }
    let tree: [Item]
    let truncated: Bool
}

extension LocalStore {
    static func bindingURL(_ folder: URL) throws -> URL {
        try metadata(folder).appendingPathExtension("remote")
    }
    static func binding(_ folder: URL) throws -> WorkspaceBinding {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkspaceBinding.self, from: Data(contentsOf: bindingURL(folder)))
    }
    static func saveBinding(_ binding: WorkspaceBinding, folder: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(binding).write(to: bindingURL(folder), options: .atomic)
    }
    static func gitHashes(_ folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for path in try snapshot(folder).hashes.keys {
            let url = folder.appendingPathComponent(path)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            var hash = Insecure.SHA1()
            hash.update(data: Data("blob \(size)\0".utf8))
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty { hash.update(data: data) }
            result[path] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
    static func prepare(_ folder: URL, paths: Set<String>, expected: LocalSnapshot) throws -> [WorkspaceWrite] {
        let current = try snapshot(folder)
        guard current.hashes == expected.hashes else { throw AppError(text: "扫描后文件已变化，请刷新并重新勾选") }
        return try paths.sorted().map { path in
            guard !path.isEmpty, path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), !path.contains("\\") else { throw AppError(text: "无效工作区路径") }
            guard current.hashes[path] != nil else { return WorkspaceWrite(path: path, bytes: nil) }
            let url = folder.appendingPathComponent(path)
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 10 * 1024 * 1024 else {
                throw AppError(text: "\(path) 超过普通提交 10 MiB 限制，请取消勾选并使用 Release 附件")
            }
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 10 * 1024 * 1024,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == current.hashes[path] else {
                throw AppError(text: "读取期间文件已变化或超限，请刷新")
            }
            return WorkspaceWrite(path: path, bytes: bytes)
        }
    }
    static func finish(_ folder: URL, binding: WorkspaceBinding, snapshot: LocalSnapshot, paths: Set<String>) throws {
        var updated = binding
        for path in paths { updated.snapshot.hashes[path] = snapshot.hashes[path]; updated.snapshot.texts[path] = snapshot.texts[path] }
        // Head and partial baseline advance together in one atomic record.
        try saveBinding(updated, folder: folder)
    }
}

struct WorkspacePull: Identifiable {
    let id = UUID()
    let binding: WorkspaceBinding
    let local: LocalSnapshot
    let remoteFolder: URL
    let conflicts: [String]
}

enum WorkspaceMerge {
    static func remoteChanges(base: LocalSnapshot, remote: LocalSnapshot) -> [LocalChange] {
        Set(base.hashes.keys).union(remote.hashes.keys).sorted().compactMap { path in
            guard base.hashes[path] != remote.hashes[path] else { return nil }
            return LocalChange(path: path, kind: base.hashes[path] == nil ? "新增" : (remote.hashes[path] == nil ? "删除" : "修改"), before: base.texts[path], after: remote.texts[path])
        }
    }
    // nil denotes absence, so additions and deletion/modification conflicts use the same rule.
    static func conflicts(base: LocalSnapshot, local: LocalSnapshot, remote: LocalSnapshot) -> [String] {
        Set(base.hashes.keys).union(local.hashes.keys).union(remote.hashes.keys).filter {
            local.hashes[$0] != base.hashes[$0] && remote.hashes[$0] != base.hashes[$0] && local.hashes[$0] != remote.hashes[$0]
        }.sorted()
    }
    static func remotePaths(base: LocalSnapshot, local: LocalSnapshot, remote: LocalSnapshot, choices: [String: Bool]) -> [String] {
        Set(base.hashes.keys).union(local.hashes.keys).union(remote.hashes.keys).filter {
            if let useRemote = choices[$0] { return useRemote }
            return local.hashes[$0] == base.hashes[$0]
        }.sorted()
    }
}

extension LocalStore {
    static func applyPull(_ pull: WorkspacePull, folder: URL, original: WorkspaceBinding, choices: [String: Bool]) throws {
        let fm = FileManager.default
        guard pull.conflicts.allSatisfy({ choices[$0] != nil }) else { throw AppError(text: "请逐项解决冲突") }
        guard try snapshot(folder).hashes == pull.local.hashes,
              try binding(folder).head == original.head else { throw AppError(text: "拉取期间本地或基线已变化，请重新拉取") }
        let stage = folder.deletingLastPathComponent().appendingPathComponent(".pull-" + UUID().uuidString)
        let backup = folder.deletingLastPathComponent().appendingPathComponent(".backup-" + UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: folder, to: stage)
        let paths = WorkspaceMerge.remotePaths(base: original.snapshot, local: pull.local, remote: pull.binding.snapshot, choices: choices)
        // Delete first, including directories replaced by files; unchanged local descendants are conflicts.
        for path in paths.sorted(by: { $0.count > $1.count }) {
            let target = stage.appendingPathComponent(path)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        }
        for path in paths where pull.binding.snapshot.hashes[path] != nil {
            let target = stage.appendingPathComponent(path)
            var ancestor = target.deletingLastPathComponent()
            while ancestor.path != stage.path {
                var directory: ObjCBool = false
                if fm.fileExists(atPath: ancestor.path, isDirectory: &directory), !directory.boolValue {
                    throw AppError(text: "文件/目录结构冲突：" + path + "；请先调整本地结构")
                }
                ancestor.deleteLastPathComponent()
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: pull.remoteFolder.appendingPathComponent(path), to: target)
        }
        var expected = pull.local.hashes
        for path in paths { expected[path] = pull.binding.snapshot.hashes[path] }
        guard try snapshot(stage).hashes == expected else { throw AppError(text: "文件/目录冲突会覆盖未提交文件，已取消应用") }
        guard try snapshot(folder).hashes == pull.local.hashes else { throw AppError(text: "安全应用前本地已变化，请重新拉取") }
        let oldRecord = try Data(contentsOf: bindingURL(folder))
        try fm.moveItem(at: folder, to: backup)
        do {
            try fm.moveItem(at: stage, to: folder)
            var applied = pull.binding
            applied.lastPulled = Date()
            try saveBinding(applied, folder: folder)
        } catch {
            // Keep backup until both worktree and the baseline record are durable.
            try? fm.removeItem(at: folder)
            do {
                try fm.moveItem(at: backup, to: folder)
                try oldRecord.write(to: bindingURL(folder), options: .atomic)
            } catch { throw AppError(text: "回滚失败；原工作区仍保存在 " + backup.path + "：" + error.localizedDescription) }
            throw error
        }
        try? fm.removeItem(at: backup)
    }
}
