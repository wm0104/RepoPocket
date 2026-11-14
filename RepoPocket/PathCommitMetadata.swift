import SwiftUI

struct PathCommitMetadata: Codable {
    let oid: String
    let messageHeadline: String
    let committedDate: String?
}

enum PathCommitQuery {
    static let batchSize = 20
    @MainActor static func request(repo: String, head: String, paths: [String]) throws -> (String, [String: Any]) {
        let parts = try RepositoryInput.parse(repo).split(separator: "/").map(String.init)
        guard head.utf8.count == 40, head.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !paths.isEmpty, paths.count <= batchSize, Set(paths).count == paths.count else { throw AppError(text: "提交信息查询范围无效。") }
        var variables: [String: Any] = ["owner": parts[0], "name": parts[1], "head": head]
        var declarations = ["$owner: String!", "$name: String!", "$head: String!"]
        var fields: [String] = []
        for (index, path) in paths.enumerated() {
            _ = try GitHub.filePath(path)
            variables["p\(index)"] = path
            declarations.append("$p\(index): String!")
            fields.append("p\(index): history(first: 1, path: $p\(index)) { nodes { oid messageHeadline committedDate } }")
        }
        return ("query(\(declarations.joined(separator: ","))) { repository(owner: $owner, name: $name) { object(expression: $head) { ... on Commit { \(fields.joined(separator: " ")) } } } }", variables)
    }
    static func decode(_ data: Data, paths: [String]) throws -> [String: PathCommitMetadata] {
        struct Connection: Decodable { let nodes: [PathCommitMetadata] }
        struct RepositoryResult: Decodable { let object: [String: Connection]? }
        struct Result: Decodable { let repository: RepositoryResult? }
        struct Envelope: Decodable {
            struct Failure: Decodable { let message: String }
            let data: Result?
            let errors: [Failure]?
        }
        let response = try JSONDecoder().decode(Envelope.self, from: data)
        guard response.errors?.isEmpty != false, let object = response.data?.repository?.object else {
            throw AppError(text: response.errors?.first?.message ?? "未取得当前提交的路径信息。")
        }
        var result: [String: PathCommitMetadata] = [:]
        for (index, path) in paths.enumerated() { result[path] = object["p\(index)"]?.nodes.first }
        return result
    }
}

@MainActor final class PathCommitMetadataState: ObservableObject {
    @Published private(set) var commits: [String: PathCommitMetadata] = [:]
    @Published private(set) var error = ""
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    func cancel() { requestID = UUID(); task?.cancel(); task = nil }
    func load(api: GitHub, repo: String, branch: String, entries: [Entry]) {
        cancel()
        let token = requestID, generation = AccountStore.generation
        let paths = entries.filter { $0.type == "file" || $0.type == "dir" }.map(\.path)
        commits = [:]; error = ""
        guard !paths.isEmpty, !branch.isEmpty else { return }
        let identity = repo.lowercased() + "\n" + branch
        func cached(_ head: String) -> [String: PathCommitMetadata] {
            var values: [String: PathCommitMetadata] = [:]
            for path in paths {
                values[path] = api.cachedContent(PathCommitMetadata.self, key: "path-commit:" + repo.lowercased() + "\n" + head + "\n" + path)?.value
            }
            return values
        }
        if let old = api.cachedContent(String.self, key: "directory-head:" + identity)?.value { commits = cached(old) }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.requestID == token { self.task = nil } }
            do {
                let head = try await api.workspaceHead(repo, branch: branch)
                try Task.checkCancellation()
                guard self.requestID == token, generation == AccountStore.generation, api.isCurrentSession else { return }
                self.commits = cached(head)
                if let data = try? JSONEncoder().encode(head) {
                    ContentSnapshotCache.shared.save(data, accountID: api.accountID, key: "directory-head:" + identity)
                }
                let missing = paths.filter { self.commits[$0] == nil }
                for offset in stride(from: 0, to: missing.count, by: PathCommitQuery.batchSize) {
                    let batch = Array(missing[offset..<min(offset + PathCommitQuery.batchSize, missing.count)])
                    let values = try await api.repositoryPathCommits(repo, head: head, paths: batch)
                    try Task.checkCancellation()
                    guard self.requestID == token, generation == AccountStore.generation, api.isCurrentSession else { return }
                    self.commits.merge(values) { _, new in new }
                    for (path, value) in values {
                        if let data = try? JSONEncoder().encode(value) {
                            ContentSnapshotCache.shared.save(data, accountID: api.accountID, key: "path-commit:" + repo.lowercased() + "\n" + head + "\n" + path)
                        }
                    }
                }
            } catch {
                if self.requestID == token, generation == AccountStore.generation, api.isCurrentSession, !RefreshFailure.isCancellation(error) {
                    self.error = "提交信息尚未更新：" + error.localizedDescription
                }
            }
        }
    }
}

struct PathCommitMetadataLink: View {
    @ObservedObject var api: GitHub
    let repo: String
    let path: String
    let commit: PathCommitMetadata?
    var body: some View {
        if let commit {
            NavigationLink { CommitDetailView(api: api, repo: repo, sha: commit.oid) } label: {
                HStack(spacing: 5) {
                    Text(commit.messageHeadline).lineLimit(1)
                    if let date = ChinaDate.parse(commit.committedDate) {
                        Text(date, style: .relative).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    }
                }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: 150, alignment: .trailing)
            }.buttonStyle(.borderless)
                .accessibilityLabel(path + " 最近提交：" + commit.messageHeadline)
                .accessibilityIdentifier("path-commit-" + path)
        }
    }
}
