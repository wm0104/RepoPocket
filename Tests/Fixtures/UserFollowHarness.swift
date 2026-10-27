import Foundation
import Combine
struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
enum AccountStore {
    static var activeID = "A", generation = UUID()
    struct Account { let id: String; let login: String }
    static let accounts = [Account(id: "A", login: "viewer")]
}
enum CredentialStore {
    static var token = "fixture-only"
    static func read(account: String) -> String { token }
}
final class OfficialUpdateRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor final class GitHub {
    let accountID = AccountStore.activeID, generation = AccountStore.generation
    var login = "viewer"
    var isCurrentSession: Bool { accountID == AccountStore.activeID && generation == AccountStore.generation }
    let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FollowProtocol.self]
        session = URLSession(configuration: config)
    }
    private func ensureActiveAccount() throws { guard isCurrentSession else { throw CancellationError() } }
    static func component(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    private func url(_ path: String) throws -> URL { URL(string: "https://api.github.com" + path)! }
    // PRODUCTION_API
}
// PRODUCTION_STORE
struct DeviceAuthorization: Decodable {
    let device_code: String, user_code: String, verification_uri: String
    let expires_in: Int
    let interval: Int?
}
// BEGIN_OAUTH_RULES
// PRODUCTION_OAUTH_RULES

final class FollowProtocol: URLProtocol {
    static let lock = NSLock()
    static var followed = false, readCode: Int? = nil, writeCode = 204, delay: TimeInterval = 0
    static var reads = 0, writes: [String] = []
    static var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method = request.httpMethod ?? ""
        precondition(request.url?.host == "api.github.com")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
        precondition(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        Self.lock.lock()
        let code: Int
        if method == "GET" {
            precondition(request.url?.path == "/users/viewer/following/target")
            Self.reads += 1; code = Self.readCode ?? (Self.followed ? 204 : 404)
        } else {
            precondition(request.url?.path == "/user/following/target")
            precondition(["PUT", "DELETE"].contains(method))
            precondition(request.value(forHTTPHeaderField: "Content-Length") == "0")
            Self.writes.append(method); code = Self.writeCode
            if code == 204 { Self.followed = method == "PUT" }
        }
        let delay = Self.delay; Self.lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct FollowTests {
    @MainActor static func main() async throws {
        let api = GitHub(), store = UserFollowStore(api: GitHub())
        _ = store // weak API ownership must not crash after the owner is released
        for code in [200, 201, 301, 401, 403, 429, 500] {
            do { _ = try UserFollowRules.status(code, checking: true); fatalError("unexpected accepted read") } catch {}
        }
        do { _ = try UserFollowRules.status(404, checking: false); fatalError() } catch {}
        for login in ["", "../target", "a/b", "中文", String(repeating: "a", count: 40)] {
            do { _ = try UserFollowRules.login(login); fatalError() } catch {}
        }
        precondition(DeviceOAuthRules.scope(privateRepositories: false, followUsers: false) == "read:user public_repo")
        precondition(DeviceOAuthRules.scope(privateRepositories: true, followUsers: true) == "read:user repo user:follow")
        precondition(DeviceOAuthRules.scope(privateRepositories: false, followUsers: true) == "read:user public_repo user:follow")
        precondition(DeviceOAuthRules.scope(privateRepositories: true, followUsers: false, writeProfile: false) == "read:user repo")
        precondition(DeviceOAuthRules.scope(privateRepositories: false, followUsers: false, writeProfile: true) == "user public_repo")
        precondition(DeviceOAuthRules.scope(privateRepositories: true, followUsers: false, writeProfile: true) == "user repo")
        precondition(DeviceOAuthRules.scope(privateRepositories: false, followUsers: true, writeProfile: true) == "user public_repo user:follow")
        precondition(DeviceOAuthRules.scope(privateRepositories: true, followUsers: true, writeProfile: true) == "user repo user:follow")
        let state = UserFollowStore(api: api)
        CredentialStore.token = ""
        do { _ = try await state.load("target"); fatalError() } catch {}
        precondition(FollowProtocol.reads == 0)
        CredentialStore.token = "fixture-only"
        do { _ = try await state.load("VIEWER"); fatalError() } catch {}
        do { _ = try await api.followRequest("target", method: "POST"); fatalError() } catch {}
        FollowProtocol.delay = 0.03
        async let a = state.load("target")
        async let b = state.load("TARGET")
        let pair = try await (a, b)
        precondition(!pair.0 && !pair.1 && FollowProtocol.reads == 1)
        let reads = FollowProtocol.reads
        _ = try await state.load("target"); precondition(FollowProtocol.reads == reads)
        async let first: Void = state.setFollowing("target", desired: true)
        async let duplicate: Void = state.setFollowing("target", desired: true)
        _ = try await (first, duplicate)
        precondition(state.known("target") == true && FollowProtocol.writes == ["PUT"])
        FollowProtocol.writeCode = 403
        do { try await state.setFollowing("target", desired: false); fatalError() } catch {}
        precondition(state.known("target") == true)
        FollowProtocol.writeCode = 200
        do { try await state.setFollowing("target", desired: false); fatalError() } catch {}
        precondition(state.known("target") == true)
        FollowProtocol.writeCode = 204
        try await state.setFollowing("target", desired: false)
        precondition(state.known("target") == false)
        let before = FollowProtocol.writes.count
        FollowProtocol.readCode = 401
        do { try await state.setFollowing("target", desired: true); fatalError() } catch {}
        precondition(FollowProtocol.writes.count == before && state.known("target") == false)
        state.invalidate()
        do { _ = try await state.load("target"); fatalError() } catch {}
        precondition(state.known("target") == nil)
        FollowProtocol.readCode = nil
        // A cancelled first caller must not strand shared state or another profile's waiter.
        FollowProtocol.delay = 0.15
        let beforeCancellation = FollowProtocol.readCount
        let caller = Task { try await state.load("target") }
        while FollowProtocol.readCount == beforeCancellation { await Task.yield() }
        caller.cancel()
        let second = try await state.load("target")
        _ = try? await caller.value
        precondition(!second && state.known("target") == false && FollowProtocol.readCount == beforeCancellation + 1)
        // Reads during writes must not create stale responses capable of overwriting 204.
        let mutation = Task { try await state.setFollowing("target", desired: true) }
        while !state.isBusy("target") { await Task.yield() }
        _ = try await state.load("target", refresh: true)
        try await mutation.value
        precondition(state.known("target") == true)
        state.invalidate()
        FollowProtocol.delay = 0.1
        let old = Task { try await state.load("target") }
        try await Task.sleep(nanoseconds: 10_000_000)
        AccountStore.generation = UUID(); state.invalidate()
        do { _ = try await old.value; fatalError() } catch {}
        precondition(state.known("target") == nil)
        let count = FollowProtocol.writes.count
        do { try await state.setFollowing("target", desired: true); fatalError() } catch {}
        precondition(FollowProtocol.writes.count == count)
        print("PASS production follow endpoint headers, scopes, exact acknowledgement, dedup, failure, cancellation, account and read/write races")
    }
}
