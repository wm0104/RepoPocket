import Foundation
import Combine

extension Notification.Name { static let repositoryHistoryChanged = Notification.Name("RepoPocket.repositoryHistoryChanged") }

extension GitHub {
    func historyRepositoryID(_ repo: String) async throws -> String {
        let bytes = try await communityRead(Self.repoPath(repo))
        struct Identity: Decodable { let node_id: String }
        return try JSONDecoder().decode(Identity.self, from: bytes).node_id
    }
    func remoteHistorySnapshot(_ repo: String, branch: String, progress: @escaping (Int) -> Void) async throws -> RemoteHistorySnapshot {
        let repository = try RepositoryInput.parse(repo), generation = AccountStore.generation
        let selected = try await resolvedBranch(repository, branch: branch)
        guard DesktopRules.validBranch(selected) else { throw AppError(text: "请选择有效分支。") }
        let bytes = try await communityRead(Self.repoPath(repository))
        struct Identity: Decodable { let node_id: String; let permissions: Repository.Permissions? }
        let identity = try JSONDecoder().decode(Identity.self, from: bytes)
        guard identity.permissions?.push == true else { throw AppError(text: "当前账号没有已确认的推送权限，不能整理历史。") }
        let head = try await workspaceHead(repository, branch: selected)
        var commits: [RemoteHistoryCommit] = []
        for page in 1...(RemoteHistoryRules.maximumCommits / 100 + 1) {
            let data = try await communityRead(Self.repoPath(repository) + "/commits", query: [
                .init(name: "sha", value: head), .init(name: "per_page", value: "100"), .init(name: "page", value: String(page))
            ])
            let batch = try JSONDecoder().decode([RemoteHistoryCommit].self, from: data)
            guard commits.count + batch.count <= RemoteHistoryRules.maximumCommits else { throw AppError(text: "历史超过5000条，本次不提供不完整的全选或改写。") }
            commits += batch; progress(commits.count)
            try Task.checkCancellation()
            guard isCurrentSession, generation == AccountStore.generation else { throw CancellationError() }
            if batch.count < 100 {
                let snapshot = RemoteHistorySnapshot(accountID: accountID, generation: generation, repository: repository,
                    repositoryID: identity.node_id, branch: selected, head: head, commits: commits)
                _ = try RemoteHistoryRules.topologicalOrder(snapshot)
                guard try await workspaceHead(repository, branch: selected) == head else { throw AppError(text: "读取期间当前分支已变化，请重新读取。") }
                return snapshot
            }
        }
        throw AppError(text: "历史达到5000条读取边界，尚未确认全部祖先；本次不提供不完整的全选或改写。")
    }
    func historyCommitTree(_ repo: String, sha: String) async throws -> String {
        let bytes = try await communityRead(Self.repoPath(repo) + "/git/commits/" + Self.component(sha))
        struct Commit: Decodable { let tree: RemoteHistoryCommit.Object }
        return try JSONDecoder().decode(Commit.self, from: bytes).tree.sha
    }
    func historyCreatedCommit(_ repo: String, sha: String) async throws -> RemoteHistoryCreatedCommit {
        let bytes = try await communityRead(Self.repoPath(repo) + "/git/commits/" + Self.component(sha))
        return try JSONDecoder().decode(RemoteHistoryCreatedCommit.self, from: bytes)
    }
}

@MainActor final class RemoteHistoryState: ObservableObject {
    @Published private(set) var snapshot: RemoteHistorySnapshot?
    @Published private(set) var busy = false
    @Published private(set) var progress = ""
    @Published private(set) var error = ""
    @Published private(set) var result = ""
    @Published private(set) var pendingHead: String?
    @Published private(set) var backupURL: URL?
    private var pendingPreview: RemoteHistoryPreview?
    private var task: Task<Void, Never>?
    private var requestID = UUID()

    func cancel() { task?.cancel() }
    func load(api: GitHub, repo: String, branch: String) {
        guard !busy, pendingHead == nil else { return }
        if let saved = RemoteHistoryBackup.latest(accountID: api.accountID, repo: repo, branch: branch), api.isCurrentSession {
            backupURL = saved.folder
            if saved.record.phase == "update-requested", let head = saved.record.newHead {
                pendingHead = head; pendingPreview = saved.record.preview(generation: AccountStore.generation)
                checkResult(api: api); return
            }
        }
        let token = UUID(); requestID = token
        busy = true; snapshot = nil; error = ""; result = ""; progress = "正在读取当前分支完整历史…"
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.requestID == token { self.busy = false; self.task = nil } }
            do {
                let snapshot = try await api.remoteHistorySnapshot(repo, branch: branch) { count in
                    if self.requestID == token { self.progress = "已读取 \(count) 条提交…" }
                }
                guard self.requestID == token, api.isCurrentSession else { return }
                self.snapshot = snapshot; self.progress = "已取得当前分支全部 \(snapshot.commits.count) 条提交"
            } catch {
                if self.requestID == token, api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription }
            }
        }
    }
    func apply(_ preview: RemoteHistoryPreview, api: GitHub) {
        guard !busy, pendingHead == nil, valid(preview, api: api) else { return }
        busy = true; error = ""; result = ""
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.task = nil }
            do {
                try await api.requireWriteAccess(preview.snapshot.repository)
                guard self.valid(preview, api: api),
                      try await api.historyRepositoryID(preview.snapshot.repository) == preview.snapshot.repositoryID,
                      try await api.workspaceHead(preview.snapshot.repository, branch: preview.snapshot.branch) == preview.snapshot.head else { throw AppError(text: "仓库、分支或账号已变化，请重新预览。") }
                self.progress = "正在本机备份原分支完整历史，远端尚未改动…"
                let backup = try await RemoteHistoryBackup.prepare(preview, api: api)
                self.backupURL = backup
                var resolved: [String: String] = [:], completed = 0
                for step in preview.steps {
                    try Task.checkCancellation()
                    guard self.valid(preview, api: api) else { throw CancellationError() }
                    if step.recreate {
                        let parents = step.parents.map { resolved[$0] ?? $0 }
                        let created = try await api.historyCreateCommit(preview.snapshot.repository, step: step, parents: parents)
                        let object = try await api.historyCreatedCommit(preview.snapshot.repository, sha: created)
                        let tree = object.tree.sha
                        guard tree == step.tree, object.sha == created, object.parents.map(\.sha) == parents,
                              object.message.trimmingCharacters(in: .newlines) == step.message.trimmingCharacters(in: .newlines) else {
                            throw AppError(text: "提交代码树、说明或父子关系校验失败，未更新分支。")
                        }
                        resolved[step.key] = created
                        completed += 1; self.progress = "准备提交对象 \(completed)/\(preview.recreatedCount)，分支尚未更新"
                    } else { resolved[step.key] = step.key }
                }
                guard let newHead = resolved[preview.resultKey],
                      try await api.historyCommitTree(preview.snapshot.repository, sha: newHead) == preview.snapshot.tree,
                      self.valid(preview, api: api) else { throw AppError(text: "最终代码树校验失败，未更新分支。") }
                try Task.checkCancellation()
                try RemoteHistoryBackup.update(backup, preview: preview, resolved: resolved, newHead: newHead, phase: "objects-verified")
                guard try await api.workspaceHead(preview.snapshot.repository, branch: preview.snapshot.branch) == preview.snapshot.head,
                      try await api.historyRepositoryID(preview.snapshot.repository) == preview.snapshot.repositoryID,
                      self.valid(preview, api: api) else { throw AppError(text: "远端已有后续工作，未覆盖。请重新读取并核对。") }
                try Task.checkCancellation()
                try RemoteHistoryBackup.update(backup, preview: preview, resolved: resolved, newHead: newHead, phase: "update-requested")
                self.pendingHead = newHead; self.pendingPreview = preview
                self.progress = "正在原子更新当前分支…"
                do { try await api.historyUpdateRef(preview, newHead: newHead) }
                catch let rejection as RemoteHistoryRefRejection {
                    try RemoteHistoryBackup.update(backup, preview: preview, resolved: [:], newHead: newHead, phase: "rejected")
                    guard self.valid(preview, api: api) else { return }
                    self.pendingHead = nil; self.pendingPreview = nil; self.snapshot = nil
                    self.progress = ""; self.error = rejection.localizedDescription
                    self.result = "GitHub已明确拒绝更新，本次请求未改动分支。请重新读取并预览，备份仍保留。"
                    return
                }
                catch { self.error = error.localizedDescription }
                await reconcile(api: api)
            } catch {
                if api.isCurrentSession { self.error = error.localizedDescription }
            }
        }
    }
    func checkResult(api: GitHub) {
        guard !busy, pendingHead != nil else { return }
        busy = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.task = nil }
            await reconcile(api: api)
        }
    }
    private func valid(_ preview: RemoteHistoryPreview, api: GitHub) -> Bool {
        api.isCurrentSession && preview.snapshot.accountID == api.accountID && preview.snapshot.generation == AccountStore.generation
    }
    private func reconcile(api: GitHub) async {
        guard let preview = pendingPreview, let newHead = pendingHead, valid(preview, api: api) else { return }
        do {
            guard try await api.historyRepositoryID(preview.snapshot.repository) == preview.snapshot.repositoryID else {
                result = "仓库身份已变化，尚未确认原仓库的历史更新结果；仅可重新查询，不会自动重发。"; return
            }
            let actual = try await api.workspaceHead(preview.snapshot.repository, branch: preview.snapshot.branch)
            guard valid(preview, api: api) else { return }
            guard actual == newHead, try await api.historyCommitTree(preview.snapshot.repository, sha: actual) == preview.snapshot.tree else {
                result = "尚未确认历史更新结果。当前HEAD：\(actual.prefix(8))。仅可重新查询，不会自动重发历史更新。"; return
            }
            ContentSnapshotCache.shared.remove(accountID: api.accountID, key: "directory-head:" + preview.snapshot.repository.lowercased() + "\n" + preview.snapshot.branch)
            if let backupURL {
                try RemoteHistoryBackup.update(backupURL, preview: preview, resolved: [:], newHead: actual, phase: "verified")
            }
            pendingHead = nil; pendingPreview = nil; snapshot = nil; error = ""
            result = (preview.action == .versions ? "已按版本整理为\(preview.versions.count)条提交，每版代码树均已核对。" : "历史整理完成，全部文件保持不变。")
                + "当前提交：" + String(actual.prefix(8)) + "。原历史备份保存在本机，可导出。"
            NotificationCenter.default.post(name: .repositoryHistoryChanged, object: nil, userInfo: [
                "repo": preview.snapshot.repository, "branch": preview.snapshot.branch,
                "account": api.accountID, "generation": preview.snapshot.generation
            ])
        } catch {
            if valid(preview, api: api) { result = "更新结果尚未核实，请恢复网络后只读查询；不会自动重复执行。"; self.error = error.localizedDescription }
        }
    }
}
