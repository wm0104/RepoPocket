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
    func personalIssues(_ login: String, filter: PersonalIssueFilter, page: Int) async throws -> [CollaborationItem] {
        guard isCurrentSession else { throw CancellationError() }
        let query = try PersonalIssueRules.query(login: login, filter: filter)
        let response = try await communityDecode(PersonalIssueSearchResponse.self, path: "/search/issues",
            query: CommunityRules.page(page) + [.init(name: "q", value: query), .init(name: "sort", value: "updated"), .init(name: "order", value: "desc")])
        guard response.incomplete_results != true else { throw AppError(text: "GitHub 暂未完成议题搜索，请稍后重试。") }
        return response.items.filter { PersonalIssueRules.repository($0) != nil }
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
    func communitySocialAccounts(_ login: String, page: Int) async throws -> [CommunitySocialAccount] {
        let target = try UserFollowRules.login(login)
        let bytes = try await socialAccountRead(target, page: page)
        return try JSONDecoder().decode([CommunitySocialAccount].self, from: bytes)
    }
    func userConnections(_ login: String, kind: UserConnectionKind, page: Int) async throws -> [RepositorySocialUser] {
        try Task.checkCancellation()
        guard isCurrentSession else { throw CancellationError() }
        guard !login.isEmpty, login.utf8.count <= 39,
              login.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
            throw AppError(text: "无效的 GitHub 用户名。")
        }
        return try await communityDecode([RepositorySocialUser].self,
            path: "/users/" + Self.component(login) + "/" + kind.rawValue, query: CommunityRules.page(page))
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
    func socialStargazers(_ repo: String, page: Int) async throws -> [RepositorySocialUser] {
        try await communityDecode([RepositorySocialUser].self, path: Self.repoPath(repo) + "/stargazers", query: CommunityRules.page(page))
    }
    func socialForks(_ repo: String, page: Int) async throws -> [Repository] {
        try await communityDecode([Repository].self, path: Self.repoPath(repo) + "/forks", query: CommunityRules.page(page) + [.init(name: "sort", value: "newest")])
    }
    func socialComparison(_ repo: String, base: String, owner: String, head: String, page: Int) async throws -> ForkComparison {
        guard base.count == 40, head.count == 40, (base + head).allSatisfy({ $0.isHexDigit }), !owner.isEmpty else { throw AppError(text: "比较版本无效。") }
        return try await communityDecode(ForkComparison.self, path: Self.repoPath(repo) + "/compare/" + Self.component(base) + "..." + Self.component(owner + ":" + head), query: CommunityRules.page(page))
    }

}
