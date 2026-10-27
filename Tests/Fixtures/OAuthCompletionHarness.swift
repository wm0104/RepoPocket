import Foundation
import Combine

// PRODUCTION_ERRORS
// PRODUCTION_ACCOUNTS
// PRODUCTION_USER
// PRODUCTION_PRESENTATION
// PRODUCTION_REDIRECT

enum RefreshFailure {
    static func isCancellation(_ error: Error) -> Bool { error is CancellationError }
}
enum CredentialStore {
    static var tokens: [String: String] = [:]
    static func read(account: String = AccountStore.activeID) -> String { tokens[account] ?? "" }
    static func save(_ token: String, account: String) throws {
        tokens[account] = token
        AccountStore.updateAuthorization(account, scopes: nil)
    }
    static func clear(account: String) { tokens[account] = nil }
}

@MainActor final class GitHub {
    let accountID = AccountStore.activeID
    private let accountGeneration = AccountStore.generation
    private let session: URLSession
    var isCurrentSession: Bool { accountID == AccountStore.activeID && accountGeneration == AccountStore.generation }
    @Published private(set) var profileWriteAuthorization: Bool? = nil
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompletionProtocol.self]
        config.urlCache = nil
        session = URLSession(configuration: config)
        profileWriteAuthorization = AccountStore.accounts.first { $0.id == accountID }?.profileWriteAuthorization
    }
    // PRODUCTION_CHECK
    // PRODUCTION_ACCOUNT_SAVE
}

// PRODUCTION_DEVICE_OAUTH

private struct CompletionReply {
    let body: String
    let code: Int
    let scopes: String?
    let held: Bool
    init(_ body: String, code: Int = 200, scopes: String? = nil, held: Bool = false) {
        self.body = body; self.code = code; self.scopes = scopes; self.held = held
    }
}
private final class CompletionProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var replies: [CompletionReply] = []
    private static var requests: [URLRequest] = []
    private static var held: [(CompletionProtocol, CompletionReply)] = []
    private var stopped = false
    static func reset(_ values: [CompletionReply]) {
        lock.lock(); defer { lock.unlock() }
        precondition(held.isEmpty)
        replies = values; requests = []
    }
    static var captured: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static func releaseHeld() {
        lock.lock(); let ready = held; held = []; lock.unlock()
        ready.forEach { $0.0.deliver($0.1) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var value = request; value.httpBody = Self.body(request)
        Self.lock.lock()
        Self.requests.append(value)
        precondition(!Self.replies.isEmpty, "Unexpected request \(value.url!.absoluteString)")
        let reply = Self.replies.removeFirst()
        if reply.held { Self.held.append((self, reply)) }
        Self.lock.unlock()
        if !reply.held { deliver(reply) }
    }
    private func deliver(_ reply: CompletionReply) {
        Self.lock.lock(); let cancelled = stopped; Self.lock.unlock()
        guard !cancelled else { return }
        var headers = ["Content-Type": "application/json"]
        if let scopes = reply.scopes { headers["X-OAuth-Scopes"] = scopes }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.code, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
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

@main struct OAuthCompletionTests {
    static let user = #"{"id":100,"login":"fixture-alice","avatar_url":null}"#
    static let other = #"{"id":200,"login":"fixture-bob","avatar_url":null}"#
    static let device = #"{"device_code":"fixture-device","user_code":"AA-BB","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
    @MainActor static func drain(_ controller: DeviceOAuthController) async throws {
        let deadline = Date().addingTimeInterval(5)
        while controller.busy {
            precondition(Date() < deadline)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    @MainActor static func fail(_ action: () async throws -> Void) async -> String {
        do { try await action(); preconditionFailure("Rejected account was saved") }
        catch { return error.localizedDescription }
    }
    @MainActor static func main() async throws {
        UserDefaults.standard.removeObject(forKey: AccountStore.accountsKey)
        UserDefaults.standard.removeObject(forKey: AccountStore.activeKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AccountStore.accountsKey)
            UserDefaults.standard.removeObject(forKey: AccountStore.activeKey)
        }
        let legacy = try JSONDecoder().decode(GitHubAccount.self, from: Data(#"{"id":"100","login":"fixture-alice"}"#.utf8))
        precondition(legacy.oauthScopes == nil && legacy.profileWriteAuthorization == nil)
        try AccountStore.record(GitHubAccount(id: "100", login: "fixture-alice", avatarURL: nil,
                                             oauthScopes: ["read:user", "repo", "workflow"]))
        try AccountStore.record(GitHubAccount(id: "200", login: "fixture-bob", avatarURL: nil, oauthScopes: ["user"]))
        CredentialStore.tokens = ["100": "old-alice", "200": "old-bob"]
        AccountStore.activate("100")
        let presentation = AccountPresentation()
        presentation.showing = true
        let api = GitHub(), generation = AccountStore.generation
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CompletionProtocol.self]
        let oauthSession = URLSession(configuration: config)
        let controller = DeviceOAuthController(session: oauthSession, wait: { _ in })
        let rootReplacement = NotificationCenter.default.publisher(for: .githubAccountChanged).sink { _ in controller.cancel() }
        defer { rootReplacement.cancel() }
        CompletionProtocol.reset([
            .init(device),
            .init(#"{"access_token":"new-alice","token_type":"bearer","scope":"user,repo,workflow"}"#),
            .init(user, scopes: "user, repo, workflow")
        ])
        controller.start(clientID: "fixture-client", privateRepositories: true, writeProfile: true, api: api) {}
        try await drain(controller)
        precondition(AccountStore.activeID == "100" && AccountStore.generation != generation && !api.isCurrentSession)
        precondition(CredentialStore.tokens["100"] == "new-alice" && CredentialStore.tokens["200"] == "old-bob")
        precondition(AccountStore.accounts.first { $0.id == "100" }!.oauthScopes == ["repo", "user", "workflow"])
        precondition(GitHub().profileWriteAuthorization == true)
        precondition(!presentation.showing && presentation.authorizationNotice == nil)
        // The notice waits until the actual account sheet is gone and survives replacing the API/root.
        presentation.accountSheetDismissed()
        precondition(presentation.authorizationNotice?.contains("授权成功") == true)
        precondition(presentation.authorizationNotice?.contains("权限已确认") == true)
        let calls = CompletionProtocol.captured
        precondition(calls.map { $0.url!.host! } == ["github.com", "github.com", "api.github.com"])
        let requested = String(decoding: calls[0].httpBody!, as: UTF8.self)
        precondition(requested.contains("user%20repo%20workflow"))
        precondition(calls[0].value(forHTTPHeaderField: "Authorization") == nil && calls[1].value(forHTTPHeaderField: "Authorization") == nil)
        precondition(calls[2].value(forHTTPHeaderField: "Authorization") == "Bearer new-alice")
        precondition(calls[2].url!.path == "/user")

        // Wrong browser identities and narrowed grants never replace any saved credential.
        presentation.authorizationNotice = nil
        let savedScopes = AccountStore.accounts.first { $0.id == "100" }!.oauthScopes
        CompletionProtocol.reset([.init(other, scopes: "user")])
        let mismatch = await fail { try await GitHub().addAccount(token: "wrong-browser", expectedAccountID: "100", grantedScopes: "user") }
        precondition(mismatch.contains("账号不同") && presentation.authorizationNotice == nil)
        precondition(CredentialStore.tokens == ["100": "new-alice", "200": "old-bob"])
        CompletionProtocol.reset([.init(user, scopes: "read:user, public_repo")])
        let narrowed = await fail { try await GitHub().addAccount(token: "narrowed", expectedAccountID: "100", grantedScopes: "user") }
        precondition(narrowed.contains("未授予") && AccountStore.accounts.first { $0.id == "100" }!.oauthScopes == savedScopes)
        precondition(CredentialStore.tokens["100"] == "new-alice")

        // Missing scope metadata remains unknown; a requested checkbox never proves permission.
        CompletionProtocol.reset([.init(user)])
        try await GitHub().addAccount(token: "unknown")
        precondition(GitHub().profileWriteAuthorization == nil)
        precondition(AccountStore.accounts.first { $0.id == "100" }!.oauthScopes == nil)
        CompletionProtocol.reset([.init(user)])
        try await GitHub().addAccount(token: "response-grant", expectedAccountID: "100", grantedScopes: "user, public_repo")
        precondition(GitHub().profileWriteAuthorization == true)
        CompletionProtocol.reset([.init(user, scopes: "")])
        try await GitHub().addAccount(token: "explicit-no-scope")
        precondition(GitHub().profileWriteAuthorization == false)
        precondition(AccountStore.accounts.first { $0.id == "100" }!.oauthScopes == [])

        // The next credential resets write evidence; the same account still invalidates old requests.
        let verified = GitHub()
        verified.recordProfileWriteAuthorization(true)
        precondition(GitHub().profileWriteAuthorization == true)
        try CredentialStore.save("replacement", account: "100")
        precondition(GitHub().profileWriteAuthorization == nil)
        verified.recordProfileWriteAuthorization(false)
        precondition(GitHub().profileWriteAuthorization == false)
        AccountStore.activate("200")
        verified.recordProfileWriteAuthorization(true)
        precondition(AccountStore.accounts.first { $0.id == "100" }!.profileWriteAuthorization == false)
        precondition(GitHub().profileWriteAuthorization == true)

        // HTTP failure and a mid-request account switch cannot write credentials or success notices.
        AccountStore.activate("100"); presentation.authorizationNotice = nil
        for code in [401, 403, 201] {
            CompletionProtocol.reset([.init(code == 201 ? user : #"{"message":"Denied"}"#, code: code)])
            _ = await fail { try await GitHub().addAccount(token: "rejected") }
            precondition(CredentialStore.tokens["100"] == "replacement" && presentation.authorizationNotice == nil)
        }
        let inFlight = GitHub()
        CompletionProtocol.reset([.init(user, scopes: "user", held: true)])
        let save = Task { try await inFlight.addAccount(token: "late-result", expectedAccountID: "100") }
        let deadline = Date().addingTimeInterval(5)
        while CompletionProtocol.captured.isEmpty {
            precondition(Date() < deadline); try await Task.sleep(nanoseconds: 1_000_000)
        }
        AccountStore.activate("200"); CompletionProtocol.releaseHeld()
        do { try await save.value; preconditionFailure() } catch {}
        precondition(CredentialStore.tokens["100"] == "replacement" && CredentialStore.tokens["200"] == "old-bob")
        precondition(presentation.authorizationNotice == nil)

        print("PASS real OAuth completion stores only server grants, retains existing scopes and reports success across account-root replacement")
        print("PASS missing/narrowed grants, wrong-browser identity, failed HTTP and switched accounts preserve existing credentials")
        print("PASS current-credential write evidence resets on replacement; old-account callbacks never change another account")
    }
}
