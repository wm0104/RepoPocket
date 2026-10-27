import Foundation
import Combine

struct AppError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
enum AccountStore {
    static var activeID = "fixture-owner"
    static var generation = UUID()
}
enum CredentialStore {
    static var token = "fixture-social-token"
    static func read(account: String) -> String { token }
}

// PRODUCTION_MODELS
// PRODUCTION_REPOSITORY_INPUT
// PRODUCTION_COMMUNITY_MODELS
// PRODUCTION_REDIRECT_POLICY

@MainActor final class GitHub {
    static func component(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
    let accountID = AccountStore.activeID
    private let accountGeneration = AccountStore.generation
    private let session: URLSession
    var isCurrentSession: Bool { accountID == AccountStore.activeID && accountGeneration == AccountStore.generation }
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SocialProtocol.self]
        config.urlCache = nil
        session = URLSession(configuration: config)
    }
    private func ensureActiveAccount() throws {
        guard isCurrentSession else { throw CancellationError() }
    }
    private func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        var parts = URLComponents(string: "https://api.github.com" + path)!
        if !query.isEmpty { parts.queryItems = query }
        return parts.url!
    }
    private func check(_ bytes: Data, _ response: URLResponse, operation: String) throws {
        try ensureActiveAccount()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError(text: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
    }
    // PRODUCTION_REQUEST
}

// PRODUCTION_SOCIAL_API
// PRODUCTION_SOCIAL_STATE

private struct SocialReply {
    let code: Int
    let body: Data
    let held: Bool
    init(_ code: Int, _ body: String = "", held: Bool = false) {
        self.code = code; self.body = Data(body.utf8); self.held = held
    }
}

/// Every request is intercepted; unexpected requests fail instead of reaching the network.
private final class SocialProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var replies: [SocialReply] = []
    private static var requests: [URLRequest] = []
    private static var pending: [(SocialProtocol, SocialReply)] = []
    private var stopped = false

    static func reset(_ values: [SocialReply] = []) {
        lock.lock(); defer { lock.unlock() }
        precondition(pending.isEmpty, "Previous held response was not released")
        replies = values; requests = []
    }
    static var captured: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static func releaseHeld() {
        lock.lock(); let held = pending; pending = []; lock.unlock()
        held.forEach { $0.0.deliver($0.1) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        captured.httpBody = Self.body(request)
        Self.lock.lock()
        Self.requests.append(captured)
        precondition(!Self.replies.isEmpty, "Unexpected request: \(request.httpMethod ?? "") \(request.url!.absoluteString)")
        let reply = Self.replies.removeFirst()
        if reply.held { Self.pending.append((self, reply)) }
        Self.lock.unlock()
        if !reply.held { deliver(reply) }
    }
    private func deliver(_ reply: SocialReply) {
        Self.lock.lock(); let cancelled = stopped; Self.lock.unlock()
        guard !cancelled else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.code, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.lock(); stopped = true; Self.lock.unlock() }
    private static func body(_ request: URLRequest) -> Data? {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        return bytes
    }
}

@main struct SocialAccountsTests {
    static let old = "https://example.invalid/old"
    static let next = "https://example.invalid/new"
    static let other = "https://example.invalid/other"

    static func rows(_ urls: [String]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject:
            urls.map { ["provider": "generic", "url": $0] }), as: UTF8.self)
    }
    static var methods: [String] { SocialProtocol.captured.map { $0.httpMethod! } }
    static func links(_ request: URLRequest) -> [String] {
        let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: [String]]
        precondition(Set(body.keys) == ["account_urls"])
        return body["account_urls"]!
    }
    @MainActor static func failed(_ action: () async throws -> Void) async -> String {
        do { try await action(); preconditionFailure("Unconfirmed operation was accepted") }
        catch { return error.localizedDescription }
    }
    @MainActor static func waitForRequest(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while SocialProtocol.captured.count < count {
            precondition(Date() < deadline, "Expected intercepted request did not start")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    @MainActor static func ready(_ urls: [String] = [old]) async -> (GitHub, SocialAccountsState) {
        SocialProtocol.reset([.init(200, rows(urls))])
        let api = GitHub(), state = SocialAccountsState()
        await state.load(api: api)!.value
        precondition(state.loaded && !state.loading && state.accounts.map(\.url) == urls)
        return (api, state)
    }
    @MainActor static func main() async throws {
        // Execute the production read pagination, request builder, API and state below.
        let api = GitHub()
        let first = (0..<30).map { "https://example.invalid/page/\($0)" }
        SocialProtocol.reset([.init(200, rows(first)), .init(200, rows([first[0], next]))])
        let listed = try await api.ownSocialAccounts()
        precondition(listed.map(\.url) == first + [next] && methods == ["GET", "GET"])
        for (index, request) in SocialProtocol.captured.enumerated() {
            precondition(request.url!.scheme == "https" && request.url!.host == "api.github.com")
            precondition(request.url!.path == "/user/social_accounts" && request.httpBody == nil)
            precondition(request.cachePolicy == .reloadIgnoringLocalCacheData)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains { $0.name == "page" && $0.value == String(index + 1) })
            precondition(query.contains { $0.name == "per_page" && $0.value == "30" })
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-social-token")
            precondition(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
            precondition(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        }
        SocialProtocol.reset([.init(200, rows([next]))])
        _ = try await api.socialAccountRead("opa334", page: 1)
        precondition(SocialProtocol.captured[0].url!.path == "/users/opa334/social_accounts")
        precondition(SocialProtocol.captured[0].cachePolicy == .reloadIgnoringLocalCacheData)
        SocialProtocol.reset([.init(201, rows([next])), .init(204)])
        try await api.addSocialAccount(" example.invalid/new ")
        try await api.deleteSocialAccount(old)
        precondition(methods == ["POST", "DELETE"])
        for request in SocialProtocol.captured {
            precondition(request.url!.path == "/user/social_accounts" && request.url!.query == nil)
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-social-token")
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        }
        precondition(links(SocialProtocol.captured[0]) == [next])
        precondition(links(SocialProtocol.captured[1]) == [old])

        for invalid in ["", "   ", "javascript:alert(1)", "file:///tmp/link", "fixtureapp://user", "tel:123",
                        "https://user:password@example.invalid", "https://example.invalid/with space", String(repeating: "a", count: 2049)] {
            SocialProtocol.reset()
            _ = await failed { try await api.addSocialAccount(invalid) }
            precondition(SocialProtocol.captured.isEmpty)
        }
        for invalid in ["", String(repeating: "a", count: 2049)] {
            SocialProtocol.reset()
            _ = await failed { try await api.deleteSocialAccount(invalid) }
            precondition(SocialProtocol.captured.isEmpty)
        }
        for code in [403, 422, 200, 202, 204] {
            SocialProtocol.reset([.init(code, rows([next]))])
            let error = await failed { try await api.addSocialAccount(next) }
            if code == 403 { precondition(error.contains("user") && error.contains("Profile")) }
            if code == 422 { precondition(error.contains("数量已满")) }
            precondition(methods == ["POST"])
        }
        for payload in [rows([]), rows([old]), "{\"unexpected\":true}"] {
            SocialProtocol.reset([.init(201, payload)])
            _ = await failed { try await api.addSocialAccount(next) }
        }
        for code in [403, 422, 200, 201, 202] {
            SocialProtocol.reset([.init(code)])
            _ = await failed { try await api.deleteSocialAccount(old) }
            precondition(methods == ["DELETE"])
        }
        SocialProtocol.reset([.init(201, rows([old]))])
        _ = await failed { _ = try await api.ownSocialAccounts() }
        SocialProtocol.reset((0..<10).map { _ in .init(200, rows(first)) })
        _ = await failed { _ = try await api.ownSocialAccounts() }
        precondition(SocialProtocol.captured.count == 10 && methods.allSatisfy { $0 == "GET" })

        // Existing links stay untouched when adding a replacement fails.
        let (deniedAPI, denied) = await ready()
        denied.beginEditing(denied.accounts[0]); denied.draft = next
        SocialProtocol.reset([.init(403), .init(200, rows([old]))])
        await denied.save(api: deniedAPI)
        precondition(methods == ["POST", "GET"] && denied.accounts.map(\.url) == [old])
        precondition(denied.error.contains("原链接没有删除") && denied.editingURL == old && denied.draft == next)
        precondition(!denied.busy && denied.message.isEmpty)
        SocialProtocol.reset([.init(201, rows([old])), .init(200, rows([old]))])
        await denied.save(api: deniedAPI)
        precondition(methods == ["POST", "GET"] && denied.accounts.map(\.url) == [old])
        precondition(denied.error.contains("未确认新增链接"))

        let (replaceAPI, replacement) = await ready()
        replacement.beginEditing(replacement.accounts[0]); replacement.draft = next
        SocialProtocol.reset([.init(201, rows([old, next])), .init(204), .init(200, rows([next]))])
        await replacement.save(api: replaceAPI)
        precondition(methods == ["POST", "DELETE", "GET"])
        precondition(links(SocialProtocol.captured[0]) == [next] && links(SocialProtocol.captured[1]) == [old])
        precondition(replacement.accounts.map(\.url) == [next] && replacement.error.isEmpty)
        precondition(replacement.editingURL == nil && replacement.draft.isEmpty && replacement.message.contains("已更新"))

        let (partialAPI, partial) = await ready()
        partial.beginEditing(partial.accounts[0]); partial.draft = next
        SocialProtocol.reset([.init(201, rows([old, next])), .init(403), .init(200, rows([old, next]))])
        await partial.save(api: partialAPI)
        precondition(methods == ["POST", "DELETE", "GET"] && partial.accounts.map(\.url) == [old, next])
        precondition(partial.error.contains("新链接已添加") && partial.error.contains("旧链接删除未获确认"))
        precondition(partial.message.isEmpty && !partial.busy)
        SocialProtocol.reset([.init(204), .init(200, rows([next]))])
        await partial.delete(old, api: partialAPI)
        precondition(methods == ["DELETE", "GET"] && partial.accounts.map(\.url) == [next] && partial.error.isEmpty)

        let (refreshAPI, refresh) = await ready()
        refresh.draft = next
        SocialProtocol.reset([.init(201, rows([old, next])), .init(500)])
        await refresh.save(api: refreshAPI)
        precondition(methods == ["POST", "GET"] && refresh.accounts.map(\.url) == [old, next])
        precondition(refresh.error.contains("列表刷新失败"))

        let (duplicateAPI, duplicate) = await ready([old, other])
        SocialProtocol.reset()
        duplicate.draft = other; await duplicate.save(api: duplicateAPI)
        precondition(duplicate.error.contains("已在列表中"))
        duplicate.beginEditing(duplicate.accounts[0]); await duplicate.save(api: duplicateAPI)
        precondition(duplicate.message.contains("没有变化"))
        duplicate.draft = other; await duplicate.save(api: duplicateAPI)
        precondition(duplicate.error.contains("已在列表中"))
        for invalid in ["fixtureapp://author", "tel:123", "https://user:pass@example.invalid", String(repeating: "x", count: 2049)] {
            duplicate.draft = invalid; await duplicate.save(api: duplicateAPI)
            precondition(!duplicate.error.isEmpty)
        }
        await duplicate.delete(next, api: duplicateAPI)
        precondition(SocialProtocol.captured.isEmpty)

        // No request is made by an obsolete account or an already cancelled task.
        let obsolete = GitHub()
        AccountStore.generation = UUID()
        SocialProtocol.reset()
        _ = await failed { _ = try await obsolete.ownSocialAccounts() }
        _ = await failed { try await obsolete.addSocialAccount(next) }
        _ = await failed { try await obsolete.deleteSocialAccount(old) }
        precondition(SocialProtocol.captured.isEmpty)
        let current = GitHub()
        let cancelled = Task { try await current.addSocialAccount(next) }
        cancelled.cancel()
        do { try await cancelled.value; preconditionFailure() } catch is CancellationError {}
        precondition(SocialProtocol.captured.isEmpty)

        for method in ["GET", "POST", "DELETE"] {
            let inFlight = GitHub()
            let code = method == "GET" ? 200 : (method == "POST" ? 201 : 204)
            SocialProtocol.reset([.init(code, method == "DELETE" ? "" : rows([next]), held: true)])
            let task = Task {
                if method == "GET" { _ = try await inFlight.ownSocialAccounts() }
                else if method == "POST" { try await inFlight.addSocialAccount(next) }
                else { try await inFlight.deleteSocialAccount(old) }
            }
            try await waitForRequest(1)
            AccountStore.generation = UUID(); SocialProtocol.releaseHeld()
            do { try await task.value; preconditionFailure() } catch is CancellationError {}
            precondition(methods == [method])
        }

        // Switch accounts or cancel after a confirmed POST starts: never delete the old link.
        for cancel in [false, true] {
            let (raceAPI, race) = await ready()
            race.beginEditing(race.accounts[0]); race.draft = next
            SocialProtocol.reset([.init(201, rows([old, next]), held: true)])
            let task = Task { await race.save(api: raceAPI) }
            try await waitForRequest(1)
            if cancel { task.cancel() }
            else { AccountStore.generation = UUID(); race.accountChanged() }
            SocialProtocol.releaseHeld()
            await task.value
            precondition(methods == ["POST"] && !race.busy && race.message.isEmpty)
            if !cancel { precondition(race.accounts.isEmpty && !race.loaded && race.error.isEmpty) }
        }

        let readAPI = GitHub(), readState = SocialAccountsState()
        SocialProtocol.reset([.init(200, rows([old]), held: true)])
        let reading = readState.load(api: readAPI)!
        try await waitForRequest(1)
        AccountStore.activeID = "fixture-other"; AccountStore.generation = UUID()
        readState.accountChanged(); SocialProtocol.releaseHeld()
        await reading.value
        precondition(!readState.loaded && !readState.loading && readState.accounts.isEmpty && readState.error.isEmpty)
        SocialProtocol.reset()
        await readState.save(api: readAPI); await readState.delete(old, api: readAPI)
        precondition(SocialProtocol.captured.isEmpty)

        print("PASS production social API routing, headers, pagination, canonical bodies, exact status and POST payload acknowledgement")
        print("PASS production social management add-before-delete, partial failure, refresh, duplicates and invalid-input preservation")
        print("PASS cancelled and obsolete accounts cannot publish reads, start writes or delete the old link after an interrupted replacement")
    }
}
