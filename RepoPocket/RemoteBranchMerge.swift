import Foundation
import Combine

struct RemoteBranchMergeSession: Equatable {
    let accountID: String
    let generation: UUID
}

struct RemoteBranchMergePreview: Identifiable {
    let id = UUID()
    let repository: String
    let source: String
    let target: String
    let sourceSHA: String
    let targetSHA: String
    let commits: [DesktopCommit]
    let files: [DesktopCommit.File]
}

struct RemoteBranchMergePR: Decodable, Identifiable {
    struct Endpoint: Decodable {
        struct Repository: Decodable { let full_name: String }
        let ref: String
        let sha: String
        let repo: Repository?
    }
    let number: Int
    let head: Endpoint
    let base: Endpoint
    let state: String
    let draft: Bool?
    let merged: Bool?
    let mergeable: Bool?
    let mergeable_state: String?
    let merge_commit_sha: String?
    let html_url: String?
    var id: Int { number }
}

struct RemoteBranchMergeChecks {
    let statusCount: Int
    let checkRunCount: Int
    let blockReasons: [String]
    var summary: String {
        statusCount + checkRunCount == 0 ? "没有配置检查，不代表成功；GitHub 规则为准。" :
            "已读取 \(statusCount) 个提交状态、\(checkRunCount) 个检查。GitHub 仍会执行所需审查与分支保护规则。"
    }
}

struct RemoteBranchMergeConfirmation: Identifiable {
    let id = UUID()
    let preview: RemoteBranchMergePreview
    let pullNumber: Int
    let title: String
    let session: RemoteBranchMergeSession
}

enum RemoteBranchMergeRules {
    static func sha(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
        }
    }
    static func title(_ value: String) throws -> String {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 256,
              !title.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw AppError(text: "请填写有效标题（1–256 字符，不含换行或控制字符）。")
        }
        return title
    }
    static func matches(_ pr: RemoteBranchMergePR, _ preview: RemoteBranchMergePreview) -> Bool {
        pr.number > 0 && pr.head.ref == preview.source && pr.base.ref == preview.target &&
        pr.head.sha == preview.sourceSHA && pr.base.sha == preview.targetSHA &&
        pr.head.repo?.full_name.lowercased() == preview.repository.lowercased() &&
        pr.base.repo?.full_name.lowercased() == preview.repository.lowercased()
    }
    static func prReasons(_ pr: RemoteBranchMergePR, _ preview: RemoteBranchMergePreview) -> [String] {
        var reasons: [String] = []
        if !matches(pr, preview) { reasons.append("PR 分支、仓库或 SHA 已变化，请重新预览。") }
        if pr.state != "open" || pr.merged != false { reasons.append("PR 未确认处于未合并的打开状态。") }
        if pr.draft != false { reasons.append("PR 是草稿或草稿状态未知。") }
        if pr.mergeable != true || pr.mergeable_state != "clean" {
            reasons.append("PR 尚不可安全合并（\(pr.mergeable_state ?? "unknown")）：冲突、等待检查、审查或保护规则未满足时不能合并。")
        }
        return reasons
    }
}

@MainActor
extension GitHub {
    private struct MergeBranch: Decodable { struct Commit: Decodable { let sha: String }; let name: String; let commit: Commit }
    private struct MergeComparison: Decodable {
        struct Commit: Decodable { let sha: String }
        let base_commit: Commit
        let total_commits: Int
        let ahead_by: Int
        let commits: [DesktopCommit]
        let files: [DesktopCommit.File]?
    }
    private struct MergeRepository: Decodable {
        struct Permissions: Decodable { let push: Bool? }
        let full_name: String
        let permissions: Permissions?
        let allow_squash_merge: Bool?
        let delete_branch_on_merge: Bool?
    }
    private func mergeRead<T: Decodable>(_ type: T.Type, repo: String, suffix: String,
                                          query: [URLQueryItem] = []) async throws -> T {
        let data = try await remoteBranchMergeData(repo, suffix: suffix, query: query)
        return try JSONDecoder().decode(type, from: data)
    }
    private func mergeHead(_ repo: String, branch: String) async throws -> String {
        guard DesktopRules.validBranch(branch) else { throw AppError(text: "无效分支名。") }
        let value = try await mergeRead(MergeBranch.self, repo: repo, suffix: "/branches/" + Self.component(branch))
        guard value.name == branch, RemoteBranchMergeRules.sha(value.commit.sha) else {
            throw AppError(text: "GitHub 返回的分支或 SHA 无效。")
        }
        return value.commit.sha
    }
    func remoteBranchMergePreview(repo: String, source: String, target: String) async throws -> RemoteBranchMergePreview {
        let repository = try RepositoryInput.parse(repo)
        guard source != target, DesktopRules.validBranch(source), DesktopRules.validBranch(target) else {
            throw AppError(text: "请选择不同且有效的来源与目标分支。")
        }
        let head = try await mergeHead(repository, branch: source)
        let base = try await mergeHead(repository, branch: target)
        var commits: [DesktopCommit] = [], files: [DesktopCommit.File] = []
        var total: Int?
        for page in 1...50 {
            let result = try await mergeRead(MergeComparison.self, repo: repository,
                suffix: "/compare/" + base + "..." + head,
                query: [.init(name: "per_page", value: "100"), .init(name: "page", value: String(page))])
            guard result.base_commit.sha == base, result.ahead_by > 0, result.total_commits > 0,
                  total == nil || total == result.total_commits else {
                throw AppError(text: "没有可合并的提交，或比较结果不完整；请重新预览。")
            }
            total = result.total_commits
            if page == 1 {
                guard let changed = result.files, changed.count < 300 else {
                    throw AppError(text: "文件比较缺失或达到 GitHub 300 文件上限，不能使用截断预览创建或合并 PR。")
                }
                files = changed
            }
            commits += result.commits
            if commits.count == result.total_commits { break }
            guard !result.commits.isEmpty, commits.count < result.total_commits, page < 50 else {
                throw AppError(text: "提交比较分页不完整，请缩小变更范围。")
            }
        }
        guard commits.count == total, Set(commits.map(\.sha)).count == commits.count,
              commits.last?.sha == head else { throw AppError(text: "比较结果不完整，请重新预览。") }
        let preview = RemoteBranchMergePreview(repository: repository, source: source, target: target,
            sourceSHA: head, targetSHA: base, commits: commits, files: files)
        try await remoteBranchMergeValidate(preview)
        return preview
    }
    func remoteBranchMergeValidate(_ preview: RemoteBranchMergePreview) async throws {
        let head = try await mergeHead(preview.repository, branch: preview.source)
        let base = try await mergeHead(preview.repository, branch: preview.target)
        guard head == preview.sourceSHA, base == preview.targetSHA else {
            throw AppError(text: "来源分支已变化或目标分支已前进，请重新预览，不能使用旧 diff。")
        }
    }
    func remoteBranchMergePull(_ preview: RemoteBranchMergePreview, number: Int) async throws -> RemoteBranchMergePR {
        guard number > 0 else { throw AppError(text: "无效 PR 编号。") }
        let pr = try await mergeRead(RemoteBranchMergePR.self, repo: preview.repository, suffix: "/pulls/\(number)")
        guard pr.number == number else { throw AppError(text: "PR 编号与请求不一致。") }
        return pr
    }
    func remoteBranchMergeExisting(_ preview: RemoteBranchMergePreview) async throws -> RemoteBranchMergePR? {
        let owner = String(preview.repository.split(separator: "/")[0])
        var found: RemoteBranchMergePR?
        for page in 1...50 {
            let batch = try await mergeRead([RemoteBranchMergePR].self, repo: preview.repository, suffix: "/pulls",
                query: [.init(name: "state", value: "open"), .init(name: "head", value: owner + ":" + preview.source),
                        .init(name: "base", value: preview.target), .init(name: "per_page", value: "100"),
                        .init(name: "page", value: String(page))])
            for item in batch where item.head.ref == preview.source && item.base.ref == preview.target &&
                item.head.repo?.full_name.lowercased() == preview.repository.lowercased() &&
                item.base.repo?.full_name.lowercased() == preview.repository.lowercased() && item.state == "open" {
                guard found == nil else { throw AppError(text: "找到多个匹配 PR，请到 GitHub 核实。") }
                found = item
            }
            if batch.count < 100 {
                try await remoteBranchMergeValidate(preview)
                if let found {
                    let fresh = try await remoteBranchMergePull(preview, number: found.number)
                    guard RemoteBranchMergeRules.matches(fresh, preview), fresh.state == "open", fresh.merged == false else {
                        throw AppError(text: "已有 PR 已变化，请重新预览。")
                    }
                    try await remoteBranchMergeValidate(preview)
                    return fresh
                }
                return nil
            }
        }
        throw AppError(text: "PR 列表分页不完整，不能安全创建重复 PR。")
    }
    func remoteBranchMergeCreate(_ preview: RemoteBranchMergePreview, title: String) async throws -> RemoteBranchMergePR {
        let title = try RemoteBranchMergeRules.title(title)
        try await remoteBranchMergePermission(preview, squash: false)
        try await remoteBranchMergeValidate(preview)
        let data = try await remoteBranchMergeData(preview.repository, suffix: "/pulls", method: "POST",
            object: ["head": preview.source, "base": preview.target, "title": title])
        let pr = try JSONDecoder().decode(RemoteBranchMergePR.self, from: data)
        guard RemoteBranchMergeRules.matches(pr, preview), pr.state == "open" else {
            throw AppError(text: "创建响应与预览不符；PR 可能已创建，请只读刷新核实，勿重复创建。")
        }
        try await remoteBranchMergeValidate(preview)
        return pr
    }
    private func remoteBranchMergePermission(_ preview: RemoteBranchMergePreview, squash: Bool) async throws {
        let repo = try await mergeRead(MergeRepository.self, repo: preview.repository, suffix: "")
        guard repo.full_name.lowercased() == preview.repository.lowercased(), repo.permissions?.push == true else {
            throw AppError(text: "没有已确认的仓库写入权限。Token 需要 Contents: write 和 Pull requests: write。")
        }
        if squash {
            guard repo.allow_squash_merge == true else { throw AppError(text: "仓库未确认允许 Squash 合并。") }
            guard repo.delete_branch_on_merge == false else {
                throw AppError(text: "仓库开启了合并后自动删除分支，或该设置不可读取；为保留来源分支，已停止。请先在 GitHub 关闭此选项后重试，App 不会自行修改仓库设置。")
            }
        }
    }

    private struct MergeStatuses: Decodable {
        struct Status: Decodable { let context: String; let state: String }
        let sha: String
        let total_count: Int
        let statuses: [Status]
    }
    private struct MergeRuns: Decodable {
        struct Run: Decodable { let id: Int; let head_sha: String; let name: String; let status: String; let conclusion: String? }
        let total_count: Int
        let check_runs: [Run]
    }
    func remoteBranchMergeChecks(_ preview: RemoteBranchMergePreview) async throws -> RemoteBranchMergeChecks {
        var contexts: [String: String] = [:], runs: [MergeRuns.Run] = []
        var statusTotal: Int?, runTotal: Int?, statusRead = 0
        var statusComplete = false, runsComplete = false
        for page in 1...50 {
            let result = try await mergeRead(MergeStatuses.self, repo: preview.repository,
                suffix: "/commits/" + preview.sourceSHA + "/status",
                query: [.init(name: "per_page", value: "100"), .init(name: "page", value: String(page))])
            guard result.sha == preview.sourceSHA, result.total_count >= 0,
                  statusTotal == nil || statusTotal == result.total_count else { throw AppError(text: "提交状态分页已变化。") }
            statusTotal = result.total_count; statusRead += result.statuses.count
            for item in result.statuses {
                guard !item.context.isEmpty, contexts[item.context] == nil else { throw AppError(text: "提交状态重复或不完整。") }
                contexts[item.context] = item.state
            }
            if statusRead == result.total_count { statusComplete = true; break }
            guard !result.statuses.isEmpty, statusRead < result.total_count else { throw AppError(text: "提交状态分页不完整。") }
        }
        for page in 1...50 {
            let result = try await mergeRead(MergeRuns.self, repo: preview.repository,
                suffix: "/commits/" + preview.sourceSHA + "/check-runs",
                query: [.init(name: "filter", value: "latest"), .init(name: "per_page", value: "100"), .init(name: "page", value: String(page))])
            guard result.total_count >= 0, runTotal == nil || runTotal == result.total_count,
                  result.check_runs.allSatisfy({ $0.head_sha == preview.sourceSHA && $0.id > 0 && !$0.name.isEmpty }) else {
                throw AppError(text: "检查分页或提交已变化。")
            }
            runTotal = result.total_count; runs += result.check_runs
            if runs.count == result.total_count { runsComplete = true; break }
            guard !result.check_runs.isEmpty, runs.count < result.total_count else { throw AppError(text: "检查分页不完整。") }
        }
        guard statusComplete, runsComplete, Set(runs.map(\.id)).count == runs.count else {
            throw AppError(text: "状态或检查达到分页上限或重复，无法确认。")
        }
        var reasons = contexts.sorted(by: { $0.key < $1.key }).compactMap { $0.value == "success" ? nil : "状态 \($0.key)：\($0.value)" }
        reasons += runs.compactMap { $0.status == "completed" && $0.conclusion == "success" ? nil : "检查 \($0.name)：\($0.conclusion ?? $0.status)" }
        return .init(statusCount: contexts.count, checkRunCount: runs.count, blockReasons: reasons)
    }
    func remoteBranchMergeGate(_ preview: RemoteBranchMergePreview, number: Int) async throws -> RemoteBranchMergeChecks {
        try await remoteBranchMergePermission(preview, squash: true)
        try await remoteBranchMergeValidate(preview)
        let checks = try await remoteBranchMergeChecks(preview)
        let pr = try await remoteBranchMergePull(preview, number: number)
        let reasons = RemoteBranchMergeRules.prReasons(pr, preview) + checks.blockReasons
        guard reasons.isEmpty else { throw AppError(text: reasons.joined(separator: "\n")) }
        try await remoteBranchMergeValidate(preview)
        return checks
    }
    func remoteBranchMergeSquash(_ confirmation: RemoteBranchMergeConfirmation) async throws -> String {
        guard confirmation.session == remoteBranchMergeSession else { throw AppError(text: "账号会话已失效。") }
        let title = try RemoteBranchMergeRules.title(confirmation.title)
        _ = try await remoteBranchMergeGate(confirmation.preview, number: confirmation.pullNumber)
        // REST pins only the head SHA. The base can still move after this final read; GitHub rules remain authoritative.
        try await remoteBranchMergeValidate(confirmation.preview)
        let bytes = try await remoteBranchMergeData(confirmation.preview.repository, suffix: "/pulls/\(confirmation.pullNumber)/merge", method: "PUT",
            object: ["sha": confirmation.preview.sourceSHA, "merge_method": "squash", "commit_title": title])
        struct Result: Decodable { let merged: Bool; let sha: String?; let message: String? }
        let result = try JSONDecoder().decode(Result.self, from: bytes)
        guard result.merged, let sha = result.sha, RemoteBranchMergeRules.sha(sha) else {
            throw AppError(text: "未确认合并成功，请只读核实 PR：" + (result.message ?? "响应不完整"))
        }
        let fresh = try await remoteBranchMergePull(confirmation.preview, number: confirmation.pullNumber)
        guard fresh.number == confirmation.pullNumber, fresh.head.ref == confirmation.preview.source,
              fresh.base.ref == confirmation.preview.target, fresh.head.sha == confirmation.preview.sourceSHA,
              fresh.head.repo?.full_name.lowercased() == confirmation.preview.repository.lowercased(),
              fresh.base.repo?.full_name.lowercased() == confirmation.preview.repository.lowercased(),
              fresh.state == "closed", fresh.merged == true, fresh.merge_commit_sha == sha else {
            throw AppError(text: "合并响应尚未通过新鲜 PR 读取验证；请只读核实，勿重复合并。")
        }
        let retainedSource = try await mergeHead(confirmation.preview.repository, branch: confirmation.preview.source)
        guard retainedSource == confirmation.preview.sourceSHA else {
            throw AppError(text: "PR 已合并，但来源分支的保留状态或 SHA 未能确认，请在 GitHub 核实；不会重复合并。")
        }
        return sha
    }
}

// Disk-backed bounded transport: refuses redirects, caps advertised and streamed bytes.
final class RemoteBranchMergeBudget: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let limit = 8 * 1024 * 1024
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.limit || totalBytesExpectedToWrite > Self.limit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

@MainActor
final class RemoteBranchMergeState: ObservableObject {
    @Published private(set) var preview: RemoteBranchMergePreview?
    @Published private(set) var pull: RemoteBranchMergePR?
    @Published private(set) var checks: RemoteBranchMergeChecks?
    @Published private(set) var confirmation: RemoteBranchMergeConfirmation?
    @Published private(set) var busy = false
    @Published private(set) var failure = ""
    @Published private(set) var result = ""
    @Published private(set) var readOnly = false
    private var createAttempted = false
    private var mergeAttempted = false
    private var lifetime = UUID()
    func invalidate() { lifetime = UUID(); confirmation = nil }
    private func valid(_ api: GitHub, _ session: RemoteBranchMergeSession, _ ticket: UUID) throws {
        try Task.checkCancellation()
        guard api.isCurrentSession, api.remoteBranchMergeSession == session, lifetime == ticket else { throw AppError(text: "会话已失效，请重新打开。") }
    }
    func load(api: GitHub, repo: String, source: String, target: String) async {
        guard !busy, !readOnly, !mergeAttempted, result.isEmpty else { return }
        busy = true; failure = ""; confirmation = nil; preview = nil; pull = nil; checks = nil
        let ticket = lifetime, session = api.remoteBranchMergeSession
        defer { busy = false }
        do {
            let value = try await api.remoteBranchMergePreview(repo: repo, source: source, target: target)
            try valid(api, session, ticket); preview = value
        } catch { failure = error.localizedDescription }
    }
    func preparePull(api: GitHub, title: String) async {
        guard !busy, !readOnly, !createAttempted, let preview, pull == nil else { return }
        busy = true; failure = ""; confirmation = nil
        let ticket = lifetime, session = api.remoteBranchMergeSession
        defer { busy = false }
        do {
            let title = try RemoteBranchMergeRules.title(title)
            let existing = try await api.remoteBranchMergeExisting(preview)
            try valid(api, session, ticket)
            if let existing { pull = existing }
            else {
                createAttempted = true; readOnly = true
                let created = try await api.remoteBranchMergeCreate(preview, title: title)
                try valid(api, session, ticket); pull = created; readOnly = false
            }
        } catch { failure = error.localizedDescription }
    }
    func refreshGate(api: GitHub, title: String) async {
        guard !busy, !readOnly, !mergeAttempted, let preview, let pull else { return }
        busy = true; failure = ""; confirmation = nil; checks = nil
        let ticket = lifetime, session = api.remoteBranchMergeSession
        defer { busy = false }
        do {
            let title = try RemoteBranchMergeRules.title(title)
            let value = try await api.remoteBranchMergeGate(preview, number: pull.number)
            try valid(api, session, ticket); checks = value
            confirmation = .init(preview: preview, pullNumber: pull.number, title: title, session: session)
        } catch { failure = error.localizedDescription }
    }
    func dismissConfirmation() { confirmation = nil }
    func submit(api: GitHub, confirmation frozen: RemoteBranchMergeConfirmation) async {
        guard !busy, !readOnly, !mergeAttempted, confirmation?.id == frozen.id else { return }
        confirmation = nil; busy = true; mergeAttempted = true; readOnly = true; failure = ""
        let ticket = lifetime, session = api.remoteBranchMergeSession
        defer { busy = false }
        do {
            try valid(api, frozen.session, ticket)
            let sha = try await api.remoteBranchMergeSquash(frozen)
            try valid(api, session, ticket); result = "已验证 Squash 合并：\(sha)；来源分支保留。"
        } catch { failure = "合并未确认；不会自动重发。请只读核实 PR。\n" + error.localizedDescription }
    }
    func reconcile(api: GitHub) async {
        guard !busy, let preview else { return }
        busy = true; confirmation = nil; failure = ""
        let ticket = lifetime, session = api.remoteBranchMergeSession
        defer { busy = false }
        do {
            let value: RemoteBranchMergePR?
            if let pull { value = try await api.remoteBranchMergePull(preview, number: pull.number) }
            else { value = try await api.remoteBranchMergeExisting(preview) }
            try valid(api, session, ticket)
            pull = value
            if let value {
                result = "只读核实：PR #\(value.number)，状态 \(value.state)，merged=\(value.merged.map(String.init) ?? "unknown")，合并 SHA：\(value.merge_commit_sha ?? "未知")。来源分支保留；未重发写请求。"
            } else { failure = "未找到匹配的打开 PR；创建结果仍不确定，请到 GitHub 核实（包括已关闭 PR）。本会话禁止重发。" }
        } catch { failure = "只读核实失败；禁止自动重发。\n" + error.localizedDescription }
    }
}
