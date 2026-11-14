import Foundation

struct AppError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
struct GitHubAPIError: Error { let status: Int; let operation: String; let reason: String }
enum RefreshFailure { static func isCancellation(_ error: Error) -> Bool { error is CancellationError } }

@MainActor final class GitHub {
    let accountID = "upstream-regression-" + UUID().uuidString
    var isCurrentSession = true
    var preview: CheckedContinuation<UpstreamCompare, Error>?
    var merge: CheckedContinuation<UpstreamSyncRules.MergeOutcome, Error>?
    var apply: CheckedContinuation<UpstreamSyncRules.ApplyOutcome, Error>?
    var previews = 0
    var writes = 0
    func upstreamCompare(repo: String, base: String, upstream: UpstreamSyncRules.Target) async throws -> UpstreamCompare {
        previews += 1
        return try await withCheckedThrowingContinuation { preview = $0 }
    }
    func upstreamBranchHead(repo: String, branch: String) async throws -> String { String(repeating: "a", count: 40) }
    func createUpstreamRef(repo: String, ref: String, sha: String) async throws { writes += 1 }
    func mergeUpstream(repo: String, base: String, upstream: UpstreamSyncRules.Target,
                       message: String) async throws -> UpstreamSyncRules.MergeOutcome {
        writes += 1
        return try await withCheckedThrowingContinuation { merge = $0 }
    }
    func applyUpstreamFastForward(repo: String, branch: String, sha: String) async throws -> UpstreamSyncRules.ApplyOutcome {
        writes += 1
        return try await withCheckedThrowingContinuation { apply = $0 }
    }
}

@main struct UpstreamSyncHarness {
    @MainActor static func wait(_ ready: () -> Bool) async {
        for _ in 0..<10_000 {
            if ready() { return }
            await Task.yield()
        }
        preconditionFailure("operation never reached its suspension point")
    }
    @MainActor static func main() async {
        let state = UpstreamSyncState(), api = GitHub()
        let repo = "target/repo", sha = String(repeating: "b", count: 40)
        state.upstreamRepository = "source/repo"; state.upstreamBranch = "main"
        let result = UpstreamCompare(status: "ahead", ahead_by: 1, behind_by: 0,
                                     total_commits: 1, commits: [], files: [])
        let receipt = UpstreamSyncState.Receipt(stamp: "test", backupTag: "backup/test", tempBranch: "sync/test",
                                               head: "", upstream: "source/repo", upstreamBranch: "main")
        let merge = Task { await state.merge(api: api, repo: repo, branch: "main", receipt: receipt) }
        await wait { api.merge != nil }
        await state.loadPreview(api: api, repo: repo, branch: "main")
        precondition(api.previews == 0 && state.busy)
        api.merge!.resume(returning: .merged(sha: sha)); api.merge = nil
        await merge.value
        precondition(state.stage == .merged && state.mergeSHA == sha && state.receipt != nil)

        let apply = Task { await state.apply(api: api, repo: repo, branch: "main") }
        await wait { api.apply != nil }
        await state.loadPreview(api: api, repo: repo, branch: "main")
        precondition(api.previews == 0 && state.busy)
        api.apply!.resume(returning: .updated(sha: sha)); api.apply = nil
        await apply.value
        precondition(state.stage == .applied && state.appliedSHA == sha)

        let preview = Task { await state.loadPreview(api: api, repo: repo, branch: "main") }
        await wait { api.preview != nil }
        let writes = api.writes
        state.stage = .merged
        await state.merge(api: api, repo: repo, branch: "main", receipt: receipt)
        await state.apply(api: api, repo: repo, branch: "main")
        precondition(api.writes == writes && state.loading)
        // A source change must reject the old response even if made outside the disabled UI.
        state.upstreamRepository = "other/repo"; state.upstreamBranch = "develop"
        api.preview!.resume(returning: result); api.preview = nil
        await preview.value
        precondition(state.upstreamRepository == "other/repo" && state.upstreamBranch == "develop")
        precondition(state.compare == nil && !state.loading && state.mergeSHA == sha)
        precondition(UserDefaults.standard.string(forKey: UpstreamSyncRules.memoryKey(account: api.accountID, repository: repo)) == nil)

        let staleFailure = Task { await state.loadPreview(api: api, repo: repo, branch: "main") }
        await wait { api.preview != nil }
        state.upstreamBranch = "release"
        api.preview!.resume(throwing: AppError(text: "old-source-error")); api.preview = nil
        await staleFailure.value
        precondition(state.error.isEmpty && state.upstreamBranch == "release")

        let valid = Task { await state.loadPreview(api: api, repo: repo, branch: "main") }
        await wait { api.preview != nil }
        api.preview!.resume(returning: result); api.preview = nil
        await valid.value
        precondition(state.stage == .preview && state.compare?.ahead_by == 1)
        precondition(state.receipt == nil && state.mergeSHA.isEmpty && !state.loading)
        precondition(state.propose())
        UserDefaults.standard.removeObject(forKey: UpstreamSyncRules.memoryKey(account: api.accountID, repository: repo))

        let cancelled = Task { await state.loadPreview(api: api, repo: repo, branch: "main") }
        await wait { api.preview != nil }
        cancelled.cancel()
        api.preview!.resume(returning: result); api.preview = nil
        await cancelled.value
        precondition(state.compare == nil && !state.loading && state.error.isEmpty)
        print("PASS production upstream state: preview/write exclusion, stale sources, success and cancellation")
    }
}
