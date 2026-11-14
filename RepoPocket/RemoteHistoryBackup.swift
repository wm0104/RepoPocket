import Foundation
import CryptoKit
import ZIPFoundation

enum RemoteHistoryBackup {
    struct Record: Codable {
        let createdAt: Date
        let snapshot: RemoteHistorySnapshot
        let action: RemoteHistoryAction
        let selected: Set<String>
        let steps: [RemoteHistoryStep]
        let versions: [RemoteHistoryVersion]
        let baseline: String?
        let resultKey: String
        var resolved: [String: String] = [:]
        var newHead: String?
        var phase = "backed-up"
        func preview(generation: UUID) -> RemoteHistoryPreview {
            let current = RemoteHistorySnapshot(accountID: snapshot.accountID, generation: generation, repository: snapshot.repository,
                repositoryID: snapshot.repositoryID, branch: snapshot.branch, head: snapshot.head, commits: snapshot.commits)
            return .init(snapshot: current, action: action, selected: selected, steps: steps, resultKey: resultKey, versions: versions, baseline: baseline)
        }
    }
    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HistoryBackups", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
    }
    private static func accountRoot(_ accountID: String) -> URL {
        root.appendingPathComponent(SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined(), isDirectory: true)
    }
    private static func validate(_ folder: URL, accountID: String) throws {
        guard UUID(uuidString: folder.lastPathComponent) != nil,
              folder.deletingLastPathComponent().standardizedFileURL == accountRoot(accountID).standardizedFileURL,
              folder.resolvingSymlinksInPath().standardizedFileURL == folder.standardizedFileURL else {
            throw AppError(text: "原历史备份目录无效。")
        }
    }
    private static func save(_ record: Record, folder: URL) throws {
        try validate(folder, accountID: record.snapshot.accountID)
        let data = try JSONEncoder().encode(record)
        guard data.count <= 16 * 1024 * 1024 else { throw AppError(text: "历史备份记录超过16 MiB，未更新远端。") }
        try data.write(to: folder.appendingPathComponent("history.json"), options: .atomic)
    }
    private static func record(_ folder: URL, accountID: String) throws -> Record {
        try validate(folder, accountID: accountID)
        let file = folder.appendingPathComponent("history.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 16 * 1024 * 1024 else { throw AppError(text: "原历史备份记录无效。") }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
        guard record.snapshot.accountID == accountID else { throw AppError(text: "原历史备份不属于当前账号。") }
        return record
    }
    @MainActor static func prepare(_ preview: RemoteHistoryPreview, api: GitHub) async throws -> URL {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-repository-operations-style-preview") {
            throw AppError(text: "固定样式预览不连接Git传输，也不执行真实历史整理。")
        }
        #endif
        let snapshot = preview.snapshot
        guard api.isCurrentSession, api.accountID == snapshot.accountID, AccountStore.generation == snapshot.generation else { throw CancellationError() }
        let token = CredentialStore.read(account: api.accountID)
        guard !token.isEmpty else { throw AppError(text: "请先登录以备份原历史。") }
        let folder = accountRoot(api.accountID).appendingPathComponent(UUID().uuidString, isDirectory: true)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: attributes)
        do {
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var location = folder; try location.setResourceValues(values)
            try await LocalGitEngine.shared.historyBackup(remote: "https://github.com/" + (try RepositoryInput.parse(snapshot.repository)) + ".git",
                branch: snapshot.branch, head: snapshot.head, tree: snapshot.tree, count: snapshot.commits.count,
                destination: folder.appendingPathComponent("original.git", isDirectory: true), token: token, generation: snapshot.generation)
            try Task.checkCancellation()
            guard api.isCurrentSession, AccountStore.generation == snapshot.generation else { throw CancellationError() }
            try save(Record(createdAt: Date(), snapshot: snapshot, action: preview.action, selected: preview.selected,
                steps: preview.steps, versions: preview.versions, baseline: preview.baseline, resultKey: preview.resultKey), folder: folder)
            return folder
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
    static func update(_ folder: URL, preview: RemoteHistoryPreview, resolved: [String: String], newHead: String, phase: String) throws {
        var record = try record(folder, accountID: preview.snapshot.accountID)
        guard record.snapshot.head == preview.snapshot.head, record.snapshot.repository == preview.snapshot.repository,
              record.snapshot.branch == preview.snapshot.branch, ["objects-verified", "update-requested", "verified", "rejected"].contains(phase) else {
            throw AppError(text: "原历史备份与本次整理不一致，未继续。")
        }
        if !resolved.isEmpty { record.resolved = resolved }
        record.newHead = newHead; record.phase = phase
        try save(record, folder: folder)
    }
    static func latest(accountID: String, repo: String, branch: String) -> (folder: URL, record: Record)? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: accountRoot(accountID), includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> (folder: URL, record: Record)? in
            guard let record = try? record(folder, accountID: accountID),
                  record.snapshot.repository == repo, record.snapshot.branch == branch else { return nil }
            return (folder, record)
        }.max { $0.record.createdAt < $1.record.createdAt }
    }
    @MainActor static func archive(_ folder: URL, api: GitHub) async throws -> URL {
        guard api.isCurrentSession else { throw CancellationError() }
        _ = try record(folder, accountID: api.accountID)
        let generation = AccountStore.generation
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("RepoPocket-history-" + UUID().uuidString + ".zip")
        let worker = Task.detached(priority: .utility) {
            try FileManager.default.zipItem(at: folder, to: file, shouldKeepParent: true)
        }
        do {
            try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard api.isCurrentSession, AccountStore.generation == generation else { throw CancellationError() }
            return file
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
    static func removeAccount(_ accountID: String) {
        try? FileManager.default.removeItem(at: accountRoot(accountID))
    }
}
