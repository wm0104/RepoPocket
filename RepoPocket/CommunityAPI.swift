import Foundation

extension GitHub {
    private func communityDecode<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async throws -> T {
        let bytes = try await communityRead(path, query: query)
        // GitHub returns 204 for an empty repository's contributors list.
        let payload = bytes.isEmpty ? Data("[]".utf8) : bytes
        let result = try await Task.detached(priority: .userInitiated) { try JSONDecoder().decode(type, from: payload) }.value
        try Task.checkCancellation()
        guard isCurrentSession else { throw CancellationError() }
        return result
    }
    func collaborationItems(_ repo: String, kind: CollaborationKind, state: String, page: Int) async throws -> [CollaborationItem] {
        guard ["open", "closed", "all"].contains(state) else { throw AppError(text: "无效状态") }
        return try await communityDecode([CollaborationItem].self, path: Self.repoPath(repo) + "/" + kind.rawValue,
            query: CommunityRules.page(page) + [.init(name: "state", value: state), .init(name: "sort", value: "updated"), .init(name: "direction", value: "desc")])
    }
    func collaborationDetail(_ repo: String, kind: CollaborationKind, number: Int) async throws -> CollaborationItem {
        guard number > 0 else { throw AppError(text: "无效编号") }
        return try await communityDecode(CollaborationItem.self, path: Self.repoPath(repo) + "/" + kind.rawValue + "/\(number)")
    }
    func collaborationComments(_ repo: String, number: Int, stream: DiscussionStream, page: Int) async throws -> [CollaborationComment] {
        guard number > 0 else { throw AppError(text: "无效编号") }
        let suffix: String
        switch stream {
        case .conversation: suffix = "/issues/\(number)/comments"
        case .reviews: suffix = "/pulls/\(number)/reviews"
        case .inline: suffix = "/pulls/\(number)/comments"
        }
        return try await communityDecode([CollaborationComment].self, path: Self.repoPath(repo) + suffix, query: CommunityRules.page(page))
    }
    func pullFiles(_ repo: String, number: Int, page: Int) async throws -> [DesktopCommit.File] {
        guard number > 0 else { throw AppError(text: "无效 PR 编号") }
        return try await communityDecode([DesktopCommit.File].self, path: Self.repoPath(repo) + "/pulls/\(number)/files", query: CommunityRules.page(page))
    }
    func repositoryReadme(_ repo: String, branch: String) async throws -> Entry {
        try await communityDecode(Entry.self, path: Self.repoPath(repo) + "/readme", query: branch.isEmpty ? [] : [.init(name: "ref", value: branch)])
    }
    func communityProfile(_ login: String) async throws -> CommunityProfile {
        try await communityDecode(CommunityProfile.self, path: "/users/" + Self.component(login))
    }
    func communityEvents(_ login: String, received: Bool = false, page: Int) async throws -> [CommunityEvent] {
        try await communityDecode([CommunityEvent].self, path: "/users/" + Self.component(login) + (received ? "/received_events" : "/events/public"), query: CommunityRules.page(page))
    }
    func contributors(_ repo: String, page: Int) async throws -> [RepositoryContributor] {
        try await communityDecode([RepositoryContributor].self, path: Self.repoPath(repo) + "/contributors", query: CommunityRules.page(page))
    }
    func repositoryLanguages(_ repo: String) async throws -> [String: Int] {
        try await communityDecode([String: Int].self, path: Self.repoPath(repo) + "/languages")
    }
}
