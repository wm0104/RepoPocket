import Foundation
import Combine
struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
enum RefreshFailure { static func isCancellation(_ error: Error) -> Bool { error is CancellationError } }
// PRODUCTION_MODELS

final class DeletionFixture: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var allowed = true, graphqlError = false, wrongNode = false, wrongAck = false
    static var batches: [Int] = []
    static var writes = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.requests.append(request)
        precondition(request.url?.absoluteString == "https://api.github.com/graphql")
        precondition(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
        let object = try! JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
        let query = object["query"] as! String, variables = object["variables"] as! [String: Any]
        var payload: [String: Any]
        if query.hasPrefix("mutation") {
            Self.writes += 1
            let input = variables["input"] as! [String: String]
            precondition(input["issueId"] == "I_4")
            payload = ["data": ["deleteIssue": ["clientMutationId": Self.wrongAck ? "wrong" : input["clientMutationId"]!, "repository": ["nameWithOwner": "owner/repo"]]]]
        } else {
            let count = variables.count / 3; Self.batches.append(count)
            var nodes: [String: Any] = [:]
            for i in 0..<count {
                let number = variables["n\(i)"] as! Int
                let repo = (variables["o\(i)"] as! String) + "/" + (variables["r\(i)"] as! String)
                nodes["i\(i)"] = ["issue": ["id": Self.wrongNode ? "OTHER" : "I_\(number)", "number": number,
                    "viewerCanDelete": Self.allowed, "repository": ["nameWithOwner": repo]]]
            }
            payload = ["data": nodes]
        }
        if Self.graphqlError { payload["errors"] = [["message": "denied"]] }
        let bytes = try! JSONSerialization.data(withJSONObject: payload)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private static func body(_ request: URLRequest) -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let size = stream.read(&buffer, maxLength: buffer.count)
            if size <= 0 { break }; result.append(contentsOf: buffer.prefix(size))
        }
        return result
    }
}

@MainActor final class GitHub {
    var active = true, revokeOnCheck = false
    var accountID = "fixture"
    var accountGeneration = UUID()
    let session: URLSession
    var isCurrentSession: Bool { active }
    var issueDeletionSession: IssueDeletionSession { .init(accountID: accountID, generation: accountGeneration) }
    init() {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DeletionFixture.self]
        session = URLSession(configuration: config)
    }
    private func ensureActiveAccount() throws { if !active { throw CancellationError() } }
    private func url(_ path: String) -> URL { URL(string: "https://api.github.com" + path)! }
    private func request(_ url: URL, method: String, body: Data) throws -> URLRequest {
        try ensureActiveAccount()
        var result = URLRequest(url: url); result.httpMethod = method; result.httpBody = body
        result.setValue("Bearer fixture-only", forHTTPHeaderField: "Authorization"); return result
    }
    private func check(_ bytes: Data, _ response: URLResponse, operation: String) throws {
        if revokeOnCheck { active = false }
        try ensureActiveAccount()
        precondition((response as! HTTPURLResponse).statusCode == 200)
    }
    // PRODUCTION_TRANSPORT
}
// PRODUCTION_CODE

@main struct Run {
    static func item(_ n: Int = 4, repo: String = "owner/repo") -> CollaborationItem {
        let object: [String: Any] = ["id": n + 600, "number": n, "title": "issue \(n)", "state": "open", "html_url": "https://github.com/\(repo)/issues/\(n)"]
        return try! JSONDecoder().decode(CollaborationItem.self, from: JSONSerialization.data(withJSONObject: object))
    }
    @MainActor static func settle(_ state: IssueDeletionState) async {
        while !state.checking.isEmpty { await Task.yield() }
    }
    @MainActor static func main() async throws {
        let api = GitHub(); defer { api.session.invalidateAndCancel() }
        let issue = item(), subject = IssueDeletionSubject(issue, repo: "owner/repo")!
        precondition(IssueDeletionSubject(issue, repo: "other/repo") == nil)
        do { _ = try IssueDeletionRules.permissionQuery([]); preconditionFailure() } catch {}
        do { _ = try IssueDeletionRules.permissionQuery([subject, subject]); preconditionFailure() } catch {}
        DeletionFixture.allowed = false
        let denied = try await api.issueDeletionGrants([subject]); precondition(denied.isEmpty && DeletionFixture.writes == 0)
        DeletionFixture.allowed = true
        let grant = try await api.issueDeletionGrants([subject])[subject.key]!
        precondition(grant.nodeID == "I_4" && DeletionFixture.writes == 0)
        let target = IssueDeletionConfirmation(grant: grant, session: api.issueDeletionSession)
        DeletionFixture.allowed = false
        do { try await api.deleteIssue(target); preconditionFailure() } catch {}
        precondition(DeletionFixture.writes == 0)
        DeletionFixture.allowed = true; DeletionFixture.wrongNode = true
        do { try await api.deleteIssue(target); preconditionFailure() } catch {}
        precondition(DeletionFixture.writes == 0)
        DeletionFixture.wrongNode = false; DeletionFixture.graphqlError = true
        do { _ = try await api.issueDeletionGrants([subject]); preconditionFailure() } catch {}
        DeletionFixture.graphqlError = false
        let before = DeletionFixture.requests.count
        api.accountGeneration = UUID()
        do { try await api.deleteIssue(target); preconditionFailure() } catch {}
        precondition(DeletionFixture.requests.count == before)
        let current = IssueDeletionConfirmation(grant: grant, session: api.issueDeletionSession)
        api.revokeOnCheck = true
        do { try await api.deleteIssue(current); preconditionFailure() } catch {}
        precondition(DeletionFixture.writes == 0)
        api.revokeOnCheck = false; api.active = true
        let store = IssueDeletionState()
        DeletionFixture.batches = []
        let subjects = (1...65).map { IssueDeletionSubject(item($0), repo: "owner/repo")! }
        store.load(subjects, api: api); await settle(store)
        precondition(DeletionFixture.batches == [30,30,5] && store.grants.count == 65)
        let count = DeletionFixture.requests.count
        store.load(subjects, api: api); await settle(store)
        precondition(DeletionFixture.requests.count == count, "Scrolling/repeated appearance must reuse permissions")
        DeletionFixture.wrongAck = true
        do { try await store.remove(current, api: api); preconditionFailure() } catch {}
        precondition(!store.deleted.contains(issue.id) && store.failed.contains(subject.key) && store.grants[subject.key] == nil)
        DeletionFixture.wrongAck = false
        store.load([subject], api: api, retry: true); await settle(store)
        precondition(store.grants[subject.key] != nil && !store.failed.contains(subject.key))
        let writes = DeletionFixture.writes
        try await store.remove(current, api: api)
        precondition(DeletionFixture.writes == writes + 1 && store.deleted.contains(issue.id))
        precondition(store.visible([issue,item(5)]).map(\.number) == [5])
        precondition(store.visible([issue,item(5)], kind: .pulls).map(\.number) == [4,5], "Issue REST IDs must never hide same-ID pull requests")
        do { try await store.remove(current, api: api); preconditionFailure() } catch {}
        precondition(DeletionFixture.writes == writes + 1)
        store.resetPermissions(); precondition(store.grants.isEmpty && store.deleted.contains(issue.id))
        for bad in ["{}", "{\"data\":null}", "{\"data\":{\"deleteIssue\":null}}"] {
            do { try IssueDeletionRules.acknowledge(Data(bad.utf8), subject: subject, requestID: "test"); preconditionFailure() } catch {}
        }
        let mismatch = Data(#"{"data":{"i0":{"issue":{"id":"I_4","number":4,"viewerCanDelete":true,"repository":{"nameWithOwner":"wrong/repo"}}}}}"#.utf8)
        do { _ = try IssueDeletionRules.grants(mismatch, subjects: [subject]); preconditionFailure() } catch {}
        print("PASS production issue permissions, account-bound transport, batch cache, identity revalidation, failed ack retention and confirmed deletion; isolated URLProtocol only")
    }
}
