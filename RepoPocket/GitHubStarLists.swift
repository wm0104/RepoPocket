import Foundation

struct StarListOwner: Codable, Equatable { let id: String; let login: String }
struct StarRepositoryList: Codable, Identifiable {
    struct Count: Codable { let totalCount: Int }
    let id: String
    let name: String
    let isPrivate: Bool
    let user: StarListOwner
    let items: Count
}
struct StarListIndex: Codable { let owner: StarListOwner; let lists: [StarRepositoryList] }
struct StarListRepository: Codable, Identifiable {
    let id: String
    let databaseId: Int
    let nameWithOwner: String
    let name: String
    let description: String?
    let url: String
    let updatedAt: String
    let owner: User
    let viewerHasStarred: Bool
    var repository: Repository {
        .init(id: databaseId, full_name: nameWithOwner, name: name, description: description,
            default_branch: nil, html_url: url, owner: owner, private: nil, updated_at: updatedAt,
            stargazers_count: nil, forks_count: nil, language: nil, fork: nil, parent: nil, source: nil, permissions: nil)
    }
}

/// Official UserList operations. Never infer permission or memberships from cached UI.
@MainActor struct GitHubStarLists {
    let send: (String, [String: Any]) async throws -> Data
    let isCurrent: () -> Bool
    private static let fields = "id name isPrivate user { id login } items(first:1) { totalCount }"
    private static let repositoryFields = "id databaseId nameWithOwner name description url updatedAt owner { login avatar_url: avatarUrl } viewerHasStarred"
    private struct Page: Decodable { let hasNextPage: Bool; let endCursor: String? }
    private struct Connection<T: Decodable>: Decodable { let nodes: [T]; let pageInfo: Page; let totalCount: Int }
    private struct IndexPage: Decodable {
        struct Viewer: Decodable { let id: String; let login: String; let lists: Connection<StarRepositoryList> }
        let viewer: Viewer
    }
    private struct ItemsPage: Decodable {
        struct Node: Decodable { let id: String; let user: StarListOwner; let items: Connection<StarListRepository> }
        let viewer: StarListOwner
        let node: Node
    }
    private struct RepositoryPage: Decodable { let viewer: StarListOwner; let repository: StarListRepository }
    private struct ListResult: Decodable { let list: StarRepositoryList }
    private struct UserResult: Decodable { let user: StarListOwner }
    private struct MembershipResult: Decodable {
        struct Item: Decodable { let id: String }
        let item: Item; let user: StarListOwner; let lists: [StarRepositoryList]
    }
    private var incomplete: AppError { AppError(text: "未能完整核对GitHub分类，请刷新确认结果；不会自动重发写入。") }
    private func result<T: Decodable>(_ query: String, _ variables: [String: Any] = [:], key: String? = nil) async throws -> T {
        try Task.checkCancellation(); guard isCurrent() else { throw CancellationError() }
        let bytes = try await send(query, variables)
        try Task.checkCancellation(); guard isCurrent() else { throw CancellationError() }
        guard bytes.count <= 2_097_152, let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let data = object["data"] as? [String: Any] else { throw incomplete }
        if let errors = object["errors"] { guard let values = errors as? [Any], values.isEmpty else { throw incomplete } }
        let value: Any
        if let key { guard let entry = data[key] as? [String: Any] else { throw incomplete }; value = entry }
        else { value = data }
        do { return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value)) }
        catch { throw incomplete }
    }
    private func next(_ page: Page, seenCursors: inout Set<String>) throws -> String? {
        guard page.hasNextPage else { return nil }
        guard let cursor = page.endCursor, !cursor.isEmpty, seenCursors.insert(cursor).inserted else { throw incomplete }
        return cursor
    }
    func index() async throws -> StarListIndex {
        var after: String?, seenCursors = Set<String>(), seen = Set<String>(), lists: [StarRepositoryList] = []
        var owner: StarListOwner?, total: Int?
        for _ in 0..<50 {
            let page: IndexPage = try await result("query StarListIndex($after:String) { viewer { id login lists(first:100,after:$after) { nodes { \(Self.fields) } totalCount pageInfo { hasNextPage endCursor } } } }", ["after": after as Any? ?? NSNull()])
            let viewer = StarListOwner(id: page.viewer.id, login: page.viewer.login), connection = page.viewer.lists
            guard owner == nil || owner == viewer, total == nil || total == connection.totalCount else { throw incomplete }
            owner = viewer; total = connection.totalCount
            for list in connection.nodes {
                guard !list.id.isEmpty, list.user == viewer, seen.insert(list.id).inserted else { throw incomplete }
                lists.append(list)
            }
            after = try next(connection.pageInfo, seenCursors: &seenCursors)
            if after == nil {
                guard lists.count == total else { throw incomplete }
                return StarListIndex(owner: viewer, lists: lists)
            }
            guard !connection.nodes.isEmpty else { throw incomplete }
        }
        throw incomplete
    }
    func repositories(in list: StarRepositoryList) async throws -> [StarListRepository] {
        var budget = 0
        return try await repositories(in: list, budget: &budget)
    }
    private func repositories(in list: StarRepositoryList, budget: inout Int) async throws -> [StarListRepository] {
        var after: String?, seenCursors = Set<String>(), seen = Set<String>(), values: [StarListRepository] = []
        var total: Int?
        for _ in 0..<50 {
            budget += 1; guard budget <= 200 else { throw incomplete }
            let page: ItemsPage = try await result("query StarListItems($id:ID!,$after:String) { viewer { id login } node(id:$id) { ... on UserList { id user { id login } items(first:100,after:$after) { nodes { ... on Repository { \(Self.repositoryFields) } } totalCount pageInfo { hasNextPage endCursor } } } } }", ["id": list.id, "after": after as Any? ?? NSNull()])
            let connection = page.node.items
            guard page.viewer == list.user, page.node.id == list.id, page.node.user == page.viewer,
                  total == nil || total == connection.totalCount else { throw incomplete }
            total = connection.totalCount
            for item in connection.nodes {
                guard item.databaseId > 0, !item.id.isEmpty, seen.insert(item.id).inserted,
                      (try? RepositoryInput.parse(item.nameWithOwner)) == item.nameWithOwner else { throw incomplete }
                values.append(item)
            }
            after = try next(connection.pageInfo, seenCursors: &seenCursors)
            if after == nil { guard values.count == total else { throw incomplete }; return values }
            guard !connection.nodes.isEmpty else { throw incomplete }
        }
        throw incomplete
    }
    private func owned(_ list: StarRepositoryList, in index: StarListIndex) throws -> StarRepositoryList {
        guard index.owner == list.user, let current = index.lists.first(where: { $0.id == list.id }) else { throw incomplete }
        return current
    }
    private func name(_ text: String) throws -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 512,
              !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AppError(text: "请输入有效的分类名称（不超过512字节）。")
        }
        return clean
    }
    func create(name text: String) async throws -> StarRepositoryList {
        let title = try name(text), current = try await index()
        let value: ListResult = try await result("mutation CreateStarList($input:CreateUserListInput!) { createUserList(input:$input) { list { \(Self.fields) } } }", ["input": ["name": title, "isPrivate": true]], key: "createUserList")
        guard value.list.name == title, value.list.isPrivate, value.list.user == current.owner else { throw incomplete }
        return value.list
    }
    func rename(_ list: StarRepositoryList, name text: String) async throws -> StarRepositoryList {
        let title = try name(text), current = try owned(list, in: await index())
        let value: ListResult = try await result("mutation RenameStarList($input:UpdateUserListInput!) { updateUserList(input:$input) { list { \(Self.fields) } } }", ["input": ["listId": current.id, "name": title]], key: "updateUserList")
        guard value.list.id == current.id, value.list.name == title, value.list.isPrivate == current.isPrivate, value.list.user == current.user else { throw incomplete }
        return value.list
    }
    func delete(_ list: StarRepositoryList) async throws {
        let current = try owned(list, in: await index())
        let value: UserResult = try await result("mutation DeleteStarList($input:DeleteUserListInput!) { deleteUserList(input:$input) { user { id login } } }", ["input": ["listId": current.id]], key: "deleteUserList")
        guard value.user == current.user else { throw incomplete }
        let verified = try await index()
        guard verified.owner == current.user, !verified.lists.contains(where: { $0.id == current.id }) else { throw incomplete }
    }
    func setMembership(_ repository: Repository, list: StarRepositoryList, included: Bool) async throws {
        let fullName = try RepositoryInput.parse(repository.full_name), parts = fullName.split(separator: "/").map(String.init)
        let current = try await index(); _ = try owned(list, in: current)
        let page: RepositoryPage = try await result("query StarListTarget($owner:String!,$name:String!) { viewer { id login } repository(owner:$owner,name:$name) { \(Self.repositoryFields) } }", ["owner": parts[0], "name": parts[1]])
        let target = page.repository
        guard page.viewer == current.owner, target.databaseId == repository.id,
              !target.id.isEmpty,
              target.nameWithOwner.caseInsensitiveCompare(fullName) == .orderedSame else { throw incomplete }
        guard target.viewerHasStarred else { throw AppError(text: "该仓库未加星标。请先加星标再调整分类；不会自动替你加星标。") }
        var memberIDs = Set<String>(), budget = 0
        for candidate in current.lists {
            let values = try await repositories(in: candidate, budget: &budget)
            if values.contains(where: { $0.id == target.id }) { memberIDs.insert(candidate.id) }
        }
        if memberIDs.contains(list.id) == included { return }
        if included { memberIDs.insert(list.id) } else { memberIDs.remove(list.id) }
        // The official mutation replaces the complete set; it offers no server-side CAS.
        let value: MembershipResult = try await result("mutation SetStarListMembership($input:UpdateUserListsForItemInput!) { updateUserListsForItem(input:$input) { item { ... on Repository { id } } user { id login } lists { \(Self.fields) } } }", ["input": ["itemId": target.id, "listIds": memberIDs.sorted()]], key: "updateUserListsForItem")
        guard value.user == current.owner, value.item.id == target.id,
              Set(value.lists.map(\.id)) == memberIDs, value.lists.count == memberIDs.count,
              value.lists.allSatisfy({ $0.user == current.owner }) else { throw incomplete }
    }
}
