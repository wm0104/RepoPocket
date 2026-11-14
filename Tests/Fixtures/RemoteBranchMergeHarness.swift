import Foundation
import Combine

struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
enum AccountStore {
    static var activeID = "fixture"
    static var generation = UUID()
}
enum CredentialStore { static func read(account: String) -> String { "fixture-token-not-a-secret" } }

// PRODUCTION_CODE

@MainActor
final class GitHub: ObservableObject {
    private let accountID = AccountStore.activeID
    private let accountGeneration = AccountStore.generation
    private let session: URLSession
    var isCurrentSession: Bool { AccountStore.activeID == accountID && AccountStore.generation == accountGeneration }
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        config.urlCache = nil
        session = URLSession(configuration: config)
    }
    // PRODUCTION_URL
    // PRODUCTION_REQUEST
    // PRODUCTION_ACCOUNT
    // PRODUCTION_CHECK
    // PRODUCTION_TRANSPORT
}

final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var seen: [URLRequest] = []
    static var reply: ((URLRequest) throws -> (Int, Any))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.seen.append(request); let handler = Self.reply!; Self.lock.unlock()
        do {
            precondition(request.url?.host == "api.github.com", "no external hosts")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token-not-a-secret")
            let (code, object) = try handler(request)
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "Content-Length": String(bytes.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func install(_ handler: @escaping (URLRequest) throws -> (Int, Any)) {
        lock.lock(); seen = []; reply = handler; lock.unlock()
    }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    static func body(_ r: URLRequest) throws -> [String: Any] {
        var bytes = r.httpBody ?? Data()
        if bytes.isEmpty, let stream = r.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
        }
        return try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    }
}

final class Scenario: @unchecked Sendable {
    static let head = String(repeating: "a", count: 40), base = String(repeating: "b", count: 40), merged = String(repeating: "c", count: 40)
    var head = Scenario.head, base = Scenario.base
    var push = true, squash = true, draft = false, mergeable: Bool? = true
    var deleteBranchOnMerge: Bool? = false
    var sourceDeletedAfterMerge = false
    var mergeState = "clean", prState = "open", isMerged = false
    var headRepo = "sample/project", baseRepo = "sample/project", source = "feature/topic", target = "main"
    var status = "success", runStatus = "completed", conclusion: String? = "success"
    var zeroChecks = false, statusPages = false, runPages = false, unreadable = "", duplicateRuns = false
    var createUnknown = false, mergeUnknown = false, mergedResponse = true, wrongVerification = false
    var existing = true, filesLimit = false, brokenCommitPage = false, unstableHead = false
    var switchPath = "", cancelPath = ""
    var switchGeneration = false
    var branchReads = 0
    var onPath: ((String) -> Void)?
    func pr() -> [String: Any] {
        ["number": 7, "head": ["ref": source, "sha": head, "repo": ["full_name": headRepo]],
         "base": ["ref": target, "sha": base, "repo": ["full_name": baseRepo]],
         "state": prState, "draft": draft, "merged": isMerged,
         "mergeable": mergeable.map { $0 as Any } ?? NSNull(), "mergeable_state": mergeState,
         "merge_commit_sha": isMerged ? (wrongVerification ? Scenario.base : Scenario.merged) as Any : NSNull()]
    }
    func handle(_ r: URLRequest) throws -> (Int, Any) {
        let path = r.url!.path, method = r.httpMethod ?? "GET"
        let query = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let page = Int(query.first(where: { $0.name == "page" })?.value ?? "1")!
        onPath?(path)
        if !switchPath.isEmpty, path.hasSuffix(switchPath) {
            if switchGeneration { AccountStore.generation = UUID() } else { AccountStore.activeID = "other" }
        }
        if !unreadable.isEmpty && path.hasSuffix(unreadable) { return (403, ["message": "fixture denied"]) }
        if path.contains("/branches/") {
            branchReads += 1
            let name = path.components(separatedBy: "/branches/")[1]
            if isMerged, sourceDeletedAfterMerge, name == source { return (404, ["message": "source ref deleted"]) }
            let sha = name == source ? head : base
            return (200, ["name": name, "commit": ["sha": unstableHead && branchReads >= 3 ? Scenario.merged : sha]])
        }
        if path.contains("/compare/") {
            let commit: [String: Any] = ["sha": head, "commit": ["message": "fixture commit"]]
            let file: [String: Any] = ["filename": "a.txt", "status": "modified", "additions": 1, "deletions": 1, "patch": "@@ -1 +1 @@\n-old\n+new"]
            return (200, ["base_commit": ["sha": base], "total_commits": brokenCommitPage ? 2 : 1, "ahead_by": 1,
                "commits": brokenCommitPage && page > 1 ? [] : [commit], "files": filesLimit ? Array(repeating: file, count: 300) : [file]])
        }
        if path.hasSuffix("/status") {
            let values: [[String: Any]] = zeroChecks ? [] : (statusPages ? (page == 1 ? (1...100).map { ["context": "c\($0)", "state": "success"] } : [["context": "last", "state": status]]) : [["context": "ci", "state": status]])
            return (200, ["sha": head, "total_count": zeroChecks ? 0 : (statusPages ? 101 : 1), "statuses": values])
        }
        if path.hasSuffix("/check-runs") {
            precondition(query.contains(where: { $0.name == "filter" && $0.value == "latest" }))
            func run(_ id: Int, _ last: Bool) -> [String: Any] {
                ["id": duplicateRuns ? 1 : id, "head_sha": head, "name": "check\(id)",
                 "status": last ? runStatus : "completed", "conclusion": last ? (conclusion.map { $0 as Any } ?? NSNull()) : "success"]
            }
            let values = zeroChecks ? [] : (runPages ? (page == 1 ? (1...100).map { run($0, false) } : [run(101, true)]) : [run(1, true)])
            return (200, ["total_count": zeroChecks ? 0 : (runPages ? 101 : 1), "check_runs": values])
        }
        if path.hasSuffix("/pulls/7/merge") {
            precondition(method == "PUT")
            let body = try FixtureProtocol.body(r)
            precondition(Set(body.keys) == ["sha", "merge_method", "commit_title"])
            precondition(body["sha"] as? String == Scenario.head && body["merge_method"] as? String == "squash")
            precondition(body["commit_title"] as? String == "Frozen title")
            if mergeUnknown { throw URLError(.networkConnectionLost) }
            if mergedResponse { isMerged = true; prState = "closed" }
            return (200, ["merged": mergedResponse, "sha": Scenario.merged])
        }
        if path.hasSuffix("/pulls/7") { precondition(method == "GET"); return (200, pr()) }
        if path.hasSuffix("/pulls") {
            if method == "POST" {
                let body = try FixtureProtocol.body(r)
                precondition(body["head"] as? String == source && body["base"] as? String == target)
                precondition(body["title"] as? String == "Frozen title")
                if createUnknown { existing = true; throw URLError(.timedOut) }
                existing = true; return (201, pr())
            }
            precondition(method == "GET")
            return (200, existing ? [pr()] : [])
        }
        if path == "/repos/sample/project" {
            return (200, ["full_name": "sample/project", "permissions": ["push": push], "allow_squash_merge": squash,
                "delete_branch_on_merge": deleteBranchOnMerge.map { $0 as Any } ?? NSNull()])
        }
        throw AppError(text: "Unexpected fixture route: \(method) \(path)")
    }
}

struct GitHubMessage: Decodable { let message: String }
struct GitHubAPIError: LocalizedError {
    let status: Int; let operation: String; let reason: String; let permissions: String?
    var errorDescription: String? { "\(operation): \(status) \(reason)" }
}

@main
struct Harness {
    @MainActor static func main() async throws {
        var passed = 0
        func fresh(_ scenario: Scenario) -> GitHub {
            AccountStore.activeID = "fixture"; AccountStore.generation = UUID()
            FixtureProtocol.install { try scenario.handle($0) }
            return GitHub()
        }
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); passed += 1
        }
        func writes(_ method: String? = nil) -> [URLRequest] {
            FixtureProtocol.requests().filter { ($0.httpMethod ?? "GET") != "GET" && (method == nil || $0.httpMethod == method) }
        }
        func denied(_ action: () async throws -> Void) async {
            do { try await action(); preconditionFailure("unsafe operation accepted") } catch { passed += 1 }
        }
        func preview(_ api: GitHub) async throws -> RemoteBranchMergePreview {
            try await api.remoteBranchMergePreview(repo: "sample/project", source: "feature/topic", target: "main")
        }
        do {
            let s = Scenario(), api = fresh(s), p = try await preview(api)
            check(p.sourceSHA == Scenario.head && p.targetSHA == Scenario.base && p.files.first?.patch?.contains("+new") == true, "exact preview and patch")
            check(FixtureProtocol.requests().contains { $0.url!.path.contains(Scenario.base + "..." + Scenario.head) }, "SHA-pinned comparison")
            check(writes().isEmpty, "preview cannot create PR")
            let gate = try await api.remoteBranchMergeGate(p, number: 7)
            check(gate.statusCount == 1 && gate.checkRunCount == 1, "both check systems")
        }
        do {
            let api = fresh(Scenario())
            await denied { _ = try await api.remoteBranchMergePreview(repo: "sample/project", source: "main", target: "main") }
            check(FixtureProtocol.requests().isEmpty, "same branch rejected before network")
        }
        for configure in ([{ $0.filesLimit = true }, { $0.brokenCommitPage = true }, { $0.unstableHead = true }] as [(Scenario) -> Void]) {
            let s = Scenario(); configure(s); let api = fresh(s)
            await denied { _ = try await preview(api) }
            check(writes().isEmpty, "incomplete/stale preview blocks writes")
        }
        for value in ["failure", "error", "pending", "unknown", ""] {
            let s = Scenario(); s.status = value; let api = fresh(s), p = try await preview(api)
            await denied { _ = try await api.remoteBranchMergeGate(p, number: 7) }
            check(writes().isEmpty, "bad status never writes")
        }
        for value in (["failure", "cancelled", "timed_out", "action_required", "neutral", "skipped", "stale", "unknown", nil] as [String?]) {
            let s = Scenario(); s.conclusion = value; let api = fresh(s), p = try await preview(api)
            await denied { _ = try await api.remoteBranchMergeGate(p, number: 7) }
        }
        do {
            let s = Scenario(); s.runStatus = "in_progress"; let api = fresh(s), p = try await preview(api)
            await denied { _ = try await api.remoteBranchMergeGate(p, number: 7) }
        }
        for configure in ([
            { $0.push = false }, { $0.squash = false }, { $0.deleteBranchOnMerge = true }, { $0.deleteBranchOnMerge = nil },
            { $0.draft = true }, { $0.mergeable = nil },
            { $0.mergeable = false }, { $0.mergeState = "blocked" }, { $0.mergeState = "unstable" },
            { $0.mergeState = "unknown" }, { $0.prState = "closed" }, { $0.isMerged = true },
            { $0.headRepo = "outsider/project" }, { $0.baseRepo = "outsider/project" },
            { $0.source = "different" }, { $0.target = "different" }
        ] as [(Scenario) -> Void]) {
            let s = Scenario(), api = fresh(s), p = try await preview(api); configure(s)
            await denied { _ = try await api.remoteBranchMergeGate(p, number: 7) }
            check(writes().isEmpty, "permissions/reviews/PR binding fail closed")
        }
        for path in ["/status", "/check-runs"] {
            let s = Scenario(), api = fresh(s), p = try await preview(api); s.unreadable = path
            await denied { _ = try await api.remoteBranchMergeGate(p, number: 7) }
        }
        do {
            let s = Scenario(); s.statusPages = true; s.runPages = true
            let api = fresh(s), p = try await preview(api)
            let value = try await api.remoteBranchMergeGate(p, number: 7)
            check(value.statusCount == 101 && value.checkRunCount == 101, "complete pagination")
            s.status = "pending"
            await denied { _ = try await api.remoteBranchMergeGate(p, number: 7) }
            s.status = "success"; s.conclusion = "failure"
            await denied { _ = try await api.remoteBranchMergeGate(p, number: 7) }
            s.conclusion = "success"; s.duplicateRuns = true
            await denied { _ = try await api.remoteBranchMergeGate(p, number: 7) }
        }
        do {
            let s = Scenario(); s.zeroChecks = true; let api = fresh(s), p = try await preview(api)
            let value = try await api.remoteBranchMergeGate(p, number: 7)
            check(value.summary.contains("没有配置检查，不代表成功") && value.statusCount == 0 && value.checkRunCount == 0, "honest zero-check explanation")
        }
        for generation in [false, true] {
            let s = Scenario(), api = fresh(s), p = try await preview(api)
            s.switchPath = "/status"; s.switchGeneration = generation
            await denied { _ = try await api.remoteBranchMergeGate(p, number: 7) }
            check(writes().isEmpty && !FixtureProtocol.requests().contains { $0.url!.path.hasSuffix("/check-runs") }, "post-auth session validation")
        }
        do {
            let s = Scenario(), api = fresh(s), p = try await preview(api)
            let task = Task { () throws -> Void in
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try await api.remoteBranchMergeGate(p, number: 7)
            }
            await denied { try await task.value }
            check(writes().isEmpty, "cancelled operation cannot write")
        }
        do {
            let s = Scenario(), api = fresh(s), state = RemoteBranchMergeState()
            await state.load(api: api, repo: "sample/project", source: s.source, target: s.target)
            await state.preparePull(api: api, title: "Frozen title")
            check(state.pull?.number == 7 && writes().isEmpty, "reuse exact same-repo open PR")
            await state.refreshGate(api: api, title: "Frozen title")
            let frozen = state.confirmation!
            check(frozen.title == "Frozen title" && frozen.session == api.remoteBranchMergeSession && writes().isEmpty, "first confirmation never merges")
            await state.submit(api: api, confirmation: frozen)
            await state.submit(api: api, confirmation: frozen)
            check(writes("PUT").count == 1 && state.result.contains(Scenario.merged), "second explicit confirmation, one squash write, fresh verification")
            let requests = FixtureProtocol.requests()
            check(requests.contains { $0.httpMethod == "GET" && $0.url?.path.hasSuffix("/pulls/7") == true } &&
                  requests.last?.httpMethod == "GET" && requests.last?.url?.path.hasSuffix("/branches/" + s.source) == true,
                  "success requires fresh PR and retained source ref reads")
            check(!requests.contains { $0.httpMethod == "DELETE" || $0.url!.path.contains("/actions/") || $0.url!.path.contains("/git/refs") }, "source retained and no Actions writes")
        }
        do {
            let s = Scenario(); s.existing = false; let api = fresh(s), state = RemoteBranchMergeState()
            await state.load(api: api, repo: "sample/project", source: s.source, target: s.target)
            check(writes().isEmpty, "preview does not auto-create")
            await state.preparePull(api: api, title: "Frozen title")
            check(writes("POST").count == 1 && state.pull?.number == 7 && writes("PUT").isEmpty, "explicit create only, no automatic merge")
        }
        do {
            let s = Scenario(); s.existing = false; s.createUnknown = true
            let api = fresh(s), state = RemoteBranchMergeState()
            await state.load(api: api, repo: "sample/project", source: s.source, target: s.target)
            await state.preparePull(api: api, title: "Frozen title")
            await state.preparePull(api: api, title: "Frozen title")
            await state.load(api: api, repo: "sample/project", source: s.source, target: s.target)
            await state.reconcile(api: api)
            check(writes("POST").count == 1 && writes("PUT").isEmpty && state.readOnly && state.pull?.number == 7, "unknown POST reconciles read-only without retry")
        }
        for configure in ([{ $0.mergeUnknown = true }, { $0.mergedResponse = false }, { $0.wrongVerification = true }, { $0.sourceDeletedAfterMerge = true }] as [(Scenario) -> Void]) {
            let s = Scenario(), api = fresh(s), state = RemoteBranchMergeState()
            await state.load(api: api, repo: "sample/project", source: s.source, target: s.target)
            await state.preparePull(api: api, title: "Frozen title")
            await state.refreshGate(api: api, title: "Frozen title")
            let frozen = state.confirmation!; configure(s)
            await state.submit(api: api, confirmation: frozen)
            check(state.result.isEmpty && state.readOnly && !state.failure.isEmpty, "unknown/false/unverified response not success")
            await state.submit(api: api, confirmation: frozen)
            await state.refreshGate(api: api, title: "Frozen title")
            await state.reconcile(api: api)
            check(writes("PUT").count == 1, "uncertain PUT never automatically repeated")
        }
        for changeBase in [false, true] {
            let s = Scenario(), api = fresh(s), state = RemoteBranchMergeState()
            await state.load(api: api, repo: "sample/project", source: s.source, target: s.target)
            await state.preparePull(api: api, title: "Frozen title")
            await state.refreshGate(api: api, title: "Frozen title")
            let frozen = state.confirmation!
            if changeBase { s.base = Scenario.merged } else { s.head = Scenario.merged }
            await state.submit(api: api, confirmation: frozen)
            check(writes().isEmpty && !state.failure.isEmpty, "heads revalidated immediately before write")
        }
        do {
            let s = Scenario(), api = fresh(s), state = RemoteBranchMergeState()
            await state.load(api: api, repo: "sample/project", source: s.source, target: s.target)
            await state.preparePull(api: api, title: "Frozen title")
            await state.refreshGate(api: api, title: "Frozen title")
            let frozen = state.confirmation!
            state.invalidate()
            await state.submit(api: api, confirmation: frozen)
            check(writes().isEmpty, "dismissed view/session confirmation cannot be reused")
        }
        do {
            let s = Scenario(), api = fresh(s), p = try await preview(api)
            s.headRepo = "fork/project"
            let value = try await api.remoteBranchMergeExisting(p)
            check(value == nil && writes().isEmpty, "fork PR never reused")
        }
        do {
            let s = Scenario(), api = fresh(s), p = try await preview(api)
            var payload = s.pr(); payload["draft"] = NSNull()
            let pr = try JSONDecoder().decode(RemoteBranchMergePR.self, from: JSONSerialization.data(withJSONObject: payload))
            check(!RemoteBranchMergeRules.prReasons(pr, p).isEmpty, "unknown draft blocks")
            payload["draft"] = false; payload["merged"] = NSNull()
            let unknown = try JSONDecoder().decode(RemoteBranchMergePR.self, from: JSONSerialization.data(withJSONObject: payload))
            check(!RemoteBranchMergeRules.prReasons(unknown, p).isEmpty, "unknown merged blocks")
        }
        do {
            _ = fresh(Scenario())
            let policy = RemoteBranchMergeBudget()
            let task = URLSession.shared.dataTask(with: URL(string: "https://api.github.com")!)
            let response = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
            var called = false
            policy.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: "https://example.invalid")!)) { request in called = true; precondition(request == nil) }
            check(called, "all redirects refused")
            let download = URLSession.shared.downloadTask(with: URL(string: "https://api.github.com")!)
            policy.urlSession(URLSession.shared, downloadTask: download, didWriteData: 1,
                totalBytesWritten: Int64(RemoteBranchMergeBudget.limit + 1), totalBytesExpectedToWrite: -1)
            check(download.state == .canceling || download.state == .completed, "stream budget cancels task before oversized load")
        }
        print("PASS \(passed) production remote PR assertions: exact diff, both paginated check systems, permissions/rules, sessions/cancel, reuse/create, frozen squash, fresh verification, unknown-write read-only reconciliation; no live writes")
    }
}
