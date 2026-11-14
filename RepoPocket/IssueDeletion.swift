import Foundation
import Combine

struct IssueDeletionSubject: Hashable {
    let id: Int
    let repo: String
    let number: Int
    let title: String
    var key: String { repo.lowercased() + "#\(number)" }
    init?(_ item: CollaborationItem, repo: String) {
        guard item.id > 0, let actual = PersonalIssueRules.repository(item),
              actual.caseInsensitiveCompare(repo) == .orderedSame else { return nil }
        id = item.id; self.repo = actual; number = item.number; title = item.title
    }
}

struct IssueDeletionGrant {
    let subject: IssueDeletionSubject
    let nodeID: String
}

struct IssueDeletionSession: Equatable {
    let accountID: String
    let generation: UUID
}

struct IssueDeletionConfirmation: Identifiable {
    let id = UUID()
    let grant: IssueDeletionGrant
    let session: IssueDeletionSession
}

enum IssueDeletionRules {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
    struct Query {
        let text: String
        let variables: [String: Any]
    }
    private struct ErrorItem: Decodable { let message: String }
    private struct RepositoryName: Decodable { let nameWithOwner: String }
    private struct Issue: Decodable {
        let id: String
        let number: Int
        let viewerCanDelete: Bool
        let repository: RepositoryName
    }
    private struct RepositoryNode: Decodable { let issue: Issue? }
    private struct Permissions: Decodable {
        let data: [String: RepositoryNode?]?
        let errors: [ErrorItem]?
    }
    private struct Mutation: Decodable {
        struct Payload: Decodable {
            struct Result: Decodable { let clientMutationId: String?; let repository: RepositoryName? }
            let deleteIssue: Result?
        }
        let data: Payload?
        let errors: [ErrorItem]?
    }
    static func permissionQuery(_ subjects: [IssueDeletionSubject]) throws -> Query {
        guard !subjects.isEmpty, subjects.count <= 30,
              Set(subjects.map(\.key)).count == subjects.count else { throw Failure("无效的议题权限请求。") }
        var declarations: [String] = [], fields: [String] = [], variables: [String: Any] = [:]
        for (i, subject) in subjects.enumerated() {
            let repo = try RepositoryInput.parse(subject.repo).split(separator: "/").map(String.init)
            guard subject.number > 0, subject.id > 0 else { throw Failure("无效的议题编号。") }
            declarations += ["$o\(i):String!", "$r\(i):String!", "$n\(i):Int!"]
            variables["o\(i)"] = repo[0]; variables["r\(i)"] = repo[1]; variables["n\(i)"] = subject.number
            fields.append("i\(i):repository(owner:$o\(i),name:$r\(i)){issue(number:$n\(i)){id number viewerCanDelete repository{nameWithOwner}}}")
        }
        return Query(text: "query(" + declarations.joined(separator: ",") + "){" + fields.joined(separator: " ") + "}", variables: variables)
    }
    static func grants(_ bytes: Data, subjects: [IssueDeletionSubject]) throws -> [String: IssueDeletionGrant] {
        _ = try permissionQuery(subjects)
        let response = try JSONDecoder().decode(Permissions.self, from: bytes)
        guard response.errors?.isEmpty != false, let data = response.data else { throw Failure("无法确认议题删除权限，请手动重试。") }
        var result: [String: IssueDeletionGrant] = [:]
        for (i, subject) in subjects.enumerated() {
            guard data.keys.contains("i\(i)") else { throw Failure("议题权限响应不完整。") }
            guard let repository = data["i\(i)"] ?? nil, let issue = repository.issue else { continue }
            guard issue.number == subject.number,
                  issue.repository.nameWithOwner.caseInsensitiveCompare(subject.repo) == .orderedSame,
                  !issue.id.isEmpty, issue.id.utf8.count <= 256 else { throw Failure("议题身份不匹配，请刷新后重试。") }
            if issue.viewerCanDelete { result[subject.key] = IssueDeletionGrant(subject: subject, nodeID: issue.id) }
        }
        return result
    }
    static func acknowledge(_ bytes: Data, subject: IssueDeletionSubject, requestID: String) throws {
        let response = try JSONDecoder().decode(Mutation.self, from: bytes)
        guard response.errors?.isEmpty != false, let result = response.data?.deleteIssue,
              result.clientMutationId == requestID,
              result.repository?.nameWithOwner.caseInsensitiveCompare(subject.repo) == .orderedSame else {
            throw Failure("未收到匹配的删除成功确认，请先刷新核实，再决定是否重试。")
        }
    }
}

extension GitHub {
    func issueDeletionGrants(_ subjects: [IssueDeletionSubject]) async throws -> [String: IssueDeletionGrant] {
        let query = try IssueDeletionRules.permissionQuery(subjects)
        let bytes = try await issueDeletionGraphQL(query.text, variables: query.variables)
        return try IssueDeletionRules.grants(bytes, subjects: subjects)
    }
    func deleteIssue(_ confirmation: IssueDeletionConfirmation) async throws {
        guard isCurrentSession, confirmation.session == issueDeletionSession else { throw CancellationError() }
        let grant = confirmation.grant
        let current = try await issueDeletionGrants([grant.subject])
        try Task.checkCancellation()
        guard isCurrentSession, confirmation.session == issueDeletionSession,
              let refreshed = current[grant.subject.key], refreshed.nodeID == grant.nodeID else {
            throw IssueDeletionRules.Failure("议题权限或身份已变化，未执行删除，请刷新后重试。")
        }
        let requestID = UUID().uuidString
        let query = "mutation($input:DeleteIssueInput!){deleteIssue(input:$input){clientMutationId repository{nameWithOwner}}}"
        let bytes = try await issueDeletionGraphQL(query, variables: ["input": ["issueId": refreshed.nodeID, "clientMutationId": requestID]])
        try Task.checkCancellation()
        guard isCurrentSession, confirmation.session == issueDeletionSession else { throw CancellationError() }
        try IssueDeletionRules.acknowledge(bytes, subject: grant.subject, requestID: requestID)
    }
}

/// One session-owned cache; page data changes queue bounded batches, never row appearance.
@MainActor final class IssueDeletionState: ObservableObject {
    @Published private(set) var grants: [String: IssueDeletionGrant] = [:]
    @Published private(set) var failed = Set<String>()
    @Published private(set) var checking = Set<String>()
    @Published private(set) var deleted = Set<Int>()
    @Published private(set) var deleting = false
    private var attempted = Set<String>()
    private var pending: [IssueDeletionSubject] = []
    private var worker: Task<Void, Never>?
    private var generation = UUID()

    func visible(_ items: [CollaborationItem], kind: CollaborationKind = .issues) -> [CollaborationItem] {
        // Issue and PullRequest REST IDs belong to different database namespaces.
        kind == .issues ? items.filter { !deleted.contains($0.id) } : items
    }
    func resetPermissions() {
        generation = UUID(); worker?.cancel(); worker = nil; pending = []
        grants = [:]; failed = []; checking = []; attempted = []
    }
    func load(_ subjects: [IssueDeletionSubject], api: GitHub, retry: Bool = false) {
        guard api.isCurrentSession else { return }
        for subject in subjects.prefix(300) where !deleted.contains(subject.id) {
            if retry && failed.contains(subject.key) { attempted.remove(subject.key) }
            guard attempted.insert(subject.key).inserted else { continue }
            failed.remove(subject.key); checking.insert(subject.key); pending.append(subject)
        }
        guard worker == nil, !pending.isEmpty else { return }
        let request = generation
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == request { self.worker = nil } }
            while !self.pending.isEmpty && api.isCurrentSession && !Task.isCancelled {
                let batch = Array(self.pending.prefix(30)); self.pending.removeFirst(batch.count)
                let keys = Set(batch.map(\.key))
                do {
                    let values = try await api.issueDeletionGrants(batch)
                    try Task.checkCancellation(); guard api.isCurrentSession, self.generation == request else { return }
                    for key in keys { self.grants.removeValue(forKey: key) }
                    self.grants.merge(values.filter { !self.deleted.contains($0.value.subject.id) }) { _, new in new }
                } catch {
                    guard api.isCurrentSession, self.generation == request, !RefreshFailure.isCancellation(error) else { return }
                    self.failed.formUnion(keys)
                }
                self.checking.subtract(keys)
            }
        }
    }
    func remove(_ target: IssueDeletionConfirmation, api: GitHub) async throws {
        guard !deleting, api.isCurrentSession, target.session == api.issueDeletionSession,
              !deleted.contains(target.grant.subject.id) else { throw CancellationError() }
        deleting = true; defer { deleting = false }
        do { try await api.deleteIssue(target) }
        catch {
            if api.isCurrentSession, !RefreshFailure.isCancellation(error) {
                grants.removeValue(forKey: target.grant.subject.key); failed.insert(target.grant.subject.key)
            }
            throw error
        }
        guard api.isCurrentSession, target.session == api.issueDeletionSession else { throw CancellationError() }
        deleted.insert(target.grant.subject.id)
        grants.removeValue(forKey: target.grant.subject.key)
    }
}
