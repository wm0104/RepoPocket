import Foundation

enum RemoteHistoryBackup {
    struct Record {
        let original: RemoteHistoryPreview
        var phase = "backed-up"
        var newHead: String?
        func preview(generation: UUID) -> RemoteHistoryPreview {
            let old = original.snapshot
            let snapshot = RemoteHistorySnapshot(accountID: old.accountID, generation: generation, repository: old.repository,
                repositoryID: old.repositoryID, branch: old.branch, head: old.head, commits: old.commits)
            return .init(snapshot: snapshot, action: original.action, selected: original.selected, steps: original.steps,
                resultKey: original.resultKey, versions: original.versions, baseline: original.baseline)
        }
    }
    static var events: [String] = []
    static var stored: (folder: URL, record: Record)?
    static var failPrepare = false
    static func reset() { events = []; stored = nil; failPrepare = false }
    static func latest(accountID: String, repo: String, branch: String) -> (folder: URL, record: Record)? { stored }
    @MainActor static func prepare(_ preview: RemoteHistoryPreview, api: GitHub) async throws -> URL {
        if failPrepare { throw AppError(text: "fixture backup failure") }
        events.append("backup")
        let folder = URL(fileURLWithPath: "/fixture/original-history")
        stored = (folder, Record(original: preview))
        return folder
    }
    static func update(_ folder: URL, preview: RemoteHistoryPreview, resolved: [String: String], newHead: String, phase: String) throws {
        precondition(stored != nil)
        if phase == "objects-verified" { precondition(preview.steps.allSatisfy { resolved[$0.key] != nil }) }
        events.append(phase); stored?.record.phase = phase; stored?.record.newHead = newHead
    }
}

final class OperationsScenario: @unchecked Sendable {
    let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40), c = String(repeating: "c", count: 40)
    let tree = String(repeating: "f", count: 40), mergedSHA = String(repeating: "9", count: 40)
    var currentHead = String(repeating: "c", count: 40)
    var base = String(repeating: "b", count: 40)
    var baseRef = "main", headRef = "feature"
    var baseRepository = "fixture/repository", headRepository = "fixture/repository"
    var merged = false
    var mergeState = "CLEAN"
    var review: String? = nil
    var allowed = true
    var repositoryID = "R_fixture"
    var replaceAfterCreating = false
    var push = true
    var race = false
    var rejectionShape = "known", rejectionStatus = 200
    var loseReply = false
    var applyBeforeLosingReply = true
    var created: [String: [String: Any]] = [:]
    var corruptCreated = ""
    var published = 0
    var merges: [String] = []
    var repository: [String: Any] {
        ["node_id": repositoryID, "full_name": "fixture/repository", "default_branch": "main",
         "permissions": ["push": push], "allow_merge_commit": allowed, "allow_squash_merge": allowed, "allow_rebase_merge": allowed]
    }
    func pull() -> [String: Any] {
        ["number": 7, "state": merged ? "closed" : "open", "draft": false, "merged": merged,
         "mergeable": true, "mergeable_state": "clean", "rebaseable": true,
         "merge_commit_sha": merged ? mergedSHA as Any : NSNull() as Any,
          "head": ["ref": headRef, "sha": currentHead, "repo": ["full_name": headRepository]],
          "base": ["ref": baseRef, "sha": base, "repo": ["full_name": baseRepository]]]
    }
    func history() -> [[String: Any]] {
        let author = ["name": "Fixture", "email": "fixture@example.test", "date": "2026-11-13T00:00:00Z"]
        var chain = [(c, b), (b, a), (a, "")]
        if currentHead == String(repeating: "8", count: 40) { chain.insert((currentHead, c), at: 0) }
        return chain.map { sha, parent in
            ["sha": sha, "commit": ["message": "commit-" + String(sha.prefix(1)), "tree": ["sha": tree], "author": author, "committer": author],
             "parents": parent.isEmpty ? [] : [["sha": parent]]]
        }
    }
    func respond(_ request: URLRequest) throws -> (Int, Any) {
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        if path == "/repos/fixture/repository", method == "GET" { return (200, repository) }
        if path == "/repos/fixture/repository/git/ref/heads/main" { return (200, ["object": ["sha": currentHead]]) }
        if path == "/repos/fixture/repository/commits", method == "GET" { return (200, history()) }
        if path == "/repos/fixture/repository/git/commits", method == "POST" {
            precondition(RemoteHistoryBackup.events.contains("backup"), "No object creation before the original-history backup")
            let body = try FixtureProtocol.body(request)
            let sha = String(repeating: String(created.count + 1), count: 40)
            precondition(body["tree"] as? String == tree)
            precondition(body["parents"] is [String])
            created[sha] = ["sha": sha, "tree": ["sha": body["tree"]!], "message": body["message"]!,
                            "parents": (body["parents"] as! [String]).map { ["sha": $0] }]
            if replaceAfterCreating { repositoryID = "R_replaced" }
            return (201, ["sha": sha])
        }
        if path.hasPrefix("/repos/fixture/repository/git/commits/"), method == "GET" {
            let sha = request.url!.lastPathComponent
            if var object = created[sha] {
                if corruptCreated == "tree" { object["tree"] = ["sha": String(repeating: "e", count: 40)] }
                if corruptCreated == "message" { object["message"] = "unexpected message" }
                if corruptCreated == "parents" { object["parents"] = [["sha": String(repeating: "e", count: 40)]] }
                return (200, object)
            }
            return (200, ["tree": ["sha": tree]])
        }
        if path == "/repos/fixture/repository/pulls/7", method == "GET" { return (200, pull()) }
        if path == "/repos/fixture/repository/pulls/7/merge", method == "PUT" {
            let body = try FixtureProtocol.body(request)
            let value = body["merge_method"] as! String
            precondition(["merge", "squash", "rebase"].contains(value))
            precondition(body["sha"] as? String == currentHead)
            if value == "rebase" { precondition(body["commit_title"] == nil && body["commit_message"] == nil) }
            merges.append(value)
            if loseReply {
                if applyBeforeLosingReply { merged = true }
                throw URLError(.networkConnectionLost)
            }
            merged = true
            return (200, ["merged": true, "sha": mergedSHA, "message": "merged"])
        }
        if path == "/graphql", method == "POST" {
            let body = try FixtureProtocol.body(request), query = body["query"] as! String
            if query.hasPrefix("query") {
                return (200, ["data": ["repository": ["pullRequest": ["mergeStateStatus": mergeState,
                    "reviewDecision": review as Any? ?? NSNull(), "headRefOid": currentHead, "baseRefOid": base]]]])
            }
            precondition(query.contains("updateRefs(input:"))
            precondition(RemoteHistoryBackup.events.last == "update-requested")
            let variables = body["variables"] as! [String: Any], input = variables["input"] as! [String: Any]
            let updates = input["refUpdates"] as! [[String: Any]]
            precondition(updates.count == 1 && updates[0]["name"] as? String == "refs/heads/main")
            precondition(input["repositoryId"] as? String == "R_fixture")
            precondition(updates[0]["force"] as? Bool == true)
            let before = updates[0]["beforeOid"] as! String, after = updates[0]["afterOid"] as! String
            published += 1
            if rejectionStatus != 200 { return (rejectionStatus, ["message": "controlled rejection"]) }
            if race { currentHead = String(repeating: "8", count: 40) }
            guard before == currentHead else {
                if rejectionShape == "message-only" { return (200, ["errors": [["message": "beforeOid does not match"]]]) }
                let payload: Any = rejectionShape == "partial-data" ? ["clientMutationId": NSNull()] : NSNull()
                return (200, ["data": ["updateRefs": payload],
                    "errors": [["message": "并发更新，未执行", "type": "UNPROCESSABLE", "path": ["updateRefs"]]]])
            }
            if loseReply {
                if applyBeforeLosingReply { currentHead = after }
                throw URLError(.networkConnectionLost)
            }
            currentHead = after
            return (200, ["data": ["updateRefs": ["clientMutationId": NSNull()]]])
        }
        preconditionFailure("Unexpected controlled request: \(method) \(path)")
    }
}

@main struct RepositoryOperationsHarness {
    @MainActor static func idle(_ busy: @escaping () -> Bool) async throws {
        for _ in 0..<500 {
            if !busy() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("state did not settle")
    }
    @MainActor static func historyCase(race: Bool, lose: Bool, applyBeforeLosing: Bool) async throws {
        RemoteHistoryBackup.reset()
        let scenario = OperationsScenario(); scenario.race = race; scenario.loseReply = lose; scenario.applyBeforeLosingReply = applyBeforeLosing
        FixtureProtocol.install(scenario.respond)
        let api = GitHub(), state = RemoteHistoryState()
        state.load(api: api, repo: "fixture/repository", branch: "main")
        try await idle { state.busy }
        let snapshot = state.snapshot!
        let preview = try RemoteHistoryRules.preview(snapshot, selected: Set(snapshot.commits.map(\.sha)), action: .clear, message: "当前代码快照")
        state.apply(preview, api: api)
        try await idle { state.busy }
        precondition(scenario.published == 1)
        if race {
            precondition(state.pendingHead == nil && state.snapshot == nil && state.result.contains("明确拒绝"))
            precondition(RemoteHistoryBackup.events.last == "rejected")
            state.load(api: api, repo: "fixture/repository", branch: "main"); try await idle { state.busy }
            precondition(state.snapshot?.head == scenario.currentHead && scenario.published == 1,
                "A known rejection permits a fresh preview, never an automatic write retry")
        } else if lose && !applyBeforeLosing {
            precondition(state.pendingHead != nil && !state.result.contains("整理完成"))
            state.checkResult(api: api); try await idle { state.busy }
            precondition(scenario.published == 1, "a read-only retry must not publish again")
        } else {
            precondition(state.pendingHead == nil && state.result.contains("全部文件保持不变"))
            precondition(scenario.currentHead != snapshot.head)
        }
    }
    @MainActor static func versionCases() async throws {
        RemoteHistoryBackup.reset()
        let scenario = OperationsScenario(); FixtureProtocol.install(scenario.respond)
        let api = GitHub(), state = RemoteHistoryState()
        state.load(api: api, repo: "fixture/repository", branch: "main"); try await idle { state.busy }
        let snapshot = state.snapshot!
        let versions = [RemoteHistoryVersion(version: "7.0", finalCommit: scenario.b, notes: "- 第一版最终保留功能"),
                        RemoteHistoryVersion(version: "7.1", finalCommit: scenario.c, notes: "- 第二版最终修复")]
        let preview = try RemoteHistoryRules.versionPreview(snapshot, baseline: scenario.a, versions: versions)
        state.apply(preview, api: api); try await idle { state.busy }
        precondition(scenario.published == 1 && scenario.created.count == 2 && state.pendingHead == nil)
        precondition(state.result.contains("每版代码树均已核对"))
        precondition(RemoteHistoryBackup.events == ["backup", "objects-verified", "update-requested", "verified"])
        for corruption in ["tree", "message", "parents", "backup"] {
            RemoteHistoryBackup.reset()
            let broken = OperationsScenario(); broken.corruptCreated = corruption
            RemoteHistoryBackup.failPrepare = corruption == "backup"
            FixtureProtocol.install(broken.respond)
            let next = RemoteHistoryState(); next.apply(preview, api: api); try await idle { next.busy }
            precondition(broken.published == 0 && !next.error.isEmpty && broken.currentHead == scenario.c)
            if corruption == "backup" { precondition(broken.created.isEmpty) }
        }
        RemoteHistoryBackup.reset()
        let lost = OperationsScenario(); lost.loseReply = true; lost.applyBeforeLosingReply = false
        FixtureProtocol.install(lost.respond)
        let pending = RemoteHistoryState(); pending.apply(preview, api: api); try await idle { pending.busy }
        precondition(pending.pendingHead != nil && lost.published == 1)
        let restored = RemoteHistoryState()
        restored.load(api: api, repo: "fixture/repository", branch: "main"); try await idle { restored.busy }
        precondition(restored.pendingHead == pending.pendingHead && lost.published == 1)
        lost.currentHead = pending.pendingHead!
        restored.checkResult(api: api); try await idle { restored.busy }
        precondition(restored.pendingHead == nil && lost.published == 1)
    }
    @MainActor static func historyIdentityCases() async throws {
        for late in [false, true] {
            RemoteHistoryBackup.reset()
            let scenario = OperationsScenario(); FixtureProtocol.install(scenario.respond)
            let api = GitHub(), state = RemoteHistoryState()
            state.load(api: api, repo: "fixture/repository", branch: "main"); try await idle { state.busy }
            let snapshot = state.snapshot!
            let preview = try RemoteHistoryRules.preview(snapshot, selected: Set(snapshot.commits.map(\.sha)), action: .clear, message: "当前代码快照")
            if late { scenario.replaceAfterCreating = true } else { scenario.repositoryID = "R_replaced" }
            state.apply(preview, api: api); try await idle { state.busy }
            precondition(scenario.published == 0 && scenario.currentHead == snapshot.head && !state.error.isEmpty)
            if !late { precondition(scenario.created.isEmpty && RemoteHistoryBackup.events.isEmpty) }
        }
        RemoteHistoryBackup.reset()
        let scenario = OperationsScenario(); scenario.loseReply = true; scenario.applyBeforeLosingReply = false
        FixtureProtocol.install(scenario.respond)
        let api = GitHub(), state = RemoteHistoryState()
        state.load(api: api, repo: "fixture/repository", branch: "main"); try await idle { state.busy }
        let snapshot = state.snapshot!
        let preview = try RemoteHistoryRules.preview(snapshot, selected: Set(snapshot.commits.map(\.sha)), action: .clear, message: "当前代码快照")
        state.apply(preview, api: api); try await idle { state.busy }
        precondition(state.pendingHead != nil && scenario.published == 1)
        scenario.repositoryID = "R_replaced"; scenario.currentHead = state.pendingHead!
        state.checkResult(api: api); try await idle { state.busy }
        precondition(state.pendingHead != nil && scenario.published == 1 && state.result.contains("仓库身份已变化"))
    }
    @MainActor static func historyRejectionCases() async throws {
        for kind in ["message-only", "partial-data", "server-error", "forbidden"] {
            RemoteHistoryBackup.reset()
            let scenario = OperationsScenario()
            scenario.race = kind == "message-only" || kind == "partial-data"
            scenario.rejectionShape = kind
            if kind == "server-error" { scenario.rejectionStatus = 500 }
            if kind == "forbidden" { scenario.rejectionStatus = 403 }
            FixtureProtocol.install(scenario.respond)
            let api = GitHub(), state = RemoteHistoryState()
            state.load(api: api, repo: "fixture/repository", branch: "main"); try await idle { state.busy }
            let snapshot = state.snapshot!
            let preview = try RemoteHistoryRules.preview(snapshot, selected: Set(snapshot.commits.map(\.sha)), action: .clear, message: "当前代码快照")
            state.apply(preview, api: api); try await idle { state.busy }
            precondition(scenario.published == 1 && state.backupURL != nil)
            let phase = RemoteHistoryBackup.latest(accountID: api.accountID, repo: "fixture/repository", branch: "main")!.record.phase
            if kind == "forbidden" {
                precondition(state.pendingHead == nil && phase == "rejected" && state.result.contains("明确拒绝"))
            } else {
                precondition(state.pendingHead != nil && phase == "update-requested",
                    "Unstructured, partial-data or server-error responses remain unknown: " + kind)
                state.checkResult(api: api); try await idle { state.busy }
                precondition(scenario.published == 1)
            }
            let restored = RemoteHistoryState()
            restored.load(api: api, repo: "fixture/repository", branch: "main"); try await idle { restored.busy }
            precondition((restored.pendingHead == nil) == (kind == "forbidden") && scenario.published == 1)
        }
        print("PASS known atomic/permission rejection unlocks, ambiguous/partial/server failures remain pending without resending")
    }
    @MainActor static func prCase(method: PullRequestMergeMethod, lose: Bool, applyBeforeLosing: Bool) async throws {
        let scenario = OperationsScenario(); scenario.loseReply = lose; scenario.applyBeforeLosingReply = applyBeforeLosing
        FixtureProtocol.install(scenario.respond)
        let api = GitHub(), state = PullRequestMergeState()
        state.load(api: api, repo: "fixture/repository", number: 7); try await idle { state.busy }
        let options = state.options!
        precondition(PullRequestMergeMethod.allCases.allSatisfy { options.reason($0) == nil })
        let confirmation = PullRequestMergeConfirmation(accountID: api.accountID, generation: AccountStore.generation, repo: "fixture/repository", options: options, method: method, title: "自定标题", message: "正文")
        state.apply(confirmation, api: api); try await idle { state.busy }
        precondition(scenario.merges == [method.rawValue])
        if lose && !applyBeforeLosing {
            precondition(state.pending != nil && state.result.contains("尚未核实"))
            state.load(api: api, repo: "fixture/repository", number: 7); try await idle { state.busy }
            precondition(scenario.merges.count == 1)
        } else { precondition(state.pending == nil && state.result.contains("合并")) }
    }
    @MainActor static func gates() async throws {
        let scenario = OperationsScenario(); FixtureProtocol.install(scenario.respond)
        let api = GitHub()
        for value in ["BLOCKED", "DIRTY", "BEHIND", "UNKNOWN"] {
            scenario.mergeState = value
            let options = try await api.pullRequestMergeOptions("fixture/repository", number: 7)
            precondition(PullRequestMergeMethod.allCases.allSatisfy { options.reason($0) != nil })
        }
        scenario.mergeState = "UNSTABLE"
        let optionalFailure = try await api.pullRequestMergeOptions("fixture/repository", number: 7)
        precondition(optionalFailure.reason(.merge) == nil, "nonrequired failures must follow GitHub's mergeable status")
        scenario.allowed = false
        let denied = try await api.pullRequestMergeOptions("fixture/repository", number: 7)
        precondition(PullRequestMergeMethod.allCases.allSatisfy { denied.reason($0) != nil })
        precondition(scenario.merges.isEmpty)
        scenario.allowed = true; scenario.mergeState = "CLEAN"
        let initial = try await api.pullRequestMergeOptions("fixture/repository", number: 7)
        let confirmation = PullRequestMergeConfirmation(accountID: api.accountID, generation: AccountStore.generation,
            repo: "fixture/repository", options: initial, method: .merge, title: "", message: "")
        scenario.base = String(repeating: "8", count: 40)
        let stale = PullRequestMergeState(); stale.apply(confirmation, api: api); try await idle { stale.busy }
        precondition(!stale.error.isEmpty && scenario.merges.isEmpty, "a stale base must require a new preview")
        AccountStore.generation = UUID()
        let switched = PullRequestMergeState(); switched.apply(confirmation, api: api)
        precondition(!switched.busy && scenario.merges.isEmpty, "an old account confirmation cannot write")
    }
    @MainActor static func prEndpointIdentityCases() async throws {
        for field in ["base-ref", "head-ref", "base-repository", "head-repository", "repository-id"] {
            let scenario = OperationsScenario(); FixtureProtocol.install(scenario.respond)
            let api = GitHub(), state = PullRequestMergeState()
            let options = try await api.pullRequestMergeOptions("fixture/repository", number: 7)
            let confirmation = PullRequestMergeConfirmation(accountID: api.accountID, generation: AccountStore.generation,
                repo: "fixture/repository", options: options, method: .merge, title: "", message: "")
            switch field {
            case "base-ref": scenario.baseRef = "release"
            case "head-ref": scenario.headRef = "another-feature"
            case "base-repository": scenario.baseRepository = "fixture/another"
            case "head-repository": scenario.headRepository = "fixture/another-fork"
            default: scenario.repositoryID = "R_replaced"
            }
            state.apply(confirmation, api: api); try await idle { state.busy }
            precondition(scenario.merges.isEmpty && state.pending == nil && !state.error.isEmpty,
                "Same SHA cannot authorize a changed PR endpoint: " + field)
        }
        let scenario = OperationsScenario(); scenario.loseReply = true; scenario.applyBeforeLosingReply = false
        FixtureProtocol.install(scenario.respond)
        let api = GitHub(), state = PullRequestMergeState()
        let options = try await api.pullRequestMergeOptions("fixture/repository", number: 7)
        let confirmation = PullRequestMergeConfirmation(accountID: api.accountID, generation: AccountStore.generation,
            repo: "fixture/repository", options: options, method: .merge, title: "", message: "")
        state.apply(confirmation, api: api); try await idle { state.busy }
        scenario.baseRef = "release"; scenario.merged = true
        state.load(api: api, repo: "fixture/repository", number: 7); try await idle { state.busy }
        precondition(state.pending != nil && scenario.merges.count == 1 && state.result.contains("尚未核实"),
            "A later merge into another target cannot confirm this pending request")
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.last == "history" {
            try await historyCase(race: false, lose: false, applyBeforeLosing: true)
            try await historyCase(race: true, lose: false, applyBeforeLosing: true)
            try await historyCase(race: false, lose: true, applyBeforeLosing: true)
            try await historyCase(race: false, lose: true, applyBeforeLosing: false)
            try await versionCases()
            try await historyIdentityCases()
            try await historyRejectionCases()
        } else {
            for method in PullRequestMergeMethod.allCases { try await prCase(method: method, lose: false, applyBeforeLosing: true) }
            try await prCase(method: .squash, lose: true, applyBeforeLosing: true)
            try await prCase(method: .rebase, lose: true, applyBeforeLosing: false)
            try await gates()
            try await prEndpointIdentityCases()
        }
        print("PASS production repository operations: \(CommandLine.arguments.last ?? "")")
    }
}
