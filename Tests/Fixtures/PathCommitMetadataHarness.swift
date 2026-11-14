struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
enum AccountStore { static var generation = UUID() }
enum RefreshFailure { static func isCancellation(_ error: Error) -> Bool { error is CancellationError } }
struct Entry { let type: String; let path: String }
final class ContentSnapshotCache {
    static let shared = ContentSnapshotCache()
    var values: [String: Data] = [:]
    func save(_ body: Data, accountID: String, key: String) { values[accountID + "\n" + key] = body }
}
@MainActor final class GitHub {
    let accountID: String
    init(accountID: String = "path-fixture") { self.accountID = accountID }
    var isCurrentSession = true
    var heads: [String: String] = ["main": String(repeating: "b", count: 40), "dev": String(repeating: "c", count: 40)]
    var batches: [(String, [String])] = []
    var headCalls = 0
    var offline = false
    var hold = false
    var gate: CheckedContinuation<[String: PathCommitMetadata], Error>?
    // PRODUCTION_PATH_HELPERS
    func cachedContent<T: Decodable>(_ type: T.Type, key: String) -> (value: T, savedAt: Date)? {
        guard let bytes = ContentSnapshotCache.shared.values[accountID + "\n" + key],
              let value = try? JSONDecoder().decode(type, from: bytes) else { return nil }
        return (value, Date())
    }
    func workspaceHead(_ repo: String, branch: String) async throws -> String {
        headCalls += 1
        if offline { throw URLError(.notConnectedToInternet) }
        return heads[branch]!
    }
    func repositoryPathCommits(_ repo: String, head: String, paths: [String]) async throws -> [String: PathCommitMetadata] {
        _ = try PathCommitQuery.request(repo: repo, head: head, paths: paths)
        batches.append((head, paths))
        if hold { return try await withCheckedThrowingContinuation { gate = $0 } }
        return Dictionary(uniqueKeysWithValues: paths.map { ($0, PathCommitMetadata(oid: head, messageHeadline: $0 + " final", committedDate: nil)) })
    }
}
@main struct Run {
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("metadata did not settle")
    }
    @MainActor static func main() async throws {
        let head = String(repeating: "b", count: 40), paths = ["Sources", "中文 \"name\".swift"]
        let request = try PathCommitQuery.request(repo: "owner/repo", head: head, paths: paths)
        precondition(request.0.contains("object(expression: $head)") && !request.0.contains(paths[1]))
        precondition(request.1["head"] as? String == head && request.1["p1"] as? String == paths[1])
        for invalid in [[], ["same", "same"], ["../escape"], Array(repeating: "path", count: 21)] {
            do { _ = try PathCommitQuery.request(repo: "owner/repo", head: head, paths: invalid); preconditionFailure("invalid path batch accepted") } catch {}
        }
        let bytes = try JSONSerialization.data(withJSONObject: ["data": ["repository": ["object": ["p0": ["nodes": [["oid": head, "messageHeadline": "correct path"]]], "p1": ["nodes": []]]]]])
        let decoded = try PathCommitQuery.decode(bytes, paths: paths)
        precondition(decoded[paths[0]]?.messageHeadline == "correct path" && decoded[paths[1]] == nil)
        let failed = Data(#"{"errors":[{"message":"denied"}],"data":null}"#.utf8)
        do { _ = try PathCommitQuery.decode(failed, paths: paths); preconditionFailure("partial GraphQL error accepted") } catch {}
        let api = GitHub(), state = PathCommitMetadataState()
        let entries = (0..<45).map { Entry(type: $0 % 3 == 0 ? "dir" : "file", path: "entry-\($0)") }
        state.load(api: api, repo: "owner/repo", branch: "main", entries: entries)
        try await wait { state.commits.count == 45 || !state.error.isEmpty }
        precondition(state.error.isEmpty && api.headCalls == 1 && api.batches.map { $0.1.count } == [20, 20, 5])
        precondition(api.batches.allSatisfy { $0.0 == head })
        api.offline = true
        let restored = PathCommitMetadataState()
        restored.load(api: api, repo: "owner/repo", branch: "main", entries: [entries[0]])
        precondition(restored.commits[entries[0].path]?.oid == head)
        try await wait { !restored.error.isEmpty }
        precondition(restored.commits[entries[0].path]?.oid == head && api.batches.count == 3)
        let other = GitHub(accountID: "other-account"), isolated = PathCommitMetadataState()
        other.offline = true
        isolated.load(api: other, repo: "owner/repo", branch: "main", entries: [entries[0]])
        precondition(isolated.commits.isEmpty)
        try await wait { !isolated.error.isEmpty }
        precondition(isolated.commits.isEmpty)
        api.offline = false
        ContentSnapshotCache.shared.values = [:]; api.hold = true
        state.load(api: api, repo: "owner/repo", branch: "main", entries: [entries[0]])
        try await wait { api.gate != nil }
        let old = api.gate; api.gate = nil; api.hold = false
        state.load(api: api, repo: "owner/repo", branch: "dev", entries: [entries[0]])
        try await wait { state.commits[entries[0].path]?.oid == api.heads["dev"] }
        old?.resume(returning: [entries[0].path: PathCommitMetadata(oid: head, messageHeadline: "stale", committedDate: nil)])
        for _ in 0..<20 { await Task.yield() }
        precondition(state.commits[entries[0].path]?.oid == api.heads["dev"])
        ContentSnapshotCache.shared.values = [:]; api.hold = true
        state.load(api: api, repo: "owner/repo", branch: "main", entries: [entries[0]])
        try await wait { api.gate != nil }
        AccountStore.generation = UUID(); api.isCurrentSession = false
        api.gate?.resume(returning: [entries[0].path: PathCommitMetadata(oid: head, messageHeadline: "other account", committedDate: nil)])
        api.gate = nil
        for _ in 0..<20 { await Task.yield() }
        precondition(state.commits.isEmpty && state.error.isEmpty)
        print("PASS production bound path query, 20-item batches, offline cached metadata, stale branch response and account isolation")
    }
}
