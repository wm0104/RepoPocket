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
    let accountID = AccountStore.activeID
    private let session: URLSession
    private let accountGeneration = AccountStore.generation
    private var accountObserver: AnyCancellable?
    // Session-scoped caches never publish mutations to the whole repository list.
    private var parentTasks: [String: Task<RepositoryReference?, Never>] = [:]
    private var parentCache: [String: (Date, RepositoryReference?)] = [:]
    private var parentActive = 0
    private var parentWaiters: [CheckedContinuation<Void, Never>] = []
    private var collectionCache: [RepositoryHomeSection: [Repository]] = [:]
    lazy var stars = RepositoryStarStore(api: self)
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
    func clearMemoryCaches() {
        guard parentTasks.isEmpty else { return }
        parentCache.removeAll(); collectionCache.removeAll()
    }
    var canCheckAppUpdate: Bool { isCurrentSession && !CredentialStore.read(account: accountID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
        accountObserver = NotificationCenter.default.publisher(for: .githubAccountChanged)
            .sink { [weak self] _ in
                self?.session.invalidateAndCancel()
                self?.stars.invalidate()
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
        guard canCheckAppUpdate else { throw AppError(text: "请登录账号") }
        let authenticated = true
        var r = try request(endpoint)
        r.timeoutInterval = 30
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("RepoPocket", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.data(for: r, delegate: OfficialUpdateRedirectPolicy())
        try ensureActiveAccount()
        guard let http = response as? HTTPURLResponse else { throw AppError(text: "更新接口未返回有效 HTTP 响应。") }
        guard http.statusCode == 200 else {
            throw AppError(text: AppUpdateRules.statusError(http.statusCode, headers: http.allHeaderFields, body: bytes, authenticated: authenticated))
        }
        return bytes
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
        let folder = try LocalStore.importFolder(stage, name: binding.repo.replacingOccurrences(of: "/", with: "-") + (binding.branch == "main" || binding.branch == "master" ? "" : "-" + binding.branch))
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
        let writes = try items.map { item -> WorkspaceWrite in
            let data = try item.local.map { file -> Data in
                let prepared = try DebControlEditor.prepareForUpload(file)
                defer { if prepared.file != file { try? FileManager.default.removeItem(at: prepared.file.deletingLastPathComponent()) } }
                if let notice = prepared.notice { self.message = notice }
                return try Data(contentsOf: prepared.file)
            }
            guard data == nil || data!.count <= 10 * 1024 * 1024 else { throw AppError(text: item.path! + " 超过上传限制") }
            return WorkspaceWrite(path: item.path!, bytes: data)
        }
        let binding = WorkspaceBinding(repo: repo, branch: branch, head: head, tree: commit.tree.sha, modes: Dictionary(uniqueKeysWithValues: tree.tree.filter { $0.type == "blob" }.map { ($0.path, $0.mode) }), snapshot: LocalSnapshot())
        _ = try await commitWorkspace(binding, writes: writes, message: message)
    }
    func identify() async throws {
        let user = try await decoded(User.self, "/user")
        try ensureActiveAccount()
        login = user.login; avatarURL = user.avatar_url; profile = user
        if accountID == "legacy", let id = user.id {
            let account = GitHubAccount(id: String(id), login: user.login, avatarURL: user.avatar_url)
            try CredentialStore.save(CredentialStore.read(account: "legacy"), account: account.id)
            try AccountStore.record(account)
            CredentialStore.clear(account: "legacy")
            AccountStore.activate(account.id)
        }
    }
    func addAccount(token: String) async throws {
        try ensureActiveAccount()
        // Validate before replacing any existing credential. No secrets enter metadata or logs.
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer " + token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.data(for: request)
        try check(bytes, response, operation: "验证账号")
        let user = try JSONDecoder().decode(User.self, from: bytes)
        try ensureActiveAccount()
        guard let id = user.id else { throw AppError(text: "GitHub 未返回账号标识") }
        let account = GitHubAccount(id: String(id), login: user.login, avatarURL: user.avatar_url)
        try Task.checkCancellation()
        try CredentialStore.save(token, account: account.id)
        try AccountStore.record(account)
        AccountStore.activate(account.id)
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
    func searchRepositories(_ query: String, page: Int) async throws -> RepositorySearchResponse {
        let endpoint = RepositorySearchRules.endpoint(kind: .repositories, query: query, page: page)
        let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        return try await decoded(RepositorySearchResponse.self, endpoint.path, query: parts.queryItems ?? [])
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
    func fork(_ repo: String) async throws -> Repository {
        let endpoint = try Self.repoPath(repo)
        // Revalidate identity using the current credential, not cached UI state.
        try await identify()
        let owner = try RepositoryInput.parse(repo).split(separator: "/").first.map(String.init) ?? ""
        guard owner.caseInsensitiveCompare(login) != .orderedSame else {
            throw AppError(text: "这是你自己的仓库（\(login)）。GitHub 不允许把自己的仓库 Fork 回同一个账号。\n\n更新文件请点“浏览这个仓库”或“提交 / 发布”。如果要另外复制一份，需要新建不同名字的仓库再复制内容；这不属于 Fork，本版尚未提供完整仓库复制。")
        }
        return try await decoded(Repository.self, endpoint + "/forks", method: "POST", object: [:])
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
        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        guard !bytes.isEmpty else { throw AppError(text: "dylib 不能为空") }
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
        var package: [String: Any] = ["name": name, "version": normalizedVersion, "description": (description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? description! : name), "dylib": dylibURL, "section": "插件", "size": Self.trollSize(bytes.count)]
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
        let dylibBlob = try await decoded(GitObject.self, endpoint + "/git/blobs", method: "POST", object: ["content": bytes.base64EncodedString(), "encoding": "base64"])
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
        do {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = (200..<300).contains(status) ? Data() : ((try? Data(contentsOf: tmp)) ?? Data())
            try check(Data(body.prefix(8192)), response, operation: "下载归档/文件")
        } catch { try? FileManager.default.removeItem(at: tmp); throw error }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = DownloadRules.safeName(name)
        let target = dir.appendingPathComponent(safe)
        try FileManager.default.moveItem(at: tmp, to: target)
        return target
    }
}
