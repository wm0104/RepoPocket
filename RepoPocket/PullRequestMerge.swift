import Foundation
import Combine

enum PullRequestMergeMethod: String, CaseIterable, Identifiable {
    case merge, squash, rebase
    var id: String { rawValue }
    var title: String {
        switch self { case .merge: return "普通合并"; case .squash: return "压缩合并"; case .rebase: return "Rebase 合并" }
    }
}

struct PullRequestMergeRepository: Decodable {
    let node_id: String
    let full_name: String
    let permissions: Repository.Permissions?
    let allow_merge_commit: Bool?
    let allow_squash_merge: Bool?
    let allow_rebase_merge: Bool?
}

struct PullRequestMergeGate: Decodable {
    let mergeStateStatus: String
    let reviewDecision: String?
    let headRefOid: String
    let baseRefOid: String
}

struct PullRequestMergeOptions: Identifiable {
    let id = UUID()
    let repository: PullRequestMergeRepository
    let pull: RemoteBranchMergePR
    let rebaseable: Bool?
    let gate: PullRequestMergeGate
    func reason(_ method: PullRequestMergeMethod) -> String? {
        let allowed: Bool?
        switch method {
        case .merge: allowed = repository.allow_merge_commit
        case .squash: allowed = repository.allow_squash_merge
        case .rebase: allowed = repository.allow_rebase_merge
        }
        guard allowed == true else { return "仓库未允许此合并方式，或尚未取得设置。" }
        guard repository.permissions?.push == true else { return "当前账号没有已确认的推送权限。" }
        guard pull.state == "open", pull.merged == false, pull.draft == false else { return "PR已关闭、已合并、是草稿或状态尚未确认。" }
        guard gate.headRefOid == pull.head.sha, gate.baseRefOid == pull.base.sha else { return "检查期间分支已变化，请刷新。" }
        guard pull.mergeable == true else { return "存在冲突，或GitHub仍在计算可合并状态。" }
        guard ["CLEAN", "UNSTABLE", "HAS_HOOKS"].contains(gate.mergeStateStatus) else {
            return "GitHub尚未允许合并（\(gate.mergeStateStatus)），请完成所需检查、审查或分支更新。"
        }
        if gate.reviewDecision == "CHANGES_REQUESTED" || gate.reviewDecision == "REVIEW_REQUIRED" { return "所需审查尚未通过。" }
        if method == .rebase && rebaseable != true { return "GitHub尚未确认此PR可以Rebase。" }
        return nil
    }
}

struct PullRequestMergeConfirmation: Identifiable {
    let id = UUID()
    let accountID: String
    let generation: UUID
    let repo: String
    let options: PullRequestMergeOptions
    let method: PullRequestMergeMethod
    let title: String
    let message: String
}

extension GitHub {
    func pullRequestMergeOptions(_ repo: String, number: Int) async throws -> PullRequestMergeOptions {
        guard number > 0 else { throw AppError(text: "PR编号无效。") }
        let parts = try RepositoryInput.parse(repo).split(separator: "/").map(String.init)
        let repository = try JSONDecoder().decode(PullRequestMergeRepository.self, from: await communityRead(Self.repoPath(repo)))
        let bytes = try await communityRead(Self.repoPath(repo) + "/pulls/\(number)")
        let pull = try JSONDecoder().decode(RemoteBranchMergePR.self, from: bytes)
        struct Rebase: Decodable { let rebaseable: Bool? }
        let rebaseable = try JSONDecoder().decode(Rebase.self, from: bytes).rebaseable
        let query = "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { mergeStateStatus reviewDecision headRefOid baseRefOid } } }"
        let gateBytes = try await repositoryGraphQLRead(query, variables: ["owner": parts[0], "name": parts[1], "number": number], operation: "读取PR合并条件")
        struct Response: Decodable {
            struct Result: Decodable {
                struct Repo: Decodable { let pullRequest: PullRequestMergeGate? }
                let repository: Repo?
            }
            let data: Result?
        }
        guard let gate = try JSONDecoder().decode(Response.self, from: gateBytes).data?.repository?.pullRequest,
              pull.number == number, repository.full_name.caseInsensitiveCompare(repo) == .orderedSame else { throw AppError(text: "未取得完整的PR合并条件。") }
        return .init(repository: repository, pull: pull, rebaseable: rebaseable, gate: gate)
    }
}

@MainActor final class PullRequestMergeState: ObservableObject {
    @Published private(set) var options: PullRequestMergeOptions?
    @Published private(set) var busy = false
    @Published private(set) var error = ""
    @Published private(set) var result = ""
    @Published private(set) var pending: PullRequestMergeConfirmation?
    private var returnedSHA: String?
    private var task: Task<Void, Never>?
    func cancel() { task?.cancel() }
    private func valid(_ confirmation: PullRequestMergeConfirmation, api: GitHub) -> Bool {
        api.isCurrentSession && api.accountID == confirmation.accountID && AccountStore.generation == confirmation.generation
    }
    private func sameBranches(_ pull: RemoteBranchMergePR, as confirmed: RemoteBranchMergePR) -> Bool {
        pull.head.ref == confirmed.head.ref && pull.base.ref == confirmed.base.ref
            && pull.head.repo?.full_name.lowercased() == confirmed.head.repo?.full_name.lowercased()
            && pull.base.repo?.full_name.lowercased() == confirmed.base.repo?.full_name.lowercased()
    }
    func load(api: GitHub, repo: String, number: Int) {
        guard !busy else { return }
        busy = true; error = ""
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.task = nil }
            if self.pending != nil { await self.reconcile(api: api); return }
            do {
                let options = try await api.pullRequestMergeOptions(repo, number: number)
                try Task.checkCancellation(); guard api.isCurrentSession else { return }
                self.options = options
            } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
    func apply(_ confirmation: PullRequestMergeConfirmation, api: GitHub) {
        guard !busy, pending == nil, valid(confirmation, api: api) else { return }
        busy = true; error = ""; result = ""
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.task = nil }
            do {
                let fresh = try await api.pullRequestMergeOptions(confirmation.repo, number: confirmation.options.pull.number)
                guard self.valid(confirmation, api: api), fresh.repository.node_id == confirmation.options.repository.node_id,
                      self.sameBranches(fresh.pull, as: confirmation.options.pull),
                      fresh.pull.head.sha == confirmation.options.pull.head.sha,
                      fresh.pull.base.sha == confirmation.options.pull.base.sha else { throw AppError(text: "PR来源、目标分支或提交已变化，请重新预览。") }
                if let reason = fresh.reason(confirmation.method) { throw AppError(text: reason) }
                try Task.checkCancellation()
                self.pending = confirmation; self.returnedSHA = nil
                do {
                    self.returnedSHA = try await api.performPullRequestMerge(confirmation)
                } catch { self.error = error.localizedDescription }
                await self.reconcile(api: api)
            } catch { if api.isCurrentSession { self.error = error.localizedDescription } }
        }
    }
    private func reconcile(api: GitHub) async {
        guard let confirmation = pending, valid(confirmation, api: api) else { return }
        do {
            let repository = try JSONDecoder().decode(PullRequestMergeRepository.self,
                from: await api.communityRead(GitHub.repoPath(confirmation.repo)))
            let bytes = try await api.communityRead(GitHub.repoPath(confirmation.repo) + "/pulls/\(confirmation.options.pull.number)")
            let fresh = try JSONDecoder().decode(RemoteBranchMergePR.self, from: bytes)
            guard valid(confirmation, api: api) else { return }
            guard repository.node_id == confirmation.options.repository.node_id,
                  sameBranches(fresh, as: confirmation.options.pull),
                  fresh.merged == true, fresh.state == "closed", fresh.head.sha == confirmation.options.pull.head.sha,
                  returnedSHA == nil || fresh.merge_commit_sha == returnedSHA else {
                result = "尚未核实合并完成。请只读核实，不会自动重发合并请求。"; return
            }
            result = returnedSHA == nil ? "已核实PR已合并；实际执行方式以GitHub记录为准。" : confirmation.method.title + "完成。"
            pending = nil; options = nil; error = ""
            ContentSnapshotCache.shared.remove(accountID: api.accountID, key: "directory-head:" + confirmation.repo.lowercased() + "\n" + fresh.base.ref)
            NotificationCenter.default.post(name: .repositoryHistoryChanged, object: nil, userInfo: [
                "repo": confirmation.repo, "branch": fresh.base.ref, "account": api.accountID, "generation": confirmation.generation
            ])
        } catch { if valid(confirmation, api: api) { self.error = error.localizedDescription; result = "合并结果尚未核实，请恢复网络后只读核实。" } }
    }
}
