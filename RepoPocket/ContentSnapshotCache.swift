import Foundation
import CryptoKit

/// Read-only display snapshots. Permissions and write preconditions always come from a fresh request.
final class ContentSnapshotCache {
    static let shared = ContentSnapshotCache()
    static let maximumRecordBytes = 12 * 1024 * 1024
    static let maximumAccountBytes = 32 * 1024 * 1024
    struct Record: Codable {
        let accountID: String
        let key: String
        let savedAt: Date
        let body: Data
    }
    private final class Box: NSObject {
        let record: Record
        init(_ record: Record) { self.record = record }
    }
    private let queue = DispatchQueue(label: "RepoPocket.content-snapshots", qos: .utility)
    private let memory = NSCache<NSString, Box>()
    private let root: URL

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ContentSnapshots", isDirectory: true)) {
        self.root = root
        memory.countLimit = 128
        memory.totalCostLimit = Self.maximumAccountBytes
    }
    static func key(_ path: String, query: [URLQueryItem] = []) -> String {
        var components = URLComponents()
        components.queryItems = query.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        return path + "\n" + (components.percentEncodedQuery ?? "")
    }
    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func directory(_ accountID: String) -> URL { root.appendingPathComponent(digest(accountID), isDirectory: true) }
    private func location(_ accountID: String, _ key: String) -> URL { directory(accountID).appendingPathComponent(digest(key) + ".json") }
    func load(accountID: String, key: String) -> Record? {
        queue.sync {
            let identifier = (accountID + "\n" + key) as NSString
            if let box = memory.object(forKey: identifier) { return box.record }
            let file = location(accountID, key)
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= Self.maximumRecordBytes,
                  let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.accountID == accountID, record.key == key else { return nil }
            memory.setObject(Box(record), forKey: identifier, cost: data.count)
            return record
        }
    }
    func save(_ body: Data, accountID: String, key: String) {
        guard body.count <= 8 * 1024 * 1024 else { return }
        let record = Record(accountID: accountID, key: key, savedAt: Date(), body: body)
        queue.async {
            guard let data = try? JSONEncoder().encode(record), data.count <= Self.maximumRecordBytes else { return }
            let folder = self.directory(accountID)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                var excluded = self.root; try excluded.setResourceValues(values)
                let file = self.location(accountID, key)
                try data.write(to: file, options: .atomic)
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
                #endif
                self.memory.setObject(Box(record), forKey: (accountID + "\n" + key) as NSString, cost: data.count)
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
                let ordered = files.compactMap { url -> (URL, Int, Date)? in
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                    return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
                }.sorted { $0.2 < $1.2 }
                var total = ordered.reduce(0) { $0 + $1.1 }
                var count = ordered.count
                for (url, bytes, _) in ordered where total > Self.maximumAccountBytes || count > 128 {
                    try? FileManager.default.removeItem(at: url); total -= bytes; count -= 1
                }
            } catch { /* A cache failure must not prevent displaying the successful response. */ }
        }
    }
    func removeAccount(_ accountID: String) {
        queue.sync {
            memory.removeAllObjects()
            try? FileManager.default.removeItem(at: directory(accountID))
        }
    }
    func remove(accountID: String, key: String) {
        queue.sync {
            memory.removeObject(forKey: (accountID + "\n" + key) as NSString)
            try? FileManager.default.removeItem(at: location(accountID, key))
        }
    }
}

extension GitHub {
    func cachedWorkflowRuns(_ repo: String, branch: String, failedOnly: Bool = false, headSHA: String = "") -> (value: [WorkflowRun], savedAt: Date)? {
        guard let page = try? CommunityRules.page(1) else { return nil }
        let query = page + (branch.isEmpty ? [] : [.init(name: "branch", value: branch)])
            + (failedOnly ? [.init(name: "status", value: "failure")] : [])
            + (headSHA.isEmpty ? [] : [.init(name: "head_sha", value: headSHA)])
        guard let cached = try? cachedContent(WorkflowRuns.self, key: ContentSnapshotCache.key(Self.repoPath(repo) + "/actions/runs", query: query)) else { return nil }
        return (cached.value.workflow_runs.filter { headSHA.isEmpty || ($0.head_sha == headSHA && (branch.isEmpty || $0.head_branch == branch)) }, cached.savedAt)
    }
    func cachedContent<T: Decodable>(_ type: T.Type, key: String) -> (value: T, savedAt: Date)? {
        guard isCurrentSession, !CredentialStore.read(account: accountID).isEmpty,
              let record = ContentSnapshotCache.shared.load(accountID: accountID, key: key),
              let value = try? JSONDecoder().decode(type, from: record.body) else { return nil }
        return (value, record.savedAt)
    }
    func cachedRepository(_ repo: String) -> (value: Repository, savedAt: Date)? {
        try? cachedContent(Repository.self, key: ContentSnapshotCache.key(Self.repoPath(repo)))
    }
    func cachedContents(_ repo: String, path: String, branch: String) -> (value: [Entry], savedAt: Date)? {
        guard let encoded = path.isEmpty ? "" : try? Self.filePath(path) else { return nil }
        return try? cachedContent([Entry].self, key: ContentSnapshotCache.key(Self.repoPath(repo) + "/contents" + (path.isEmpty ? "" : "/" + encoded), query: [.init(name: "ref", value: branch)]))
    }
}
