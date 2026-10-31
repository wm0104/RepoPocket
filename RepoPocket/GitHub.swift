import Foundation
import CryptoKit
import Combine
import Security

struct AppError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

struct GitHubAPIError: LocalizedError {
    let status: Int
    let operation: String
    let reason: String
    let permissions: String?
    var errorDescription: String? {
        var text = "HTTP \(status) · \(operation)\n\(reason)"
        if status == 403 && reason.lowercased().contains("resource not accessible") {
            text += "\n请检查 Token 的仓库范围及权限。登录和浏览成功不代表有提交权限。"
            if let required = permissions, !required.isEmpty {
                text += "\n此接口要求：" + required
            }
        } else if status == 401 {
            text += "\nToken 无效或已过期，请在设置中重新保存。"
        }
        return text
    }
}

enum CredentialStore {
    private static let service = "com.wm0104.RepoPocket.github"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account == "legacy" ? "token" : "user:" + account]
    }
    static func read(account: String = AccountStore.activeID) -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ token: String, account: String = AccountStore.activeID) throws {
        let data = Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                  kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw AppError(text: "钥匙串保存失败（\(added)）") }
        } else if status != errSecSuccess {
            throw AppError(text: "钥匙串更新失败（\(status)）")
        }
        AccountStore.updateAuthorization(account, scopes: nil)
    }
    static func clear(account: String = AccountStore.activeID) { SecItemDelete(query(account) as CFDictionary) }
}

struct User: Decodable {
    let id: Int?
    let login: String
    let avatar_url: String?
    let name: String?
    let followers: Int?
    let following: Int?
}

struct RepoAccess: Decodable {
    struct Permissions: Decodable { let push: Bool? }
    let full_name: String
    let permissions: Permissions?
}
struct RepositoryReference: Decodable {
    let full_name: String
    let html_url: String?
    let default_branch: String?
}
struct Repository: Decodable, Identifiable {
    let id: Int
    let full_name: String
    let name: String
    let description: String?
    let default_branch: String?
    let html_url: String
    let owner: User?
    let `private`: Bool?
    let updated_at: String?
    // Optional API fields keep older/missing payloads decodable; nil is not zero.
    let stargazers_count: Int?
    let forks_count: Int?
    let language: String?
    let fork: Bool?
    let parent: RepositoryReference?
    let source: RepositoryReference?
    struct Permissions: Decodable { let admin: Bool?; let push: Bool? }
    let permissions: Permissions?
}
struct Entry: Decodable, Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let type: String
    let sha: String
    let size: Int?
    let download_url: String?
    let content: String?
    let encoding: String?
}
struct Release: Decodable, Identifiable {
    let id: Int
    let tag_name: String
    let name: String?
    let draft: Bool
    let upload_url: String
    let html_url: String
    let assets: [Asset]
}
struct Asset: Decodable, Identifiable {
    let id: Int
    let name: String
    let size: Int
    let browser_download_url: String
}
struct GitHubMessage: Decodable { let message: String }

struct TrollPublishResult { let commitSHA: String; let path: String }

final class TransferProgress: NSObject, URLSessionTaskDelegate {
    let update: (Double) -> Void
    init(update: @escaping (Double) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 {
            update(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        }
    }
}

@MainActor
final class GitHub: ObservableObject {
    @Published var message = ""
    @Published var login = ""
    @Published var avatarURL: String?
    @Published var profile: User?
    @Published private(set) var profileWriteAuthorization: Bool? = nil
    let accountID = AccountStore.activeID
    private let session: URLSession
    private let accountGeneration = AccountStore.generation
    private var accountObserver: AnyCancellable?
    private var authorizationObserver: AnyCancellable?
    // Session-scoped caches never publish mutations to the whole repository list.
    private var parentTasks: [String: Task<RepositoryReference?, Never>] = [:]
    private var parentCache: [String: (Date, RepositoryReference?)] = [:]
    private var parentActive = 0
    private var parentWaiters: [CheckedContinuation<Void, Never>] = []
    private var collectionCache: [RepositoryHomeSection: [Repository]] = [:]
    @Published private(set) var forkNames: [String: String] = [:]
    private var forkChecks: [String: Task<String?, Error>] = [:]
    private var forkCheckIDs: [String: UUID] = [:]
    private var forkCheckedAt: [String: Date] = [:]
    lazy var stars = RepositoryStarStore(api: self)
    lazy var follows = UserFollowStore(api: self)
    lazy var issueDeletions = IssueDeletionState()
    var issueDeletionSession: IssueDeletionSession { .init(accountID: accountID, generation: accountGeneration) }
    func issueDeletionGraphQL(_ query: String, variables: [String: Any]) async throws -> Data {
        try ensureActiveAccount(); try Task.checkCancellation()
        let bytes = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let r = try request(url("/graphql"), method: "POST", body: bytes)
        let response = try await session.data(for: r, delegate: OfficialUpdateRedirectPolicy())
        try check(response.0, response.1, operation: "议题权限与删除")
        try ensureActiveAccount(); try Task.checkCancellation()
        guard response.0.count <= 1_048_576 else { throw AppError(text: "议题响应过大，请重试。") }
        return response.0
    }
    @Published private(set) var starRevision = 0
    func requireStarSession() throws {
        try ensureActiveAccount()
        guard !CredentialStore.read(account: accountID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError(text: "请登录账号") }
    }
    func starRequest(_ name: String, method: String) async throws -> Bool {
        try requireStarSession()
        let canonical = try RepositoryInput.parse(name)
        let path = "/user/starred/" + canonical.split(separator: "/").map { Self.component(String($0)) }.joined(separator: "/")
        guard ["GET", "PUT", "DELETE"].contains(method) else { throw AppError(text: "无效星标操作") }
        // Personal starring is not repository push access. Keep its own auth/session gate.
        let r = try request(url(path), method: method)
        let (_, response) = try await session.data(for: r)
        try requireStarSession()
        guard let http = response as? HTTPURLResponse else { throw AppError(text: "无有效服务器响应") }
        return try RepositoryStarRules.status(http.statusCode, checking: method == "GET")
    }
    func applyStarChange(name: String, starred: Bool, repository: Repository?) {
        guard isCurrentSession else { return }
        let matches: (Repository) -> Bool = { $0.full_name.caseInsensitiveCompare(name) == .orderedSame }
        if let repository, let owned = collectionCache[.owned] {
            collectionCache[.owned] = owned.map { matches($0) ? repository : $0 }
        }
        if var list = collectionCache[.starred] {
            list.removeAll(where: matches)
            if starred {
                if let repository { list.insert(repository, at: 0) }
                else { collectionCache[.starred] = nil; starRevision += 1; return }
            }
            collectionCache[.starred] = list
        }
        starRevision += 1
    }
    var canCheckAppUpdate: Bool { isCurrentSession && !CredentialStore.read(account: accountID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// The public releases endpoint works signed out; a token only raises the rate limit.
    var canCheckOfficialUpdate: Bool { isCurrentSession }
    func cachedCollection(_ section: RepositoryHomeSection) -> [Repository]? { collectionCache[section] }
    func cacheCollection(_ repositories: [Repository], section: RepositoryHomeSection) {
        collectionCache[section] = repositories
        if section == .starred { stars.seed(repositories) }
    }
    func forkParent(for repository: Repository) async -> RepositoryReference? {
        guard repository.fork == true, isCurrentSession else { return nil }
        if let parent = repository.parent { return parent }
        let key = repository.full_name
        if let cached = parentCache[key], Date().timeIntervalSince(cached.0) < 300 { return cached.1 }
        if let pending = parentTasks[key] { return await pending.value }
        let task = Task<RepositoryReference?, Never> {
            await self.acquireParentSlot()
            defer { self.releaseParentSlot() }
            guard self.isCurrentSession else { return nil }
            do {
                let bytes = try await self.data(Self.repoPath(key))
                let parent = try await Task.detached(priority: .utility) {
                    try JSONDecoder().decode(Repository.self, from: bytes).parent
                }.value
                guard self.isCurrentSession else { return nil }
                return parent
            } catch { return nil }
        }
        parentTasks[key] = task
        let result = await task.value
        parentTasks[key] = nil
        if isCurrentSession {
            if parentCache.count >= 512, let oldest = parentCache.min(by: { $0.value.0 < $1.value.0 })?.key {
                parentCache[oldest] = nil
            }
            parentCache[key] = (Date(), result)
        }
        return result
    }
    private func acquireParentSlot() async {
        if parentActive < 3 { parentActive += 1; return }
        await withCheckedContinuation { parentWaiters.append($0) }
    }
    private func releaseParentSlot() {
        if parentWaiters.isEmpty { parentActive -= 1 }
        else { parentWaiters.removeFirst().resume() }
    }
    init(configuration: URLSessionConfiguration = .ephemeral) {
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
        profileWriteAuthorization = AccountStore.accounts.first { $0.id == accountID }?.profileWriteAuthorization
        authorizationObserver = NotificationCenter.default.publisher(for: .githubAuthorizationChanged)
            .sink { [weak self] notice in
                guard let self, self.isCurrentSession, notice.userInfo?["account"] as? String == self.accountID else { return }
                self.profileWriteAuthorization = AccountStore.accounts.first { $0.id == self.accountID }?.profileWriteAuthorization
            }
        accountObserver = NotificationCenter.default.publisher(for: .githubAccountChanged)
            .sink { [weak self] _ in
                self?.session.invalidateAndCancel()
                self?.stars.invalidate()
                self?.follows.invalidate()
            }
    }
    static func component(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters:
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
    }
    static func repoPath(_ fullName: String) throws -> String {
        let canonical = try RepositoryInput.parse(fullName)
        return "/repos/" + canonical.split(separator: "/").map { component(String($0)) }.joined(separator: "/")
    }
    static func filePath(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AppError(text: "请填写有效的仓库内文件路径，不能包含空目录或 ..")
        }
        return parts.map { component(String($0)) }.joined(separator: "/")
    }
    private func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let raw = URL(string: "https://api.github.com" + path),
              var c = URLComponents(url: raw, resolvingAgainstBaseURL: false) else {
            throw AppError(text: "无效请求地址")
        }
        if !query.isEmpty { c.queryItems = query }
        guard let u = c.url else { throw AppError(text: "无效请求参数") }
        return u
    }
    private func request(_ u: URL, method: String = "GET", body: Data? = nil,
                         binary: Bool = false) throws -> URLRequest {
        guard u.scheme == "https", let host = u.host,
              ["api.github.com", "uploads.github.com"].contains(host) else {
            throw AppError(text: "拒绝向非 GitHub API 地址发送凭据")
        }
        try ensureActiveAccount()
        let token = CredentialStore.read(account: accountID)
        guard !token.isEmpty else { throw AppError(text: "请先在设置中保存 GitHub Token") }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.httpBody = body
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("RepoPocket/1.0", forHTTPHeaderField: "User-Agent")
        if body != nil || binary {
            r.setValue(binary ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }
    // Public official update metadata only. Use the account-bound session and
    // never forward its credentials to release assets, CDN hosts or redirects.
    func officialAppUpdateData() async throws -> Data {
        try ensureActiveAccount()
        let endpoint = URL(string: "https://api.github.com/repos/wm0104/RepoPocket/releases/latest")!
        guard canCheckOfficialUpdate else { throw AppError(text: "请重新打开 App") }
        // Signed out, the public releases endpoint is still readable; a token is
        // attached only when present so the check never fails for lack of login.
        let token = CredentialStore.read(account: accountID).trimmingCharacters(in: .whitespacesAndNewlines)
        let authenticated = !token.isEmpty
        var r = URLRequest(url: endpoint)
        r.timeoutInterval = 30
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("RepoPocket", forHTTPHeaderField: "User-Agent")
        if authenticated { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.data(for: r, delegate: OfficialUpdateRedirectPolicy())
        try ensureActiveAccount()
        guard let http = response as? HTTPURLResponse else { throw AppError(text: "更新接口未返回有效 HTTP 响应。") }
        guard http.statusCode == 200 else {
            throw AppError(text: AppUpdateRules.statusError(http.statusCode, headers: http.allHeaderFields, body: bytes, authenticated: authenticated))
        }
        return bytes
    }
    func descriptionContext(_ repository: Repository) -> RepositoryDescriptionContext {
        RepositoryDescriptionContext(accountID: accountID, generation: accountGeneration, login: login,
                                     repositoryID: repository.id, fullName: repository.full_name)
    }
    func updateRepositoryDescription(_ repository: Repository, context: RepositoryDescriptionContext,
                                     description: String) async throws -> Repository {
        try ensureActiveAccount()
        guard context == descriptionContext(repository),
              RepositoryDescriptionRules.canEdit(repository, login: login, sessionMatches: isCurrentSession) else {
            throw AppError(text: RepositoryDescriptionRules.permissionHelp)
        }
        let updated = try await RepositoryDescriptionRules.execute(context: context, description: description,
            current: { RepositoryDescriptionContext(accountID: AccountStore.activeID,
                generation: AccountStore.generation, login: self.login,
                repositoryID: repository.id, fullName: repository.full_name) },
            fetch: { try await self.repository(context.fullName) },
            update: { value in
                try self.ensureActiveAccount()
                // Metadata editing requires administration, not Contents/push permission.
                // Send only description; never rename or change visibility/default branch.
                let body = try JSONSerialization.data(withJSONObject: ["description": value])
                let request = try self.request(self.url(Self.repoPath(context.fullName)), method: "PATCH", body: body)
                let (data, response) = try await self.session.data(for: request)
                do { try self.check(data, response, operation: "修改仓库描述") }
                catch let error as GitHubAPIError {
                    if [403, 404].contains(error.status) {
                        throw AppError(text: error.localizedDescription + "\n" + RepositoryDescriptionRules.permissionHelp)
                    }
                    throw error
                }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw AppError(text: "未收到 GitHub 保存成功确认，请刷新仓库核实。")
                }
                return try JSONDecoder().decode(Repository.self, from: data)
            })
        // Patch existing memory caches without publishing a global refresh signal.
        for section in Array(collectionCache.keys) {
            collectionCache[section] = collectionCache[section]?.map { $0.id == updated.id ? updated : $0 }
        }
        return updated
    }
    func deletionContext(_ repository: Repository) -> RepositoryDeletionContext {
        RepositoryDeletionContext(accountID: accountID, generation: accountGeneration,
                                  repositoryID: repository.id, fullName: repository.full_name)
    }
    func deleteRepository(_ repository: Repository, context: RepositoryDeletionContext,
                          confirmation: String) async throws -> String {
        try ensureActiveAccount()
        return try await RepositoryDeletion.execute(context: context, confirmation: confirmation,
            current: { RepositoryDeletionContext(accountID: AccountStore.activeID,
                generation: AccountStore.generation, repositoryID: repository.id, fullName: repository.full_name) },
            fetch: { try await self.repository(context.fullName) },
            remove: {
                try self.ensureActiveAccount()
                let path = try Self.repoPath(context.fullName)
                let r = try self.request(self.url(path), method: "DELETE")
                let (d, response) = try await self.session.data(for: r)
                do { try self.check(d, response, operation: "永久删除远端仓库") }
                catch let error as GitHubAPIError {
                    if [403, 404].contains(error.status) {
                        throw AppError(text: error.localizedDescription + "\n" + RepositoryDeletion.permissionHelp)
                    }
                    throw error
                }
                guard (response as? HTTPURLResponse)?.statusCode == 204 else {
                    throw AppError(text: "未收到 GitHub 删除成功确认（204），请刷新核实，勿盲目重试。")
                }
            })
    }
    var isCurrentSession: Bool {
        AccountStore.activeID == accountID && AccountStore.generation == accountGeneration
    }
    func requireWriteAccess(_ repo: String) async throws {
        try ensureActiveAccount()
        let info = try await decoded(RepoAccess.self, Self.repoPath(repo))
        try ensureActiveAccount()
        guard RepositoryWriteRules.canWrite(push: info.permissions?.push) else {
            throw AppError(text: "此账号没有已确认的仓库推送权限，不能上传、编辑或删除文件。")
        }
    }
    private func ensureActiveAccount() throws {
        guard AccountStore.activeID == accountID, AccountStore.generation == accountGeneration else {
            throw AppError(text: "账号已切换，请重新打开此页面。")
        }
    }
    private func check(_ data: Data, _ response: URLResponse, operation: String = "GitHub 请求") throws {
        try ensureActiveAccount()
        guard let h = response as? HTTPURLResponse else { throw AppError(text: "无有效服务器响应") }
        guard (200..<300).contains(h.statusCode) else {
            let reason = (try? JSONDecoder().decode(GitHubMessage.self, from: data).message) ?? "GitHub 请求失败"
            throw GitHubAPIError(status: h.statusCode, operation: operation, reason: reason,
                                 permissions: h.value(forHTTPHeaderField: "X-Accepted-GitHub-Permissions"))
        }
    }
    private func operation(_ path: String, method: String) -> String {
        if path.contains("/contents") {
            if method == "PUT" { return "提交文件（Contents 写入）" }
            if method == "DELETE" { return "删除文件（Contents 写入）" }
            return "读取仓库文件（Contents 读取）"
        }
        if path.hasSuffix("/forks") { return "Fork 仓库" }
        if path == "/user/repos" && method == "POST" { return "新建仓库" }
        if path.contains("/releases") { return "Release 操作（Contents 权限）" }
        return "GitHub 请求"
    }
    private func data(_ path: String, method: String = "GET", object: [String: Any]? = nil,
                      query: [URLQueryItem] = []) async throws -> Data {
        if method != "GET", path.hasPrefix("/repos/"), !path.hasSuffix("/forks") {
            let parts = path.split(separator: "/")
            guard parts.count >= 3,
                  let owner = String(parts[1]).removingPercentEncoding,
                  let name = String(parts[2]).removingPercentEncoding else { throw AppError(text: "无效写入目标") }
            try await requireWriteAccess(owner + "/" + name)
        }
        let body = try object.map { try JSONSerialization.data(withJSONObject: $0) }
        let r = try request(url(path, query: query), method: method, body: body)
        let (d, response) = try await session.data(for: r)
        try check(d, response, operation: operation(path, method: method))
        return d
    }
    private func decoded<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET",
                                       object: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: await data(path, method: method, object: object, query: query))
    }
    private func uploadGitBlobFile(_ file: URL, path: String, maximumBytes: Int64, expectedSize: Int64? = nil) async throws -> GitObject {
        try ensureActiveAccount()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let number = attributes[.size] as? NSNumber else { throw AppError(text: "请选择有效的普通文件。") }
        let sourceSize = number.int64Value
        guard sourceSize >= 0, sourceSize <= maximumBytes,
              expectedSize == nil || expectedSize == sourceSize else { throw AppError(text: "文件已变化或超过上传大小限制。") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RepoPocket-GitBlob-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bodyFile = directory.appendingPathComponent("request.json")
        guard FileManager.default.createFile(atPath: bodyFile.path, contents: nil) else { throw AppError(text: "无法准备上传请求。") }
        let writer = Task.detached(priority: .utility) { () throws -> Void in
            let input = try FileHandle(forReadingFrom: file)
            let output = try FileHandle(forWritingTo: bodyFile)
            defer { try? input.close(); try? output.close() }
            try output.write(contentsOf: Data("{\"content\":\"".utf8))
            var carry = Data()
            var totalBytes: Int64 = 0
            while let chunk = try input.read(upToCount: 192 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                let count = Int64(chunk.count)
                guard totalBytes <= maximumBytes - count else { throw AppError(text: "文件超过上传大小限制。") }
                totalBytes += count
                carry.append(chunk)
                let completeCount = (carry.count / 3) * 3
                if completeCount > 0 {
                    try output.write(contentsOf: Data(carry.prefix(completeCount)).base64EncodedData())
                    carry = Data(carry.dropFirst(completeCount))
                }
            }
            if !carry.isEmpty { try output.write(contentsOf: carry.base64EncodedData()) }
            guard totalBytes == sourceSize else { throw AppError(text: "文件在上传准备期间发生变化，请重新选择。") }
            try output.write(contentsOf: Data("\",\"encoding\":\"base64\"}".utf8))
            try output.synchronize()
        }
        try await withTaskCancellationHandler {
            try await writer.value
        } onCancel: {
            writer.cancel()
        }
        try ensureActiveAccount()
        var uploadRequest = try request(url(path), method: "POST")
        uploadRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (bytes, response) = try await session.upload(for: uploadRequest, fromFile: bodyFile)
        try check(bytes, response, operation: "上传 Git 文件")
        try ensureActiveAccount()
        return try JSONDecoder().decode(GitObject.self, from: bytes)
    }
    func history(_ repo: String, branch: String, page: Int) async throws -> [DesktopCommit] {
        try await decoded([DesktopCommit].self, Self.repoPath(repo) + "/commits", query: [
            .init(name: "sha", value: branch), .init(name: "per_page", value: "30"), .init(name: "page", value: String(page))])
    }
    func commitDetail(_ repo: String, sha: String, page: Int) async throws -> DesktopCommit {
        try await decoded(DesktopCommit.self, Self.repoPath(repo) + "/commits/" + Self.component(sha), query: [
            .init(name: "per_page", value: "100"), .init(name: "page", value: String(page))])
    }
    func branches(_ repo: String, page: Int) async throws -> [DesktopBranch] {
        try await decoded([DesktopBranch].self, Self.repoPath(repo) + "/branches", query: [
            .init(name: "per_page", value: "100"), .init(name: "page", value: String(page))])
    }
    func createBranch(_ repo: String, name: String, from source: String, expectedHead: String) async throws {
        guard DesktopRules.validBranch(name) else { throw AppError(text: "分支名不符合 Git 引用规则") }
        guard try await workspaceHead(repo, branch: source) == expectedHead else {
            throw AppError(text: "来源分支已变化，请重新加载后创建")
        }
        _ = try await data(Self.repoPath(repo) + "/git/refs", method: "POST", object: ["ref": "refs/heads/" + name, "sha": expectedHead])
    }
    func fetchWorkspace(_ repo: String, branch: String, revision: String = "") async throws -> (WorkspaceBinding, URL) {
        let repo = try RepositoryInput.parse(repo)
        let branch = try await resolvedBranch(repo, branch: branch)
        let endpoint = try Self.repoPath(repo)
        let head: String
        if revision.isEmpty { head = try await workspaceHead(repo, branch: branch) } else { head = revision }
        let commit = try await decoded(GitCommitInfo.self, endpoint + "/git/commits/" + Self.component(head))
        let tree = try await decoded(GitTreeInfo.self, endpoint + "/git/trees/" + Self.component(commit.tree.sha), query: [.init(name: "recursive", value: "1")])
        guard !tree.truncated, tree.tree.count <= 20000, tree.tree.allSatisfy({ $0.type == "tree" || ($0.type == "blob" && ["100644", "100755"].contains($0.mode)) }) else { throw AppError(text: "远端树过大或含符号链接/子模块，不支持安全拉取") }
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        do {
            var total = 0
            var seen = Set<String>()
            for item in tree.tree {
                _ = try Self.filePath(item.path)
                guard !item.path.contains("\\"), !item.path.contains("\0"), !item.path.contains(":"), !item.path.split(separator: "/").contains(".git"),
                      seen.insert(item.path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw AppError(text: "远端包含不安全或大小写重复路径") }
            }
            for item in tree.tree where item.type == "blob" {
                _ = try Self.filePath(item.path)
                guard !item.path.contains("\\"), !item.path.contains("\0"), !item.path.split(separator: "/").contains(".git") else { throw AppError(text: "远端包含不安全路径") }
                guard let size = item.size, size <= 100 * 1024 * 1024 else { throw AppError(text: item.path + " 超过下载单文件 100 MiB 限制或缺少大小") }
                total += size
                guard total <= 1024 * 1024 * 1024 else { throw AppError(text: item.path + " 导致下载总量超过 1 GiB") }
                let free = (try FileManager.default.attributesOfFileSystem(forPath: stage.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                guard free > Int64(size) * 3 + 64 * 1024 * 1024 else { throw AppError(text: "磁盘空间不足：" + item.path) }
                let target = stage.appendingPathComponent(item.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Immutable Git blob endpoint: no per-byte AsyncBytes loop or contents redirect.
                var r = try request(url(endpoint + "/git/blobs/" + Self.component(item.sha)))
                r.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
                r.timeoutInterval = 180
                let tmp = try await downloadBlob(r, path: item.path)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let expectedSHA256 = try await Task.detached(priority: .userInitiated) {
                    let handle = try FileHandle(forReadingFrom: tmp)
                    defer { try? handle.close() }
                    var hash = StreamingBlobHash(size: size)
                    while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty { try hash.update(chunk) }
                    return try hash.finish(expectedGit: item.sha)
                }.value
                try FileManager.default.moveItem(at: tmp, to: target)
                guard try LocalStore.snapshotFileSHA256(target) == expectedSHA256 else { throw AppError(text: "磁盘 SHA256 校验失败：" + item.path) }
            }
            let snapshot = try LocalStore.snapshot(stage)
            let binding = WorkspaceBinding(repo: repo, branch: branch, head: head, tree: commit.tree.sha, modes: Dictionary(uniqueKeysWithValues: tree.tree.filter { $0.type == "blob" }.map { ($0.path, $0.mode) }), snapshot: snapshot, remoteAuthorDate: commit.author?.date, remoteCommitterDate: commit.committer?.date, lastChecked: Date())
            return (binding, stage)
        } catch { try? FileManager.default.removeItem(at: stage); throw error }
    }
    func downloadWorkspace(repo: String, branch: String) async throws -> URL {
        let (binding, stage) = try await fetchWorkspace(repo, branch: branch)
        defer { try? FileManager.default.removeItem(at: stage) }
        let folder = try LocalStore.importFolder(stage, name: binding.repo.replacingOccurrences(of: "/", with: "-") + "-" + binding.branch + "-" + (binding.remoteCommitterDate.map { ISO8601DateFormatter().string(from: $0) } ?? String(binding.head.prefix(8))))
        var downloadedBinding = binding
        downloadedBinding.lastPulled = Date()
        do { try LocalStore.saveBinding(downloadedBinding, folder: folder) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return folder
    }
    func preparePull(_ folder: URL, binding: WorkspaceBinding) async throws -> WorkspacePull {
        let local = try LocalStore.snapshot(folder)
        let (remote, stage) = try await fetchWorkspace(binding.repo, branch: binding.branch)
        return WorkspacePull(binding: remote, local: local, remoteFolder: stage, conflicts: WorkspaceMerge.conflicts(base: binding.snapshot, local: local, remote: remote.snapshot))
    }
    func workspaceHead(_ repo: String, branch: String) async throws -> String {
        try await decoded(GitReference.self, Self.repoPath(repo) + "/git/ref/heads/" + Self.filePath(branch)).object.sha
    }
    func associateWorkspace(_ folder: URL, repo: String, branch: String, revision: String = "") async throws -> WorkspaceBinding {
        let repo = try RepositoryInput.parse(repo)
        let branch = try await resolvedBranch(repo, branch: branch.trimmingCharacters(in: .whitespacesAndNewlines))
        let selected = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        let head: String
        if selected.isEmpty { head = try await workspaceHead(repo, branch: branch) }
        else {
            guard WorkspaceBaselineRules.validRevision(selected) else { throw AppError(text: "历史提交请输入 ZIP 对应的 7–40 位十六进制 commit SHA，不要输入分支名") }
            let commit = try await decoded(GitCommitInfo.self, Self.repoPath(repo) + "/commits/" + Self.component(selected))
            head = commit.sha
            let comparison = try await decoded(WorkspaceComparison.self, Self.repoPath(repo) + "/compare/" + Self.component(head) + "..." + Self.component(branch))
            guard ["ahead", "identical"].contains(comparison.status) else { throw AppError(text: "选择的历史提交不是目标分支的祖先，请确认 ZIP 来源和分支") }
        }
        // Never promote edited local bytes to a trusted remote baseline.
        let original = try JSONDecoder().decode(LocalSnapshot.self, from: Data(contentsOf: LocalStore.metadata(folder)))
        let (verified, stage) = try await fetchWorkspace(repo, branch: branch, revision: head)
        defer { try? FileManager.default.removeItem(at: stage) }
        guard WorkspaceBaselineRules.matches(original: original, verified: verified.snapshot) else {
            throw AppError(text: "原始导入副本与选定远端提交不匹配，关联未建立。请填写 ZIP 对应历史 commit（例如文件名中的 9230587），或重新导入未编辑的原始 ZIP；原始 ZIP 若含额外文件也需核实。当前编辑副本不会被覆盖。也可另建远端工作区。")
        }
        // Persist the verified REMOTE snapshot, retaining every current edit/deletion.
        try ensureActiveAccount()
        try LocalStore.saveBinding(verified, folder: folder)
        return verified
    }
    private func downloadBlob(_ request: URLRequest, path: String) async throws -> URL {
        for attempt in 0..<3 {
            do {
                let (tmp, response) = try await session.download(for: request)
                do {
                    try ensureActiveAccount()
                    let body = (response as? HTTPURLResponse)?.statusCode == 200 ? Data() : ((try? Data(contentsOf: tmp, options: .mappedIfSafe)) ?? Data())
                    // Only read API error text; successful binary remains untouched on disk.
                    try check((response as? HTTPURLResponse)?.statusCode == 200 ? Data() : Data(body.prefix(8192)), response, operation: "下载 " + path)
                    return tmp
                } catch { try? FileManager.default.removeItem(at: tmp); throw error }
            } catch {
                let e = error as NSError
                guard attempt < 2, WorkspaceBaselineRules.retryable(domain: e.domain, code: e.code) else {
                    throw AppError(text: path + "：" + error.localizedDescription + "。下载未完成，不会建立基线；请检查网络后手动重试。")
                }
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
                try ensureActiveAccount()
            }
        }
        throw AppError(text: "下载失败：" + path)
    }
    func commitWorkspace(_ binding: WorkspaceBinding, writes: [WorkspaceWrite], message: String) async throws -> WorkspaceBinding {
        guard !writes.isEmpty, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError(text: "请选择变更并填写提交说明") }
        let endpoint = try Self.repoPath(binding.repo)
        guard try await workspaceHead(binding.repo, branch: binding.branch) == binding.head else { throw AppError(text: "远端分支已变化，拒绝提交。请先手动拉取更新；不会强制覆盖。") }
        var entries: [[String: Any]] = []
        var updated = binding
        for write in writes {
            _ = try Self.filePath(write.path)
            let mode = binding.modes[write.path] ?? "100644"
            if let bytes = write.bytes {
                guard bytes.count <= 10 * 1024 * 1024 else { throw AppError(text: "文件超过 10 MiB，请使用 Release") }
                let blob = try await decoded(GitObject.self, endpoint + "/git/blobs", method: "POST", object: ["content": bytes.base64EncodedString(), "encoding": "base64"])
                entries += RepoQueue.treeEntries([(write.path, blob.sha, mode)])
                updated.modes[write.path] = mode
            } else {
                entries += RepoQueue.treeEntries([(write.path, nil, mode)])
                updated.modes[write.path] = nil
            }
        }
        let tree = try await decoded(GitObject.self, endpoint + "/git/trees", method: "POST", object: ["base_tree": binding.tree, "tree": entries])
        let commit = try await decoded(GitObject.self, endpoint + "/git/commits", method: "POST", object: ["message": message, "tree": tree.sha, "parents": [binding.head]])
        guard try await workspaceHead(binding.repo, branch: binding.branch) == binding.head else { throw AppError(text: "提交准备期间远端已变化，拒绝更新分支") }
        // A concurrent update after this check is rejected by GitHub's non-fast-forward check.
        _ = try await data(endpoint + "/git/refs/heads/" + Self.filePath(binding.branch), method: "PATCH", object: ["sha": commit.sha, "force": false])
        updated.head = commit.sha; updated.tree = tree.sha
        return updated
    }
    func commitQueue(repo: String, branch: String, items: [PendingRepoItem], message: String) async throws {
        let repo = try RepositoryInput.parse(repo)
        let branch = try await resolvedBranch(repo, branch: branch)
        let endpoint = try Self.repoPath(repo)
        let head = try await workspaceHead(repo, branch: branch)
        let commit = try await decoded(GitCommitInfo.self, endpoint + "/git/commits/" + Self.component(head))
        let tree = try await decoded(GitTreeInfo.self, endpoint + "/git/trees/" + Self.component(commit.tree.sha), query: [.init(name: "recursive", value: "1")])
        guard !tree.truncated, tree.tree.count <= 20000, tree.tree.allSatisfy({ $0.type == "tree" || ($0.type == "blob" && ["100644", "100755"].contains($0.mode)) }) else { throw AppError(text: "不安全或截断的远端树") }
        let files = Dictionary(uniqueKeysWithValues: tree.tree.filter { $0.type == "blob" }.map { ($0.path, $0.sha) })
        try RepoQueue.validate(items, head: head, files: files, directories: Set(tree.tree.filter { $0.type == "tree" }.map(\.path)))
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError(text: "请填写提交说明") }
        guard try await workspaceHead(repo, branch: branch) == head else { throw AppError(text: "远端分支已变化，请重新加载后再提交。") }
        var entries: [[String: Any]] = []
        var totalBytes: Int64 = 0
        let modes = Dictionary(uniqueKeysWithValues: tree.tree.filter { $0.type == "blob" }.map { ($0.path, $0.mode) })
        for item in items {
            guard let path = item.path else { throw AppError(text: "请选择每项的仓库目标。") }
            _ = try Self.filePath(path)
            let mode = modes[path] ?? "100644"
            if let file = item.local {
                let prepared = try await Task.detached(priority: .utility) { try DebControlEditor.prepareForUpload(file) }.value
                defer { if prepared.file != file { try? FileManager.default.removeItem(at: prepared.file.deletingLastPathComponent()) } }
                if let notice = prepared.notice { self.message = notice }
                let size = (try FileManager.default.attributesOfItem(atPath: prepared.file.path)[.size] as? NSNumber)?.int64Value ?? Int64.max
                guard size >= 0, size <= RepoQueue.maximumFileBytes else { throw AppError(text: path + " 超过上传 10 MiB，请使用 Release") }
                guard totalBytes <= RepoQueue.maximumTotalUploadBytes - size else { throw AppError(text: "普通提交总大小不能超过 50 MiB，请使用 Release") }
                totalBytes += size
                let blob = try await uploadGitBlobFile(prepared.file, path: endpoint + "/git/blobs", maximumBytes: RepoQueue.maximumFileBytes, expectedSize: size)
                entries += RepoQueue.treeEntries([(path, blob.sha, mode)])
            } else {
                entries += RepoQueue.treeEntries([(path, nil, mode)])
            }
        }
        let newTree = try await decoded(GitObject.self, endpoint + "/git/trees", method: "POST", object: ["base_tree": commit.tree.sha, "tree": entries])
        let newCommit = try await decoded(GitCommitInfo.self, endpoint + "/git/commits", method: "POST", object: ["message": message, "tree": newTree.sha, "parents": [head]])
        guard try await workspaceHead(repo, branch: branch) == head else { throw AppError(text: "提交准备期间远端已变化，拒绝更新分支") }
        _ = try await data(endpoint + "/git/refs/heads/" + Self.filePath(branch), method: "PATCH", object: ["sha": newCommit.sha, "force": false])
    }
    func identify() async throws {
        let r = try request(url("/user"))
        let (bytes, response) = try await session.data(for: r, delegate: OfficialUpdateRedirectPolicy())
        try check(bytes, response)
        let user = try JSONDecoder().decode(User.self, from: bytes)
        try ensureActiveAccount()
        login = user.login; avatarURL = user.avatar_url; profile = user
        if let scopes = GitHubAccount.grantedScopes((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-OAuth-Scopes")) {
            AccountStore.updateAuthorization(accountID, scopes: scopes)
        }
        if accountID == "legacy", let id = user.id {
            let account = GitHubAccount(id: String(id), login: user.login, avatarURL: user.avatar_url)
            try CredentialStore.save(CredentialStore.read(account: "legacy"), account: account.id)
            try AccountStore.record(account)
            CredentialStore.clear(account: "legacy")
            AccountStore.activate(account.id)
        }
    }
    var oauthScopes: [String]? { AccountStore.accounts.first { $0.id == accountID }?.oauthScopes }
    func recordProfileWriteAuthorization(_ allowed: Bool) {
        guard isCurrentSession else { return }
        AccountStore.updateAuthorization(accountID, scopes: oauthScopes, profileWriteAccess: allowed)
        profileWriteAuthorization = allowed
    }
    func addAccount(token: String, expectedAccountID: String? = nil, grantedScopes: String? = nil) async throws {
        try ensureActiveAccount()
        // Validate before replacing any existing credential. No secrets enter metadata or logs.
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer " + token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.data(for: request, delegate: OfficialUpdateRedirectPolicy())
        try check(bytes, response, operation: "验证账号")
        guard (response as? HTTPURLResponse)?.statusCode == 200, bytes.count <= 1024 * 1024 else { throw AppError(text: "GitHub 未确认账号验证成功。") }
        let user = try JSONDecoder().decode(User.self, from: bytes)
        try ensureActiveAccount()
        guard let id = user.id else { throw AppError(text: "GitHub 未返回账号标识") }
        guard expectedAccountID == nil || expectedAccountID == String(id) else {
            throw AppError(text: "浏览器授权的账号与当前账号不同，请在 GitHub 切换到当前账号后重试。原账号凭据未修改。")
        }
        let scopes = GitHubAccount.grantedScopes((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? grantedScopes)
        if expectedAccountID != nil, let scopes, !scopes.contains("user") {
            throw AppError(text: "GitHub 未授予社交账号管理所需的 user 权限，原账号凭据未修改。")
        }
        let account = GitHubAccount(id: String(id), login: user.login, avatarURL: user.avatar_url, oauthScopes: scopes)
        try Task.checkCancellation()
        try CredentialStore.save(token, account: account.id)
        try AccountStore.record(account)
        AccountStore.activate(account.id)
        let detail = account.profileWriteAuthorization == true ? "社交账号管理权限已确认。" : ""
        NotificationCenter.default.post(name: .githubAuthorizationCompleted, object: nil,
            userInfo: ["account": account.id, "message": "授权成功，账号 @\(account.login) 已保存。" + detail])
    }
    func repositories() async throws -> [Repository] {
        var result: [Repository] = []
        for page in 1...50 {
            let batch = try await decoded([Repository].self, "/user/repos", query: [
                .init(name: "per_page", value: "100"), .init(name: "page", value: String(page)), .init(name: "sort", value: "pushed")])
            result += batch
            if batch.count < 100 { return result }
            if page == 50 { throw AppError(text: "列表加载未完成：超过分页上限，请缩小范围或重试。") }
        }
        return result
    }
    func starredRepositories() async throws -> [Repository] {
        var result: [Repository] = []
        for page in 1...50 {
            let batch = try await decoded([Repository].self, "/user/starred", query: [
                .init(name: "per_page", value: "100"), .init(name: "page", value: String(page)),
                .init(name: "sort", value: "created"), .init(name: "direction", value: "desc")])
            result += batch
            if batch.count < 100 { return result }
            if page == 50 { throw AppError(text: "列表加载未完成：超过分页上限，请缩小范围或重试。") }
        }
        return result
    }
    func searchRepositories(_ query: String, page: Int, options: RepositorySearchOptions = .init()) async throws -> RepositorySearchResponse {
        let endpoint = RepositorySearchRules.endpoint(kind: .repositories, query: query, page: page, options: options)
        let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        return try await decoded(RepositorySearchResponse.self, endpoint.path, query: parts.queryItems ?? [])
    }
    // Read-only gateway reuses the existing account checks, credential host guard
    // and redirect policy. Community modules cannot bypass repository write guards.
    func communityRead(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        let bytes = try await data(path, query: query)
        try Task.checkCancellation()
        guard bytes.count <= 8 * 1024 * 1024 else { throw AppError(text: "响应过大，请在 GitHub 查看。") }
        return bytes
    }
    func communityReadmeHTML(_ repo: String, branch: String) async throws -> String {
        try ensureActiveAccount(); try Task.checkCancellation()
        var r = try request(url(Self.repoPath(repo) + "/readme", query: [.init(name: "ref", value: branch)]))
        r.setValue("application/vnd.github.html+json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.data(for: r, delegate: GitHubAPIRedirectPolicy())
        try check(bytes, response); try Task.checkCancellation()
        return try ReadmeDocumentRules.renderedHTML(bytes)
    }
    // Native collaboration transport: allowed routes and bodies are constructed
    // by CommunityMutationRules, never from a user-supplied API path.
    func communityMutate(_ repo: String, action: CommunityMutation, title: String = "", text: String = "") async throws -> Data {
        try ensureActiveAccount(); try Task.checkCancellation()
        let change = try CommunityMutationRules.request(action, title: title, text: text)
        let path = try Self.repoPath(repo) + change.suffix
        if change.requiresPush { try await requireWriteAccess(repo) }
        if case .deleteRun = action {
            struct RunStatus: Decodable { let status: String }
            let current = try JSONDecoder().decode(RunStatus.self, from: await communityRead(path))
            guard current.status == "completed" else { throw AppError(text: "此运行尚未结束，请先取消，待结束后再删除。") }
        }
        try ensureActiveAccount(); try Task.checkCancellation()
        let body = try JSONSerialization.data(withJSONObject: change.body)
        var r = try request(url(path), method: change.method, body: body)
        if case .deleteRun = action { r.httpBody = nil }
        let response = try await session.data(for: r, delegate: OfficialUpdateRedirectPolicy())
        try check(response.0, response.1, operation: "仓库协作操作")
        if case .deleteRun = action, (response.1 as? HTTPURLResponse)?.statusCode != 204 {
            throw AppError(text: "未收到删除成功确认，请刷新运行列表核实，避免重复操作。")
        }
        try Task.checkCancellation()
        return response.0
    }
    func communityStarDates(_ repo: String, page: Int) async throws -> [StarTimestamp] {
        guard page > 0 else { throw AppError(text: "无效页码") }
        var r = try request(url(Self.repoPath(repo) + "/stargazers", query: [.init(name: "page", value: String(page)), .init(name: "per_page", value: "100")]))
        r.setValue("application/vnd.github.star+json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.data(for: r, delegate: OfficialUpdateRedirectPolicy())
        try check(bytes, response); try Task.checkCancellation()
        guard bytes.count < 8 * 1024 * 1024 else { throw AppError(text: "Star 数据过大") }
        return try JSONDecoder().decode([StarTimestamp].self, from: bytes)
    }
    func communityRunStepLogs(_ repo: String, run: Int, attempt: Int, job: String, steps: Set<Int>) async throws -> WorkflowStepLogs {
        guard run > 0, attempt > 0 else { throw AppError(text: "无效运行编号或运行次数") }
        let policy = WorkflowLogArchiveDownloadPolicy()
        let file: URL
        do {
            file = try await download(request(url(Self.repoPath(repo) + "/actions/runs/\(run)/attempts/\(attempt)/logs")), name: "workflow-logs.zip", redirect: policy)
        } catch {
            if policy.exceededBudget { throw AppError(text: "日志归档超过 32 MiB，已停止下载。") }
            if (error as? GitHubAPIError)?.status == 404 { throw AppError(text: "GitHub 尚未提供此运行的日志归档，或日志已过期。运行完成后可刷新重试。") }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let worker = Task.detached(priority: .utility) { try WorkflowLogArchiveRules.read(file, job: job, steps: steps) }
        let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation(); try ensureActiveAccount()
        return result
    }
    func communityJobLog(_ repo: String, id: Int) async throws -> String {
        guard id > 0 else { throw AppError(text: "无效任务编号") }
        let r = try request(url(Self.repoPath(repo) + "/actions/jobs/\(id)/logs"))
        let (stream, response) = try await session.bytes(for: r, delegate: WorkflowLogRedirectPolicy())
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError(text: "日志尚未就绪、已过期或缺少 Actions 读取权限。") }
        var bytes = Data(); let limit = 256 * 1024
        for try await byte in stream {
            try Task.checkCancellation()
            if bytes.count == limit { try ensureActiveAccount(); return String(decoding: bytes, as: UTF8.self) + "\n…日志预览已达256 KiB上限。" }
            bytes.append(byte)
        }
        try ensureActiveAccount()
        return String(decoding: bytes, as: UTF8.self)
    }
    func communityArtifact(_ repo: String, id: Int, name: String) async throws -> URL {
        guard id > 0 else { throw AppError(text: "无效构建产物编号") }
        return try await download(request(url(Self.repoPath(repo) + "/actions/artifacts/\(id)/zip")), name: DownloadRules.safeName(name) + ".zip", redirect: WorkflowLogRedirectPolicy())
    }
    func searchUsers(_ query: String, page: Int) async throws -> UserSearchResponse {
        let endpoint = RepositorySearchRules.endpoint(kind: .users, query: query, page: page)
        let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        return try await decoded(UserSearchResponse.self, endpoint.path, query: parts.queryItems ?? [])
    }
    func userRepositories(_ login: String, page: Int) async throws -> [Repository] {
        try await decoded([Repository].self, "/users/" + Self.component(login) + "/repos", query: [
            .init(name: "per_page", value: "100"), .init(name: "page", value: String(page)), .init(name: "sort", value: "updated")])
    }
    func repository(_ repo: String) async throws -> Repository {
        try await decoded(Repository.self, Self.repoPath(repo))
    }
    func inspectAccess(_ repo: String) async throws -> String {
        try await identify()
        let info = try await decoded(RepoAccess.self, Self.repoPath(repo))
        _ = try await contents(repo, path: "")
        if info.permissions?.push == nil {
            return "权限未知：无法确认推送权限；上传、编辑及删除入口保持关闭。"
        }
        if info.permissions?.push == false {
            return "账号：\(login)\n仓库：\(info.full_name)\n可读取，但账号没有推送权限。"
        }
        return "账号：\(login)\n仓库：\(info.full_name)\n读取正常。提交还需要 Token 对此仓库有 Contents 读写权限；此检查不写入文件，不能保证提交成功。"
    }
    func resolvedBranch(_ repo: String, branch: String) async throws -> String {
        if !branch.isEmpty { return branch }
        let repository = try await decoded(Repository.self, Self.repoPath(repo))
        guard let name = repository.default_branch, !name.isEmpty else { throw AppError(text: "仓库没有默认分支") }
        return name
    }
    func contents(_ repo: String, path: String, branch: String = "") async throws -> [Entry] {
        let endpoint = try Self.repoPath(repo) + "/contents" + (path.isEmpty ? "" : "/" + Self.filePath(path))
        return try await decoded([Entry].self, endpoint, query: branch.isEmpty ? [] : [.init(name: "ref", value: branch)])
    }
    func file(_ repo: String, path: String, branch: String = "") async throws -> Entry {
        let endpoint = try Self.repoPath(repo) + "/contents/" + Self.filePath(path)
        return try await decoded(Entry.self, endpoint, query: branch.isEmpty ? [] : [.init(name: "ref", value: branch)])
    }
    func commit(_ repo: String, path: String, bytes: Data, sha: String?, message: String, branch: String) async throws {
        guard bytes.count <= 10 * 1024 * 1024 else { throw AppError(text: "本版普通提交限制为 10 MiB。大文件请使用“新建仓库并发布”。") }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError(text: "请填写提交说明") }
        var o: [String: Any] = ["message": message, "content": bytes.base64EncodedString()]
        if let sha = sha { o["sha"] = sha }
        if !branch.isEmpty { o["branch"] = branch }
        _ = try await data(Self.repoPath(repo) + "/contents/" + Self.filePath(path), method: "PUT", object: o)
    }
    func delete(_ repo: String, entry: Entry, message: String, branch: String) async throws {
        var o: [String: Any] = ["message": message, "sha": entry.sha]
        if !branch.isEmpty { o["branch"] = branch }
        _ = try await data(Self.repoPath(repo) + "/contents/" + Self.filePath(entry.path), method: "DELETE", object: o)
    }
    // Fork status is read only, on demand, and scoped to this account generation.
    func existingFork(_ input: String, forceRefresh: Bool = false) async throws -> String? {
        try requireStarSession()
        let name = try RepositoryInput.parse(input), key = name.lowercased()
        guard !RepositoryGroupRules.isOwned(name, login: login), !login.isEmpty else { return nil }
        if forceRefresh { forkCheckedAt[key] = nil; forkNames[key] = nil }
        if let date = forkCheckedAt[key] {
            if Date().timeIntervalSince(date) < 300 { return forkNames[key] }
            forkNames[key] = nil
            forkCheckedAt[key] = nil
        }
        let task: Task<String?, Error>, requestID: UUID
        if !forceRefresh, let pending = forkChecks[key], let pendingID = forkCheckIDs[key] {
            task = pending; requestID = pendingID
        } else {
            task = Task<String?, Error> { try await self.findExistingFork(name, fresh: forceRefresh) }
            requestID = UUID()
            forkChecks[key] = task; forkCheckIDs[key] = requestID
        }
        let result: String?
        do { result = try await task.value }
        catch {
            if forkCheckIDs[key] == requestID {
                forkChecks[key] = nil; forkCheckIDs[key] = nil
            }
            throw error
        }
        // A cancelled waiter leaves the shared task available for another waiter.
        try Task.checkCancellation()
        try requireStarSession()
        guard forkCheckIDs[key] == requestID else {
            // Another waiter or a newer lookup may already have published. Never
            // publish a result superseded by a forced confirmation lookup.
            if let date = forkCheckedAt[key], Date().timeIntervalSince(date) < 300 {
                return forkNames[key]
            }
            throw CancellationError()
        }
        forkChecks[key] = nil; forkCheckIDs[key] = nil
        // A concurrent successful POST takes precedence over an earlier empty lookup.
        if let date = forkCheckedAt[key], Date().timeIntervalSince(date) < 300,
           let positive = forkNames[key] { return positive }
        forkNames[key] = result
        forkCheckedAt[key] = Date()
        return result
    }
    private func findExistingFork(_ name: String, fresh: Bool) async throws -> String? {
        let upstream = try await repository(name)
        let candidates = fresh ? [] : (collectionCache[.owned] ?? [])
        if let found = candidates.first(where: { RepositoryForkRules.matches($0, upstream: upstream, login: login) }) {
            return found.full_name
        }
        let candidateName = login + "/" + (name.split(separator: "/").last.map(String.init) ?? "")
        var inspected: [String: Repository] = [:]
        do {
            let candidate = try await repository(candidateName)
            inspected[candidate.full_name.lowercased()] = candidate
            if RepositoryForkRules.matches(candidate, upstream: upstream, login: login) { return candidate.full_name }
        } catch let error as GitHubAPIError where error.status == 404 {
            // A renamed fork cannot be found by its original repository name.
        }
        // Server-side viewer ownership filter avoids enumerating popular fork networks.
        // Query both the immediate upstream and its network root for renamed forks.
        let root = upstream.source?.full_name ?? upstream.full_name
        let parts = root.split(separator: "/").map(String.init)
        let target = upstream.full_name.split(separator: "/").map(String.init)
        guard parts.count == 2, target.count == 2 else { throw AppError(text: "无法确认复刻状态") }
        let query = """
        query($owner: String!, $name: String!, $targetOwner: String!, $targetName: String!) {
          root: repository(owner: $owner, name: $name) { forkCount direct: forks(first: 1) { totalCount } forks(first: 1, affiliations: [OWNER]) { nodes { nameWithOwner } } }
          target: repository(owner: $targetOwner, name: $targetName) { forks(first: 1, affiliations: [OWNER]) { nodes { nameWithOwner } } }
        }
        """
        let response = try await decoded(RepositoryForkLookup.self, "/graphql", method: "POST", object: [
            "query": query, "variables": ["owner": parts[0], "name": parts[1], "targetOwner": target[0], "targetName": target[1]]])
        guard response.errors?.isEmpty != false, let data = response.data,
              let rootResult = data.root, let targetResult = data.target else {
            throw AppError(text: "无法确认复刻状态，请重试。")
        }
        for node in targetResult.forks.nodes + rootResult.forks.nodes {
            let candidate = try await repository(node.nameWithOwner)
            inspected[candidate.full_name.lowercased()] = candidate
            if RepositoryForkRules.matches(candidate, upstream: upstream, login: login) { return candidate.full_name }
        }
        // forks(affiliations: OWNER) only searches direct forks. An empty result
        // is conclusive only when the root's whole network contains no indirect
        // forks; otherwise my renamed fork may be below another owner's fork.
        if let networkCount = rootResult.forkCount,
           let directCount = rootResult.direct?.totalCount, networkCount == directCount { return nil }
        // Enumerate only this account's repositories, never a popular upstream's
        // entire fork network. A full page at the budget boundary remains unknown.
        var detailCount = 0
        for page in 1...3 {
            let owned = try await decoded([Repository].self,
                "/user/repos?affiliation=owner&per_page=100&sort=full_name&direction=asc&page=\(page)")
            try ensureActiveAccount()
            for item in owned {
                guard let isFork = item.fork else { throw AppError(text: "复刻状态资料不完整，请重试。") }
                if !isFork { continue }
                guard RepositoryGroupRules.isOwned(item.full_name, login: login) else {
                    throw AppError(text: "无法完整确认复刻状态，请重试。")
                }
                let key = item.full_name.lowercased()
                let cached = candidates.first { $0.full_name.lowercased() == key }
                if RepositoryForkRules.matches(item, upstream: upstream, login: login) { return item.full_name }
                if let cached, RepositoryForkRules.matches(cached, upstream: upstream, login: login) { return cached.full_name }
                let candidate: Repository
                if let known = inspected[key] { candidate = known }
                else if let cached, cached.source != nil { candidate = cached }
                else if item.source != nil { candidate = item }
                else {
                    guard detailCount < 20 else { throw AppError(text: "复刻状态查询达到限额，请稍后重试。") }
                    detailCount += 1
                    candidate = try await repository(item.full_name)
                    try ensureActiveAccount()
                    inspected[key] = candidate
                }
                if RepositoryForkRules.matches(candidate, upstream: upstream, login: login) { return candidate.full_name }
                guard candidate.fork == false || candidate.source != nil else {
                    throw AppError(text: "复刻状态资料不完整，请重试。")
                }
            }
            if owned.count < 100 { return nil }
        }
        throw AppError(text: "复刻状态查询达到限额，请稍后重试。")
    }

    func fork(_ repo: String) async throws -> Repository {
        let endpoint = try Self.repoPath(repo)
        // Revalidate identity using the current credential, not cached UI state.
        try await identify()
        let owner = try RepositoryInput.parse(repo).split(separator: "/").first.map(String.init) ?? ""
        guard owner.caseInsensitiveCompare(login) != .orderedSame else {
            throw AppError(text: "这是你自己的仓库（\(login)）。GitHub 不允许把自己的仓库 Fork 回同一个账号。\n\n更新文件请点“浏览这个仓库”或“提交 / 发布”。如果要另外复制一份，需要新建不同名字的仓库再复制内容；这不属于 Fork，本版尚未提供完整仓库复制。")
        }
        guard try await existingFork(repo) == nil else { throw AppError(text: "此仓库已复刻。") }
        try ensureActiveAccount()
        let result = try await decoded(Repository.self, endpoint + "/forks", method: "POST", object: [:])
        try ensureActiveAccount()
        // The accepted POST itself confirms this relationship, even before metadata is ready.
        if RepositoryGroupRules.isOwned(result.full_name, login: login) {
            let key = (try RepositoryInput.parse(repo)).lowercased()
            forkNames[key] = result.full_name
            forkCheckedAt[key] = Date()
        }
        return result
    }
    func createRepository(name: String, isPrivate: Bool) async throws -> Repository {
        guard !name.isEmpty, name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              name != ".", name != ".." else { throw AppError(text: "仓库名只允许英文字母、数字、点、横线和下划线") }
        return try await decoded(Repository.self, "/user/repos", method: "POST", object: [
            "name": name, "private": isPrivate, "auto_init": true, "description": "Created with RepoPocket"])
    }
    func releases(_ repo: String) async throws -> [Release] {
        try await decoded([Release].self, Self.repoPath(repo) + "/releases", query: [.init(name: "per_page", value: "100")])
    }
    func createRelease(_ repo: String, tag: String, title: String) async throws -> Release {
        guard !tag.isEmpty, !tag.contains(" ") else { throw AppError(text: "请填写不含空格的版本标签，例如 v1.0") }
        return try await decoded(Release.self, Self.repoPath(repo) + "/releases", method: "POST", object: [
            "tag_name": tag, "name": title.isEmpty ? tag : title, "draft": true, "body": "Uploaded with RepoPocket"])
    }
    func upload(_ release: Release, file: URL, progress: @escaping (Double) -> Void) async throws -> Asset {
        let prepared = try DebControlEditor.prepareForUpload(file)
        defer { if prepared.file != file { try? FileManager.default.removeItem(at: prepared.file.deletingLastPathComponent()) } }
        if let notice = prepared.notice { message = notice }
        let file = prepared.file
        let endpoint = release.upload_url.components(separatedBy: "{")[0]
        guard var c = URLComponents(string: endpoint) else { throw AppError(text: "无效上传地址") }
        c.queryItems = [.init(name: "name", value: file.lastPathComponent)]
        guard let u = c.url else { throw AppError(text: "无效附件名") }
        let parts = u.path.split(separator: "/")
        guard u.scheme == "https", u.host == "uploads.github.com", parts.count == 6,
              parts[0] == "repos", parts[3] == "releases", parts[5] == "assets",
              let owner = String(parts[1]).removingPercentEncoding,
              let name = String(parts[2]).removingPercentEncoding else { throw AppError(text: "无效 Release 上传目标") }
        try await requireWriteAccess(owner + "/" + name)
        let r = try request(u, method: "POST", binary: true)
        let delegate = TransferProgress(update: progress)
        let (d, response) = try await session.upload(for: r, fromFile: file, delegate: delegate)
        try check(d, response)
        return try JSONDecoder().decode(Asset.self, from: d)
    }
    func publish(_ repo: String, release: Release) async throws -> Release {
        try await decoded(Release.self, Self.repoPath(repo) + "/releases/\(release.id)", method: "PATCH", object: ["draft": false])
    }
    func trollPublish(repo: String, branch: String, file: URL, pluginName: String, version: String = "1.0", description: String? = nil, bundleID: String? = nil, author: String? = nil) async throws -> TrollPublishResult {
        let repo = try RepositoryInput.parse(repo)
        let name = pluginName.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = file.lastPathComponent
        guard filename.lowercased().hasSuffix(".dylib"), !filename.contains("/") else { throw AppError(text: "请选择 .dylib 文件") }
        guard !name.isEmpty else { throw AppError(text: "请填写插件名字") }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let fileSize = attributes[.size] as? NSNumber else { throw AppError(text: "请选择有效的 dylib 文件") }
        let size = fileSize.int64Value
        guard size > 0 else { throw AppError(text: "dylib 不能为空") }
        guard size <= RepoQueue.maximumTrollPluginBytes else { throw AppError(text: "TrollFools 插件不能超过 20 MiB") }
        let resolved = try await resolvedBranch(repo, branch: branch)
        let endpoint = try Self.repoPath(repo)
        let head = try await workspaceHead(repo, branch: resolved)
        let commit = try await decoded(GitCommitInfo.self, endpoint + "/git/commits/" + Self.component(head))
        let tree = try await decoded(GitTreeInfo.self, endpoint + "/git/trees/" + Self.component(commit.tree.sha), query: [.init(name: "recursive", value: "1")])
        let dylibPath = "downloads/" + filename
        let indexPath = "trollpackages.json"
        let existing = tree.tree.first { $0.type == "blob" && $0.path == indexPath }
        var index: [String: Any] = ["repository_name": repo, "packages": []]
        if let e = existing {
            let raw = try await decoded(WorkspaceBlob.self, endpoint + "/git/blobs/" + Self.component(e.sha))
            guard raw.encoding == "base64", let d = Data(base64Encoded: raw.content, options: .ignoreUnknownCharacters), let object = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw AppError(text: "trollpackages.json 格式无效，未提交") }
            index = object
        }
        guard var packages = index["packages"] as? [[String: Any]] else { throw AppError(text: "trollpackages.json 缺少 packages 数组，未提交") }
        index["repository_name"] = index["repository_name"] as? String ?? repo
        let ownerRepo = repo.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard ownerRepo.count == 2 else { throw AppError(text: "仓库格式应为：用户名/仓库名") }
        let pagesBase = "https://\(Self.component(ownerRepo[0])).github.io/\(Self.component(ownerRepo[1]))/downloads/"
        let dylibURL = pagesBase + Self.component(filename)
        let normalizedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedVersion.isEmpty else { throw AppError(text: "请填写版本") }
        var package: [String: Any] = ["name": name, "version": normalizedVersion, "description": (description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? description! : name), "dylib": dylibURL, "section": "插件", "size": Self.trollSize(Int(size))]
        if let bundleID, !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { package["bundle"] = bundleID }
        if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { package["author"] = author }
        // Match by URL path, not host or string formatting, preserving other metadata and links.
        let targetURLPath = URLComponents(string: dylibURL)?.percentEncodedPath
        if let i = packages.firstIndex(where: { value in
            guard let url = value["dylib"] as? String, let parsed = URL(string: url) else { return false }
            return URLComponents(url: parsed, resolvingAgainstBaseURL: false)?.percentEncodedPath == targetURLPath && parsed.host?.caseInsensitiveCompare(ownerRepo[0] + ".github.io") == .orderedSame
        }) {
            package["section"] = packages[i]["section"] ?? "插件"
            for (key, value) in package { packages[i][key] = value }
        } else { packages.append(package) }
        index["packages"] = packages
        let json = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
        let dylibBlob = try await uploadGitBlobFile(file, path: endpoint + "/git/blobs", maximumBytes: RepoQueue.maximumTrollPluginBytes, expectedSize: size)
        let indexBlob = try await decoded(GitObject.self, endpoint + "/git/blobs", method: "POST", object: ["content": json.base64EncodedString(), "encoding": "base64"])
        let newTree = try await decoded(GitObject.self, endpoint + "/git/trees", method: "POST", object: ["base_tree": commit.tree.sha, "tree": [["path": dylibPath, "mode": "100644", "type": "blob", "sha": dylibBlob.sha], ["path": indexPath, "mode": "100644", "type": "blob", "sha": indexBlob.sha]]])
        let newCommit = try await decoded(GitCommitInfo.self, endpoint + "/git/commits", method: "POST", object: ["message": "Publish TrollFools plugin: \(name)", "tree": newTree.sha, "parents": [head]])
        guard try await workspaceHead(repo, branch: resolved) == head else { throw AppError(text: "远端分支已变化，未提交任何文件，请重试") }
        _ = try await data(endpoint + "/git/refs/heads/" + Self.filePath(resolved), method: "PATCH", object: ["sha": newCommit.sha, "force": false])
        return TrollPublishResult(commitSHA: newCommit.sha, path: dylibPath)
    }
    func metadataSnapshot(repo: String, branch: String, entry: Entry) async throws -> TrollMetadataSnapshot {
        let repo = try RepositoryInput.parse(repo)
        guard entry.path.lowercased().hasSuffix(".dylib") else { throw AppError(text: "只支持 dylib 元信息") }
        let resolved = try await resolvedBranch(repo, branch: branch)
        let head = try await workspaceHead(repo, branch: resolved)
        let endpoint = try Self.repoPath(repo)
        let commit = try await decoded(GitCommitInfo.self, endpoint + "/git/commits/" + Self.component(head))
        let tree = try await decoded(GitTreeInfo.self, endpoint + "/git/trees/" + Self.component(commit.tree.sha), query: [.init(name: "recursive", value: "1")])
        guard !tree.truncated, let file = tree.tree.first(where: { $0.path == entry.path && $0.type == "blob" && ["100644", "100755"].contains($0.mode) }), file.sha == entry.sha else { throw AppError(text: "文件已变化或树无效，请刷新") }
        let existing = tree.tree.first { $0.path == "trollpackages.json" && $0.type == "blob" }
        var index: [String: Any] = ["repository_name": repo, "packages": []]
        var rawIndex = Data("{\"repository_name\":\"\(repo)\",\"packages\":[]}".utf8)
        if let existing {
            let raw = try await decoded(WorkspaceBlob.self, endpoint + "/git/blobs/" + Self.component(existing.sha))
            guard raw.size <= 1024 * 1024, raw.encoding == "base64", let bytes = Data(base64Encoded: raw.content, options: .ignoreUnknownCharacters), let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw AppError(text: "索引格式无效或超过 1 MiB") }
            rawIndex = bytes
            index = object
        }
        _ = try TrollMetadata.package(index: index, repo: repo, branch: resolved, path: entry.path)
        let binding = WorkspaceBinding(repo: repo, branch: resolved, head: head, tree: commit.tree.sha, modes: Dictionary(uniqueKeysWithValues: tree.tree.filter { $0.type == "blob" }.map { ($0.path, $0.mode) }), snapshot: LocalSnapshot())
        return TrollMetadataSnapshot(binding: binding, index: index, rawIndex: rawIndex, indexSHA: existing?.sha, dylibSHA: file.sha, path: entry.path)
    }
    func saveMetadata(_ original: TrollMetadataSnapshot, fields: [String: String]) async throws {
        guard try await workspaceHead(original.binding.repo, branch: original.binding.branch) == original.binding.head else { throw AppError(text: "远端已变化，请关闭并重新载入；未提交") }
        let file = try await self.file(original.binding.repo, path: original.path, branch: original.binding.head)
        guard file.sha == original.dylibSHA else { throw AppError(text: "插件 SHA 已变化") }
        let bytes = try TrollMetadata.updating(raw: original.rawIndex, repo: original.binding.repo, branch: original.binding.branch, path: original.path, fields: fields)
        _ = try await commitWorkspace(original.binding, writes: [WorkspaceWrite(path: "trollpackages.json", bytes: bytes)], message: "Update plugin metadata: " + (fields["name"] ?? original.path))
    }
    func saveRemoteDeb(repo: String, branch: String, head: String, entry: Entry, output: URL, message: String) async throws {
        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? Int64.max
        guard size <= 10 * 1024 * 1024 else { throw AppError(text: "新 deb 超过普通提交 10 MiB 限额，请保存文件使用 Release") }
        guard try await workspaceHead(repo, branch: branch) == head else { throw AppError(text: "远端 HEAD 已变化，请重新载入；未提交") }
        let current = try await file(repo, path: entry.path, branch: head)
        guard current.sha == entry.sha else { throw AppError(text: "原文件 SHA 已变化，请重新载入") }
        let item = PendingRepoItem(local: output, size: size, path: entry.path, sha: entry.sha, head: head)
        try await commitQueue(repo: repo, branch: branch, items: [item], message: message.isEmpty ? "Edit deb metadata" : message)
    }
    static func trollSize(_ count: Int) -> String {
        if count >= 1024 * 1024 { return String(format: "%.2f MB", Double(count) / 1048576.0) }
        return String(format: "%.1f KB", Double(count) / 1024.0)
    }
    func downloadFile(_ repo: String, entry: Entry, branch: String) async throws -> URL {
        let endpoint = try Self.repoPath(repo) + "/contents/" + Self.filePath(entry.path)
        var r = try request(url(endpoint, query: branch.isEmpty ? [] : [.init(name: "ref", value: branch)]))
        r.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        return try await download(r, name: entry.name)
    }
    func downloadAsset(_ repo: String, asset: Asset) async throws -> URL {
        let endpoint = try Self.repoPath(repo) + "/releases/assets/" + String(asset.id)
        var r = try request(url(endpoint))
        r.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return try await download(r, name: asset.name, redirect: ReleaseAssetRedirectPolicy())
    }
    func downloadZIP(_ repo: String, branch: String) async throws -> URL {
        let repo = try RepositoryInput.parse(repo)
        let endpoint = try Self.repoPath(repo) + "/zipball" + (branch.isEmpty ? "" : "/" + Self.component(branch))
        return try await download(request(url(endpoint)), name: repo.replacingOccurrences(of: "/", with: "-") + ".zip")
    }
    private func download(_ request: URLRequest, name: String, redirect: URLSessionTaskDelegate = ArchiveRedirectPolicy()) async throws -> URL {
        let (tmp, response) = try await session.download(for: request, delegate: redirect)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try ensureActiveAccount()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var body = Data()
        if !(200..<300).contains(status), let handle = try? FileHandle(forReadingFrom: tmp) {
            defer { try? handle.close() }
            body = (try? handle.read(upToCount: 8192)) ?? Data()
        }
        try check(body, response, operation: "下载归档/文件")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = DownloadRules.safeName(name)
        let target = dir.appendingPathComponent(safe)
        try FileManager.default.moveItem(at: tmp, to: target)
        return target
    }
    // These bounded endpoints do not use decoded(): large JSON is parsed off MainActor.
    func followIdentity() throws -> String {
        try ensureActiveAccount()
        guard !CredentialStore.read(account: accountID).isEmpty else { throw AppError(text: "请先登录账号。") }
        return try UserFollowRules.login(login.isEmpty ? (AccountStore.accounts.first { $0.id == accountID }?.login ?? "") : login)
    }
    func followRequest(_ input: String, method: String) async throws -> Bool {
        let viewer = try followIdentity(), target = try UserFollowRules.login(input)
        guard viewer != target, ["GET", "PUT", "DELETE"].contains(method) else { throw AppError(text: "无效关注操作。") }
        // Public relationship reads need no additional OAuth scope. Writes affect only the signed-in user.
        let path = method == "GET" ? "/users/\(Self.component(viewer))/following/\(Self.component(target))" : "/user/following/\(Self.component(target))"
        var r = try request(url(path), method: method)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.timeoutInterval = 30
        if method != "GET" { r.setValue("0", forHTTPHeaderField: "Content-Length") }
        let (_, response) = try await session.data(for: r, delegate: OfficialUpdateRedirectPolicy())
        try Task.checkCancellation(); _ = try followIdentity()
        guard let http = response as? HTTPURLResponse else { throw AppError(text: "关注接口未返回有效响应。") }
        return try UserFollowRules.status(http.statusCode, checking: method == "GET")
    }
    private func managedJSON<T: Decodable>(_ type: T.Type, repo: String, suffix: String,
        method: String = "GET", object: [String: Any]? = nil, page: Int? = nil, perPage: Int = 20) async throws -> T {
        let canonical = try RepositoryInput.parse(repo)
        try Task.checkCancellation(); try ensureActiveAccount()
        if let page, !ReleaseManagementRules.validPage(page) { throw AppError(text: "已达分页预算，请在 GitHub 查看更多。") }
        let body = try object.map { try JSONSerialization.data(withJSONObject: $0) }
        let query: [URLQueryItem] = page.map { [.init(name: "per_page", value: String(perPage)), .init(name: "page", value: String($0))] } ?? []
        let r = try request(url(Self.repoPath(canonical) + suffix, query: query), method: method, body: body)
        let budget = ReleaseAPIRedirectPolicy()
        let file: URL
        let response: URLResponse
        do { (file, response) = try await session.download(for: r, delegate: budget) }
        catch {
            try Task.checkCancellation(); try ensureActiveAccount()
            if budget.exceededBudget { throw AppError(text: "发行版 JSON 超过 8 MiB 网络预算，已停止请求，请在 GitHub 查看。") }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation(); try ensureActiveAccount()
        // Error payloads are also bounded; never synchronously load a huge response.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let payload = try await Task.detached { () -> Data in
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                return try handle.read(upToCount: 8192) ?? Data()
            }.value
            if http.statusCode == 404 { throw ManagedReleaseHTTPError(status: 404, tagAlreadyExists: false) }
            if http.statusCode == 422 && ReleaseManagementRules.tagAlreadyExists(payload) {
                throw AppError(text: "此标签已有发行版，请编辑原发行版。")
            }
            try check(payload, response, operation: "发行版管理")
        } else { try check(Data(), response, operation: "发行版管理") }
        let result = try await Task.detached { try ReleaseJSON.decode(type, file: file) }.value
        try Task.checkCancellation(); try ensureActiveAccount()
        return result
    }
    private var managedPresenceCache: [String: Bool] = [:]
    func managedReleasePresence(_ repo: String, refresh: Bool = false) async throws -> Bool {
        let canonical = try RepositoryInput.parse(repo)
        try ensureActiveAccount(); try Task.checkCancellation()
        if !refresh, let cached = managedPresenceCache[canonical] { return cached }
        struct Presence: Decodable { let id: Int }
        let rows = try await managedJSON([Presence].self, repo: canonical, suffix: "/releases", page: 1, perPage: 1)
        try ensureActiveAccount(); try Task.checkCancellation()
        if managedPresenceCache.count >= 100 { managedPresenceCache.removeAll() }
        managedPresenceCache[canonical] = !rows.isEmpty
        return !rows.isEmpty
    }
    private var managedLatestCache: [String: Int] = [:] // 0 represents a verified 404; owner is this account/session API.
    func managedLatestID(_ repo: String, refresh: Bool = false) async throws -> Int? {
        let canonical = try RepositoryInput.parse(repo)
        try ensureActiveAccount(); try Task.checkCancellation()
        if !refresh, let cached = managedLatestCache[canonical] { return cached == 0 ? nil : cached }
        struct Latest: Decodable { let id: Int }
        let id: Int
        do { id = try await managedJSON(Latest.self, repo: canonical, suffix: "/releases/latest").id }
        catch let error as ManagedReleaseHTTPError where error.status == 404 {
            _ = try await managedRepository(canonical) // A hidden/inaccessible repo is not "no latest".
            id = 0
        }
        try ensureActiveAccount(); try Task.checkCancellation()
        if managedLatestCache.count >= 100 { managedLatestCache.removeAll() }
        managedLatestCache[canonical] = id
        return id == 0 ? nil : id
    }
    private func verifyManagedTagAvailable(_ repo: String, tag: String, originalID: Int?) async throws {
        do {
            let found = try await managedJSON(ManagedRelease.self, repo: repo, suffix: "/releases/tags/" + Self.component(tag))
            guard found.id == originalID else { throw AppError(text: "此标签已有发行版，请编辑原发行版。") }
        } catch let error as ManagedReleaseHTTPError where error.status == 404 {
            // The tag endpoint omits drafts. Check all visible releases, not git refs.
        }
        for page in 1...ReleaseManagementRules.pageLimit {
            let rows = try await managedReleases(repo, page: page)
            if rows.contains(where: { $0.tag_name == tag && $0.id != originalID }) {
                throw AppError(text: "此标签已有发行版，请编辑原发行版。")
            }
            if rows.count < ReleaseManagementRules.pageSize { return }
        }
        throw AppError(text: "发行版超过标签检查范围，请在 GitHub 管理。")
    }
    func invalidateManagedPresence(_ repo: String) {
        managedPresenceCache.removeValue(forKey: repo)
        managedLatestCache.removeValue(forKey: repo)
    }
    func managedRepository(_ repo: String) async throws -> Repository {
        try await managedJSON(Repository.self, repo: repo, suffix: "")
    }
    func managedReleases(_ repo: String, page: Int) async throws -> [ReleaseSummary] {
        try await managedJSON([ReleaseSummary].self, repo: repo, suffix: "/releases", page: page)
    }
    func managedRelease(_ repo: String, id: Int) async throws -> ManagedRelease {
        guard id > 0 else { throw AppError(text: "无效发行版 ID") }
        return try await managedJSON(ManagedRelease.self, repo: repo, suffix: "/releases/\(id)")
    }
    func managedAssets(_ repo: String, id: Int, page: Int) async throws -> [Asset] {
        guard id > 0 else { throw AppError(text: "无效发行版 ID") }
        return try await managedJSON([Asset].self, repo: repo, suffix: "/releases/\(id)/assets", page: page)
    }
    private func managedWriteAccess(_ repo: String) async throws {
        let info = try await managedRepository(repo)
        guard ReleaseManagementRules.canWrite(info.permissions?.push, session: isCurrentSession) else {
            throw AppError(text: "没有已确认的仓库写权限；Token 还需 Contents 写权限。")
        }
        try Task.checkCancellation()
    }
    func saveManagedRelease(_ repo: String, original: ManagedRelease?, form: ReleaseForm) async throws -> ManagedRelease {
        try await managedWriteAccess(repo)
        guard ReleaseManagementRules.validTag(form.tag), form.validMarker, ReleaseManagementRules.editable(form.body) else {
            throw AppError(text: "请填写有效标签；正文编辑限 128 KiB，超限请在 GitHub 编辑，不会截断保存。")
        }
        if let original {
            let current = try await managedRelease(repo, id: original.id)
            guard current == original else { throw AppError(text: "远端发行版已变化，请关闭编辑并刷新；未覆盖远端。") }
        }
        if original?.tag_name != form.tag { try await verifyManagedTagAvailable(repo, tag: form.tag, originalID: original?.id) }
        if let original, form.marker == .latest {
            let latest = try await managedLatestID(repo, refresh: true)
            if form.initialLatestID == original.id && latest != original.id {
                throw AppError(text: "最新版标记已变化，请关闭编辑并刷新。")
            }
        }
        var object: [String: Any] = ["name": form.title, "tag_name": form.tag, "body": form.body, "draft": form.draft, "prerelease": form.prerelease, "make_latest": form.makeLatest]
        if let original, form.initialLatestID == original.id, form.marker == .latest {
            object.removeValue(forKey: "make_latest") // Preserve an unchanged official Latest; do not promote it again.
        }
        if original == nil && !form.branch.isEmpty { object["target_commitish"] = form.branch }
        // PATCH only changes release metadata; never calls git refs/tag mutation APIs.
        return try await managedJSON(ManagedRelease.self, repo: repo,
            suffix: original.map { "/releases/\($0.id)" } ?? "/releases",
            method: original == nil ? "POST" : "PATCH", object: object)
    }
    func deleteManagedRelease(_ repo: String, original: ManagedRelease, asset: Asset?) async throws {
        try await managedWriteAccess(repo)
        let current = try await managedRelease(repo, id: original.id)
        guard current == original else { throw AppError(text: "远端发行版已变化，请刷新后重新确认。") }
        if let asset {
            // Verify fixed asset ID belongs to the confirmed release, within a finite budget.
            var matched = false
            for page in 1...ReleaseManagementRules.pageLimit {
                let rows = try await managedAssets(repo, id: original.id, page: page)
                if rows.contains(where: { $0.id == asset.id && $0.name == asset.name }) { matched = true; break }
                if rows.count < ReleaseManagementRules.pageSize { break }
            }
            guard matched else { throw AppError(text: "附件已变化或超出核验预算，请刷新。") }
        }
        let suffix = asset.map { "/releases/assets/\($0.id)" } ?? "/releases/\(original.id)"
        let r = try request(url(Self.repoPath(repo) + suffix), method: "DELETE")
        let (d, response) = try await session.data(for: r, delegate: ReleaseAPIRedirectPolicy())
        try Task.checkCancellation(); try check(d, response, operation: "删除发行版/附件（不删除标签）")
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw AppError(text: "未收到删除成功确认，请刷新核实。") }
    }
    func uploadManagedAsset(_ repo: String, original: ManagedRelease, file: URL,
        progress: @escaping (Double) -> Void) async throws -> Asset {
        try await managedWriteAccess(repo)
        let current = try await managedRelease(repo, id: original.id)
        guard current == original else { throw AppError(text: "远端发行版已变化，请刷新后重新上传。") }
        let size = try await Task.detached { (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? Int64.max }.value
        guard ReleaseManagementRules.validAsset(size: size, name: file.lastPathComponent) else { throw AppError(text: "附件必须小于 2 GiB，且文件名有效。") }
        var checkedAll = false
        for page in 1...ReleaseManagementRules.pageLimit {
            let rows = try await managedAssets(repo, id: original.id, page: page)
            guard !ReleaseManagementRules.duplicate(name: file.lastPathComponent, names: rows.map(\.name)) else { throw AppError(text: "同名附件已存在；请改名或单独确认删除，不自动覆盖。") }
            if rows.count < ReleaseManagementRules.pageSize { checkedAll = true; break }
        }
        guard checkedAll else { throw AppError(text: "附件超过同名检查预算，未上传。请在 GitHub 管理。") }
        let canonical = try RepositoryInput.parse(repo)
        var c = URLComponents(string: "https://uploads.github.com" + (try Self.repoPath(canonical)) + "/releases/\(original.id)/assets")!
        c.queryItems = [.init(name: "name", value: file.lastPathComponent)]
        let r = try request(c.url!, method: "POST", binary: true)
        let (data, response) = try await session.upload(for: r, fromFile: file, delegate: ManagedUploadProgress(update: progress))
        try Task.checkCancellation(); try check(data, response, operation: "上传附件")
        guard data.count <= ReleaseManagementRules.jsonLimit else { throw AppError(text: "上传响应超预算，请刷新核实。") }
        let asset = try await Task.detached { try JSONDecoder().decode(Asset.self, from: data) }.value
        try Task.checkCancellation(); try ensureActiveAccount()
        return asset
    }
    func downloadManagedAsset(_ repo: String, asset: Asset, progress: @escaping (Double) -> Void) async throws -> URL {
        var r = try request(url(Self.repoPath(repo) + "/releases/assets/\(asset.id)"))
        r.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return try await download(r, name: asset.name, redirect: ManagedDownloadProgress(update: progress))
    }
    func downloadManagedAssetWithProgress(_ repo: String, asset: Asset, transfer: @escaping (ReleaseDownloadProgress) -> Void) async throws -> URL {
        var r = try request(url(Self.repoPath(repo) + "/releases/assets/\(asset.id)"))
        r.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return try await download(r, name: asset.name, redirect: ReleaseAssetDownloadDelegate(update: transfer))
    }

}

// Current-account profile writes have their own endpoint and acknowledgement checks.
extension GitHub {
    func socialAccountRead(_ login: String, page: Int) async throws -> Data {
        try await socialAccountData(method: "GET", page: page, path: "/users/" + Self.component(login) + "/social_accounts")
    }
    func ownSocialAccounts() async throws -> [CommunitySocialAccount] {
        var result: [CommunitySocialAccount] = []
        var seen = Set<String>()
        for page in 1...CommunityRules.pageLimit {
            let bytes = try await socialAccountData(method: "GET", page: page)
            let batch = try JSONDecoder().decode([CommunitySocialAccount].self, from: bytes)
            result += batch.filter { seen.insert($0.id).inserted }
            if batch.count < CommunityRules.pageSize { return result }
        }
        throw AppError(text: "社交账号列表未加载完整，请稍后重试。")
    }
    func addSocialAccount(_ raw: String) async throws {
        guard raw.utf8.count <= 2048, let target = CommunityRules.profileWebsiteURL(raw) else {
            throw AppError(text: "请填写有效的社交账号或网站链接。")
        }
        let bytes = try await socialAccountData(method: "POST", link: target.absoluteString)
        let result = try JSONDecoder().decode([CommunitySocialAccount].self, from: bytes)
        guard result.contains(where: { $0.url == target.absoluteString }) else {
            throw AppError(text: "GitHub 未确认新增链接，请刷新核实；原链接不会自动删除。")
        }
        recordProfileWriteAuthorization(true)
    }
    func deleteSocialAccount(_ link: String) async throws {
        guard !link.isEmpty, link.utf8.count <= 2048 else { throw AppError(text: "无效的社交账号链接。") }
        _ = try await socialAccountData(method: "DELETE", link: link)
        recordProfileWriteAuthorization(true)
    }
    private func socialAccountData(method: String, link: String? = nil, page: Int = 1, path: String = "/user/social_accounts") async throws -> Data {
        try Task.checkCancellation(); try ensureActiveAccount()
        guard ["GET", "POST", "DELETE"].contains(method) else { throw AppError(text: "无效的社交账号操作。") }
        guard method == "GET" || path == "/user/social_accounts" else { throw AppError(text: "社交账号只能修改当前账号。") }
        let body = try link.map { try JSONSerialization.data(withJSONObject: ["account_urls": [$0]]) }
        let query = method == "GET" ? try CommunityRules.page(page) : []
        var r = try request(url(path, query: query), method: method, body: body)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.data(for: r, delegate: OfficialUpdateRedirectPolicy())
        try Task.checkCancellation(); try ensureActiveAccount()
        let code = (response as? HTTPURLResponse)?.statusCode
        if code == 403, method != "GET" {
            let http = response as? HTTPURLResponse
            if http?.value(forHTTPHeaderField: "X-RateLimit-Remaining") != "0", http?.value(forHTTPHeaderField: "Retry-After") == nil {
                recordProfileWriteAuthorization(false)
            }
            throw AppError(text: "当前授权无法管理社交账号。浏览器授权请开启“授权社交账号管理”；Token 需 user 或 Profile 写入权限。")
        }
        if code == 422 {
            throw AppError(text: "GitHub 未接受此链接，请检查格式、是否重复或数量已满。如已满，请先删除不再使用的链接，再添加新链接。")
        }
        try check(bytes, response, operation: "社交账号管理")
        let expected = method == "GET" ? 200 : (method == "POST" ? 201 : 204)
        guard code == expected else { throw AppError(text: "未收到社交账号操作成功确认，请刷新核实后重试。") }
        guard bytes.count <= 1024 * 1024 else { throw AppError(text: "社交账号响应过大。") }
        if method != "GET" {
            NotificationCenter.default.post(name: .socialAccountsChanged, object: nil,
                userInfo: ["account": accountID, "generation": accountGeneration])
        }
        return bytes
    }
    // MARK: - Upstream sync
    // Step 1 is read-only: one compare request, no refs, no merges.
    func upstreamCompare(repo: String, base: String, upstream: UpstreamSyncRules.Target) async throws -> UpstreamCompare {
        let path = try UpstreamSyncRules.comparePath(repo: repo, base: base, upstream: upstream)
        return try await decoded(UpstreamCompare.self, path)
    }
    func upstreamBranchHead(repo: String, branch: String) async throws -> String {
        let bytes = try await data(try UpstreamSyncRules.branchHeadPath(repo: repo, branch: branch))
        guard let sha = UpstreamSyncRules.objectSHA(bytes) else {
            throw AppError(text: "未能读取目标分支的最新提交，请刷新后重试。")
        }
        return sha
    }
    /// Creates the backup tag and the temporary branch. Both point at the exact
    /// head that was just read; neither moves the target branch.
    func createUpstreamRef(repo: String, ref: String, sha: String) async throws {
        guard UpstreamSyncRules.validSHA(sha) else { throw AppError(text: "提交 SHA 无效，未创建任何引用。") }
        _ = try await data(try UpstreamSyncRules.refsPath(repo: repo), method: "POST",
                           object: UpstreamSyncRules.refObject(ref: ref, sha: sha))
    }
    func mergeUpstream(repo: String, base: String, upstream: UpstreamSyncRules.Target,
                       message: String) async throws -> UpstreamSyncRules.MergeOutcome {
        try ensureActiveAccount()
        try await requireWriteAccess(repo)
        try Task.checkCancellation()
        let body = try JSONSerialization.data(withJSONObject:
            UpstreamSyncRules.mergeObject(base: base, upstream: upstream, message: message))
        var r = try request(url(try UpstreamSyncRules.mergesPath(repo: repo)), method: "POST", body: body)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.data(for: r)
        try Task.checkCancellation(); try ensureActiveAccount()
        guard let http = response as? HTTPURLResponse else { throw AppError(text: "无有效服务器响应") }
        if [401, 403, 404].contains(http.statusCode) {
            throw GitHubAPIError(status: http.statusCode, operation: "合并上游到临时分支",
                                 reason: UpstreamSyncRules.message(bytes) ?? "GitHub 拒绝了合并请求",
                                 permissions: http.value(forHTTPHeaderField: "X-Accepted-GitHub-Permissions"))
        }
        return UpstreamSyncRules.mergeOutcome(status: http.statusCode, body: bytes)
    }
    /// Fast-forward only: the request always sends force: false.
    func applyUpstreamFastForward(repo: String, branch: String,
                                  sha: String) async throws -> UpstreamSyncRules.ApplyOutcome {
        guard UpstreamSyncRules.validSHA(sha) else { throw AppError(text: "提交 SHA 无效，未更新分支。") }
        try ensureActiveAccount()
        try await requireWriteAccess(repo)
        try Task.checkCancellation()
        let body = try JSONSerialization.data(withJSONObject: UpstreamSyncRules.applyObject(sha: sha))
        var r = try request(url(try UpstreamSyncRules.branchRefPath(repo: repo, branch: branch)),
                            method: "PATCH", body: body)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.data(for: r)
        try Task.checkCancellation(); try ensureActiveAccount()
        guard let http = response as? HTTPURLResponse else { throw AppError(text: "无有效服务器响应") }
        if [401, 403, 404].contains(http.statusCode) {
            throw GitHubAPIError(status: http.statusCode, operation: "应用快进更新",
                                 reason: UpstreamSyncRules.message(bytes) ?? "GitHub 拒绝了引用更新",
                                 permissions: http.value(forHTTPHeaderField: "X-Accepted-GitHub-Permissions"))
        }
        return UpstreamSyncRules.applyOutcome(status: http.statusCode, body: bytes)
    }
}
