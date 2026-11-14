
func expect(_ condition: Bool) { precondition(condition) }
enum AccountStore { static var activeID = "collections-fixture"; static var generation = UUID() }
enum CredentialStore { static var token = "fixture-not-a-secret"; static func read(account: String) -> String { token } }
struct GitHubMessage: Decodable { let message: String }
@MainActor final class GitHub {
    let accountID = AccountStore.activeID
    private let accountGeneration = AccountStore.generation
    private let session: URLSession
    var isCurrentSession: Bool { accountID == AccountStore.activeID && accountGeneration == AccountStore.generation }
    init() {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CollectionsProtocol.self]; config.urlCache = nil
        session = URLSession(configuration: config)
    }
    var lists: GitHubStarLists { .init(send: { try await self.starListGraphQL($0, variables: $1) }, isCurrent: { self.isCurrentSession }) }
    // PRODUCTION_TRANSPORT
}

final class CollectionsProtocol: URLProtocol, @unchecked Sendable {
    static var handler: (([String: Any]) throws -> Any)!
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        precondition(request.url?.absoluteString == "https://api.github.com/graphql")
        precondition(request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-not-a-secret")
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); guard count >= 0 else { throw URLError(.cannotDecodeRawData) }; if count == 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            }
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let result = try Self.handler(object), bytes = try JSONSerialization.data(withJSONObject: result)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class CollectionsScenario: @unchecked Sendable {
    let owner: [String: Any] = ["id": "U_fixture", "login": "fixture"]
    var listIDs = ["A", "B"], members = ["A": Set<String>(), "B": Set(["R1"])], names = ["A": "Tools", "B": "Other"]
    var starred = true, brokenIndex = false, brokenItems = false, repeatedCursor = false, unknownWrite = false
    var unknownMembershipAfterApply = false
    var wrongOwner = false, wrongRepository = false, switchAccount = false, paginated = false, itemPages = false
    var writes: [[String: Any]] = []
    func list(_ id: String) -> [String: Any] {
        ["id": id, "name": names[id] ?? id, "isPrivate": id != "B", "user": owner,
         "items": ["totalCount": members[id]?.count ?? 0]]
    }
    func repo(_ id: String = "R1") -> [String: Any] {
        ["id": id, "databaseId": wrongRepository ? 999 : Int(id.dropFirst())!, "nameWithOwner": "fixture/project", "name": "project", "description": "Fixture repository",
         "url": "https://github.com/fixture/project", "updatedAt": "2026-11-13T00:00:00Z", "owner": ["login": "fixture"], "viewerHasStarred": starred]
    }
    func connection(_ nodes: [[String: Any]], next: Bool = false, cursor: String = "next", total: Int? = nil) -> [String: Any] {
        ["nodes": nodes, "totalCount": total ?? nodes.count, "pageInfo": ["hasNextPage": next, "endCursor": next ? cursor as Any : NSNull()]]
    }
    func respond(_ object: [String: Any]) throws -> Any {
        let query = object["query"] as! String, vars = object["variables"] as! [String: Any]
        if query.hasPrefix("query StarListIndex") {
            if switchAccount { AccountStore.generation = UUID() }
            let rows = listIDs.map(list)
            let next = repeatedCursor || (paginated && vars["after"] is NSNull && rows.count > 1)
            let nodes = next ? Array(rows.prefix(1)) : (paginated && !(vars["after"] is NSNull) ? Array(rows.dropFirst()) : rows)
            var viewer = owner; viewer["lists"] = connection(nodes, next: next, total: rows.count)
            var value: [String: Any] = ["data": ["viewer": viewer]]
            if brokenIndex { value["errors"] = [["message": "Partial page"]] }
            return value
        }
        if query.hasPrefix("query StarListItems") {
            let id = vars["id"] as! String
            if brokenItems { return ["data": ["viewer": owner, "node": NSNull()]] }
            let rows = (members[id] ?? []).sorted().map { repo($0) }
            let first = itemPages && id == "B" && vars["after"] is NSNull && rows.count > 1
            let nodes = first ? Array(rows.suffix(1)) : (itemPages && id == "B" && !(vars["after"] is NSNull) ? Array(rows.dropLast()) : rows)
            return ["data": ["viewer": owner, "node": ["id": id,
                "user": wrongOwner ? ["id": "U_other", "login": "other"] : owner, "items": connection(nodes, next: first, total: rows.count)]]]
        }
        if query.hasPrefix("query StarListTarget") { return ["data": ["viewer": owner, "repository": repo()]] }
        precondition(query.hasPrefix("mutation "))
        writes.append(object)
        if unknownWrite { throw URLError(.timedOut) }
        let input = vars["input"] as! [String: Any]
        if query.hasPrefix("mutation CreateStarList") {
            precondition(input["isPrivate"] as? Bool == true)
            listIDs.append("C"); names["C"] = input["name"] as? String; members["C"] = []
            return ["data": ["createUserList": ["list": list("C")]]]
        }
        if query.hasPrefix("mutation RenameStarList") {
            precondition(input["isPrivate"] == nil && input["description"] == nil)
            let id = input["listId"] as! String; names[id] = input["name"] as? String
            return ["data": ["updateUserList": ["list": list(id)]]]
        }
        if query.hasPrefix("mutation DeleteStarList") {
            let id = input["listId"] as! String; listIDs.removeAll { $0 == id }; members[id] = nil
            return ["data": ["deleteUserList": ["user": owner]]]
        }
        precondition(query.hasPrefix("mutation SetStarListMembership") && input["itemId"] as? String == "R1")
        let ids = Set(input["listIds"] as! [String])
        for id in listIDs { if ids.contains(id) { members[id, default: []].insert("R1") } else { members[id]?.remove("R1") } }
        if unknownMembershipAfterApply { throw URLError(.timedOut) }
        return ["data": ["updateUserListsForItem": ["user": owner, "item": ["id": "R1"], "lists": ids.sorted().map(list)]]]
    }
}

@main struct RepositoryCollectionsHarness {
    @MainActor static func reject(_ operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure("Invalid operation unexpectedly succeeded") } catch {}
    }
    @MainActor static func main() async throws {
        var count = 0
        func pass(_ label: String) { count += 1; print("PASS \(label)") }
        let repo = try JSONDecoder().decode(Repository.self, from: JSONSerialization.data(withJSONObject: ["id": 1, "full_name": "fixture/project", "name": "project", "html_url": "https://github.com/fixture/project"]))
        let second = try JSONDecoder().decode(Repository.self, from: JSONSerialization.data(withJSONObject: ["id": 2, "full_name": "fixture/second", "name": "second", "html_url": "https://github.com/fixture/second"]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RepositoryFavorites(accountID: "first", root: folder), other = RepositoryFavorites(accountID: "second", root: folder)
        expect(try store.read().isEmpty); try store.save([repo, second])
        expect(try store.read().map(\.id) == [1, 2]); expect(try other.read().isEmpty)
        pass("favorite persistence and account separation")
        let original = try Data(contentsOf: store.location)
        await reject { try store.save([repo, repo]) }; expect(try Data(contentsOf: store.location) == original)
        await reject { try store.save(Array(repeating: repo, count: 201)) }; expect(try Data(contentsOf: store.location) == original)
        pass("duplicate and over-budget favorites preserve originals")
        try Data("broken JSON".utf8).write(to: store.location)
        await reject { _ = try store.read() }; expect(try Data(contentsOf: store.location) == Data("broken JSON".utf8))
        pass("corrupt favorite data is not silently replaced")
        try Data(repeating: 32, count: RepositoryFavorites.maximumBytes + 1).write(to: store.location)
        await reject { _ = try store.read() }
        pass("oversized persisted favorite data rejected before decode")
        let stateID = "fixture-" + UUID().uuidString
        defer { RepositoryFavorites.removeAccount(stateID) }
        var active = true
        let state = RepositoryFavoritesState(accountID: stateID, isCurrent: { active })
        try state.add(repo); try state.add(repo); try state.add(second); try state.reorder([2, 1])
        precondition(state.repositories.map(\.id) == [2, 1])
        let reopened = RepositoryFavoritesState(accountID: stateID, isCurrent: { active }); precondition(reopened.repositories.map(\.id) == [2, 1])
        await reject { try state.reorder([1]) }; active = false; await reject { try state.remove([1]) }
        active = true; try state.remove([1]); precondition(state.repositories.map(\.id) == [2])
        RepositoryFavorites.removeAccount(stateID); expect(try RepositoryFavorites(accountID: stateID).read().isEmpty)
        pass("favorite duplicate updates, reorder, stale-account guard and removal cleanup")

        func install(_ scenario: CollectionsScenario) -> GitHub {
            AccountStore.generation = UUID(); CollectionsProtocol.handler = scenario.respond; CollectionsProtocol.requests = 0
            return GitHub()
        }
        let scenario = CollectionsScenario(); scenario.paginated = true; scenario.itemPages = true; scenario.members["B"] = ["R1", "R2"]
        let api = install(scenario), index = try await api.lists.index()
        precondition(index.lists.count == 2); pass("official lists read all pages")
        try await api.lists.setMembership(repo, list: index.lists[0], included: true)
        let input = (scenario.writes.last!["variables"] as! [String: Any])["input"] as! [String: Any]
        precondition(input["listIds"] as? [String] == ["A", "B"])
        try await api.lists.setMembership(repo, list: index.lists[0], included: false)
        precondition(scenario.members["A"]!.isEmpty && scenario.members["B"]! == ["R1", "R2"])
        pass("membership pagination add/remove preserves other lists and star status")
        let created = try await api.lists.create(name: "  私密分类\" }  ")
        precondition(created.name == "私密分类\" }" && created.isPrivate)
        _ = try await api.lists.rename(index.lists[1], name: "Public renamed")
        try await api.lists.delete(created)
        precondition(!scenario.listIDs.contains(created.id) && scenario.starred)
        pass("private create, rename visibility preservation and delete without unstar")
        for mode in ["partial", "cursor", "items", "owner", "repository", "unstarred", "switched"] {
            let s = CollectionsScenario()
            switch mode {
            case "partial": s.brokenIndex = true
            case "cursor": s.repeatedCursor = true
            case "items": s.brokenItems = true
            case "owner": s.wrongOwner = true
            case "repository": s.wrongRepository = true
            case "unstarred": s.starred = false
            default: s.switchAccount = true
            }
            let value = install(s)
            await reject { try await value.lists.setMembership(repo, list: index.lists[0], included: true) }
            precondition(s.writes.isEmpty); pass("reject \(mode) before any membership write")
        }
        let unknown = CollectionsScenario(), unknownAPI = install(unknown); unknown.unknownWrite = true
        await reject { _ = try await unknownAPI.lists.create(name: "Timeout") }; precondition(unknown.writes.count == 1)
        pass("unknown mutation result is never automatically resent")
        let applied = CollectionsScenario(), appliedAPI = install(applied)
        applied.unknownMembershipAfterApply = true
        await reject { try await appliedAPI.lists.setMembership(repo, list: index.lists[0], included: true) }
        precondition(applied.writes.count == 1)
        expect(try await appliedAPI.lists.repositories(in: index.lists[0]).map(\.id) == ["R1"])
        precondition(applied.writes.count == 1 && applied.members["B"] == ["R1"] && applied.starred)
        applied.unknownMembershipAfterApply = false
        try await appliedAPI.lists.setMembership(repo, list: index.lists[0], included: true)
        precondition(applied.writes.count == 1)
        applied.unknownMembershipAfterApply = true
        await reject { try await appliedAPI.lists.setMembership(repo, list: index.lists[0], included: false) }
        expect(try await appliedAPI.lists.repositories(in: index.lists[0]).isEmpty)
        precondition(applied.writes.count == 2 && applied.members["B"] == ["R1"] && applied.starred)
        pass("applied-but-unknown add/remove reconciles read-only, without resend or other-list rollback")
        let noToken = CollectionsScenario(), noTokenAPI = install(noToken); CredentialStore.token = ""
        await reject { _ = try await noTokenAPI.lists.index() }; precondition(CollectionsProtocol.requests == 0)
        CredentialStore.token = "fixture-not-a-secret"
        pass("missing credentials stop before network")
        let cancelledAPI = install(CollectionsScenario())
        let cancelled = Task { try await cancelledAPI.lists.index() }; cancelled.cancel()
        await reject { _ = try await cancelled.value }; precondition(CollectionsProtocol.requests == 0)
        pass("cancelled read stops before transport")
        let invalidAPI = install(CollectionsScenario())
        await reject { _ = try await invalidAPI.lists.create(name: " \n ") }; precondition(CollectionsProtocol.requests == 0)
        pass("invalid list title rejected before transport")
        print("Repository collections: \(count) production checks passed")
    }
}
