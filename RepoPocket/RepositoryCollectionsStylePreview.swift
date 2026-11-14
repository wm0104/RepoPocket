#if DEBUG
import SwiftUI

/// Shipping home/search/collection screens; every network operation stays in URLProtocol.
struct RepositoryCollectionsStylePreview: View {
    @State private var api: GitHub?
    @State private var error = ""
    @State private var writes = 0
    @StateObject private var accountPresentation = AccountPresentation()
    var body: some View {
        Group {
            if let api {
                RepositoriesView(api: api).environmentObject(accountPresentation)
                    .id(api.accountID)
                    .safeAreaInset(edge: .bottom) {
                        HStack {
                            Button("切换测试账号") { prepare(api.accountID == "collections-style-preview" ? "collections-other-preview" : "collections-style-preview") }
                            Text("分类写入：\(writes)").accessibilityIdentifier("collection-preview-writes")
                        }.font(.caption).frame(minHeight: 44).background(Color(uiColor: .secondarySystemBackground))
                    }
            } else if !error.isEmpty { Text(error) }
            else { ProgressView("准备收藏与分类回归…") }
        }.preferredColorScheme(.light)
        .onReceive(NotificationCenter.default.publisher(for: .init("CollectionsPreview.write")).receive(on: RunLoop.main)) { _ in writes += 1 }
        .task {
            guard api == nil else { return }
            if !ProcessInfo.processInfo.arguments.contains("-keep-collection-favorites") {
                RepositoryFavorites.removeAccount("collections-style-preview"); RepositoryFavorites.removeAccount("collections-other-preview")
            }
            CollectionsPreviewProtocol.reset(); prepare("collections-style-preview")
        }
    }
    private func prepare(_ id: String) {
        do {
            try CredentialStore.save("fixture-collections", account: id)
            try AccountStore.record(.init(id: id, login: "fixture-owner", avatarURL: nil)); AccountStore.activate(id)
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CollectionsPreviewProtocol.self]; config.urlCache = nil
            api = GitHub(configuration: config)
        } catch { self.error = error.localizedDescription }
    }
}

private final class CollectionsPreviewProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var lists = ["A": "工具", "B": "其他分类"]
    private static var members = ["A": Set<Int>(), "B": Set([1])]
    static func reset() { lock.lock(); defer { lock.unlock() }; lists = ["A": "工具", "B": "其他分类"]; members = ["A": [], "B": [1]] }
    private static let owner: [String: Any] = ["id": "U_fixture", "login": "fixture-owner"]
    private static func repository(_ id: Int) -> [String: Any] {
        ["id": id, "name": id == 1 ? "collection-fixture" : "second", "full_name": "fixture-owner/" + (id == 1 ? "collection-fixture" : "second"),
         "html_url": "https://github.com/fixture-owner/" + (id == 1 ? "collection-fixture" : "second"), "default_branch": "main",
         "description": "收藏与Star分类测试仓库", "owner": ["id": 1, "login": "fixture-owner"], "permissions": ["push": true],
         "updated_at": "2026-11-13T00:00:00Z", "stargazers_count": 2, "forks_count": 0]
    }
    private static func graphRepository(_ id: Int) -> [String: Any] {
        let repo = repository(id)
        return ["id": "R\(id)", "databaseId": id, "nameWithOwner": repo["full_name"]!, "name": repo["name"]!, "description": repo["description"]!,
                "url": repo["html_url"]!, "updatedAt": repo["updated_at"]!, "owner": repo["owner"]!, "viewerHasStarred": true]
    }
    private static func list(_ id: String) -> [String: Any] {
        ["id": id, "name": lists[id]!, "isPrivate": true, "user": owner, "items": ["totalCount": members[id]?.count ?? 0]]
    }
    private static func connection(_ nodes: [[String: Any]]) -> [String: Any] {
        ["nodes": nodes, "totalCount": nodes.count, "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "api.github.com", request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-collections" else {
            reply(["message": "Fixture refuses this host or credential"], status: 403); return
        }
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        if path == "/graphql", method == "POST" { graph(); return }
        guard method == "GET" else { reply(["message": "No real or unrelated writes"], status: 403); return }
        if path == "/user" { reply(["id": 1, "login": "fixture-owner", "name": "测试账号", "followers": 0, "following": 0]) }
        else if path == "/user/repos" || path == "/user/starred" { reply([Self.repository(1), Self.repository(2)]) }
        else if path == "/search/repositories" { reply(["total_count": 2, "items": [Self.repository(1), Self.repository(2)]]) }
        else if path == "/search/issues" { reply(["total_count": 0, "items": []]) }
        else if path == "/repos/fixture-owner/collection-fixture" { reply(Self.repository(1)) }
        else if path == "/repos/fixture-owner/second" { reply(Self.repository(2)) }
        else if path.hasPrefix("/user/starred/") { reply([:], status: 204) }
        else if path.hasSuffix("/contents") || path.hasSuffix("/forks") || path.hasSuffix("/releases") || path.hasSuffix("/branches") { reply([]) }
        else if path.hasSuffix("/actions/runs") { reply(["workflow_runs": []]) }
        else { reply(["message": "Fixture endpoint not provided"], status: 404) }
    }
    private func graph() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
        }
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], let query = object["query"] as? String,
              let vars = object["variables"] as? [String: Any] else { reply([:], status: 400); return }
        Self.lock.lock()
        let payload: [String: Any]
        if query.hasPrefix("query StarListIndex") {
            var viewer = Self.owner; viewer["lists"] = Self.connection(Self.lists.keys.sorted().map(Self.list)); payload = ["viewer": viewer]
        } else if query.hasPrefix("query StarListItems"), let id = vars["id"] as? String, Self.lists[id] != nil {
            payload = ["viewer": Self.owner, "node": ["id": id, "user": Self.owner, "items": Self.connection((Self.members[id] ?? []).sorted().map(Self.graphRepository))]]
        } else if query.hasPrefix("query StarListTarget") {
            payload = ["viewer": Self.owner, "repository": Self.graphRepository(vars["name"] as? String == "second" ? 2 : 1)]
        } else if query.hasPrefix("mutation "), let input = vars["input"] as? [String: Any] {
            if query.hasPrefix("mutation CreateStarList"), let name = input["name"] as? String, input["isPrivate"] as? Bool == true {
                Self.lists["C"] = name; Self.members["C"] = []; payload = ["createUserList": ["list": Self.list("C")]]
            } else if query.hasPrefix("mutation RenameStarList"), let id = input["listId"] as? String, Self.lists[id] != nil, let name = input["name"] as? String {
                Self.lists[id] = name; payload = ["updateUserList": ["list": Self.list(id)]]
            } else if query.hasPrefix("mutation DeleteStarList"), let id = input["listId"] as? String {
                Self.lists[id] = nil; Self.members[id] = nil; payload = ["deleteUserList": ["user": Self.owner]]
            } else if query.hasPrefix("mutation SetStarListMembership"), let item = input["itemId"] as? String,
                      let id = Int(item.dropFirst()), let ids = input["listIds"] as? [String], ids.allSatisfy({ Self.lists[$0] != nil }) {
                for key in Self.lists.keys { if ids.contains(key) { Self.members[key, default: []].insert(id) } else { Self.members[key]?.remove(id) } }
                payload = ["updateUserListsForItem": ["item": ["id": item], "user": Self.owner, "lists": ids.map(Self.list)]]
            } else { Self.lock.unlock(); reply(["errors": [["message": "Unexpected fixture mutation"]]]); return }
            NotificationCenter.default.post(name: .init("CollectionsPreview.write"), object: nil)
        } else { Self.lock.unlock(); reply(["errors": [["message": "Unexpected fixture query"]]]); return }
        Self.lock.unlock(); reply(["data": payload])
    }
    private func reply(_ object: Any, status: Int = 200) {
        let data = status == 204 ? Data() : try! JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
