import Foundation
import Combine

/// Only the exact GET /user/starred/{owner}/{repo} endpoint interprets 404 as false.
enum RepositoryStarRules {
    static func status(_ code: Int, checking: Bool) throws -> Bool {
        if code == 204 { return true }
        if checking && code == 404 { return false }
        if code == 401 { throw AppError(text: "登录已失效，请重新登录账号") }
        if code == 403 { throw AppError(text: "无法操作星标：请检查 Token 星标权限或稍后重试") }
        if code == 429 { throw AppError(text: "请求过于频繁，请稍后重试") }
        throw AppError(text: "星标请求失败，请稍后重试（\(code)）")
    }
    static func clampedCount(_ count: Int?) -> Int? { count.map { max(0, $0) } }
}

struct RepositoryStarTarget {
    let fullName: String
    let accountID: String
    let generation: UUID
    let desired: Bool
}

@MainActor
final class RepositoryStarStore: ObservableObject {
    private unowned let api: GitHub
    @Published private(set) var revision = 0
    private var states: [String: (Date, Bool)] = [:]
    private var pending: [String: Task<Bool, Error>] = [:]
    private var busy: Set<String> = []
    private var metadata: [String: Repository] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(api: GitHub) { self.api = api }
    private func key(_ name: String) -> String { name.lowercased() }
    func known(_ name: String) -> Bool? {
        let k = key(name)
        if api.cachedCollection(.starred)?.contains(where: { key($0.full_name) == k }) == true { return true }
        guard let entry = states[k], Date().timeIntervalSince(entry.0) < 300 else { return nil }
        return entry.1
    }
    func display(_ repository: Repository) -> Repository { metadata[key(repository.full_name)] ?? repository }
    func isBusy(_ name: String) -> Bool { busy.contains(key(name)) }
    func invalidate() {
        pending.values.forEach { $0.cancel() }; pending.removeAll()
        states.removeAll(); metadata.removeAll(); busy.removeAll()
        revision += 1
    }
    func seed(_ repositories: [Repository]) {
        // A refreshed complete list supersedes stale known-true state.
        states.removeAll()
        for repository in repositories.prefix(512) { remember(repository.full_name, true) }
    }
    private func remember(_ name: String, _ value: Bool) {
        if states.count >= 512, let oldest = states.min(by: { $0.value.0 < $1.value.0 })?.key { states[oldest] = nil }
        states[key(name)] = (Date(), value)
    }
    private func acquire() async {
        if active < 3 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
    }
    func status(_ input: String) async throws -> Bool {
        try api.requireStarSession()
        let name = try RepositoryInput.parse(input), k = key(name)
        if let value = known(name) { return value }
        if let task = pending[k] { return try await task.value }
        let task = Task<Bool, Error> {
            await self.acquire(); defer { self.release() }
            try Task.checkCancellation(); try self.api.requireStarSession()
            return try await self.api.starRequest(name, method: "GET")
        }
        pending[k] = task
        defer { pending[k] = nil }
        let result = try await task.value
        try api.requireStarSession()
        remember(name, result)
        return result
    }
    func target(_ input: String, desired: Bool) throws -> RepositoryStarTarget {
        try api.requireStarSession()
        let name = try RepositoryInput.parse(input)
        guard let current = known(name), current != desired else { throw AppError(text: "星标状态已变化，请重新打开菜单") }
        return RepositoryStarTarget(fullName: name, accountID: api.accountID,
                                    generation: AccountStore.generation, desired: desired)
    }
    func perform(_ fixed: RepositoryStarTarget, repository: Repository?) async throws {
        try api.requireStarSession()
        guard fixed.accountID == api.accountID, fixed.generation == AccountStore.generation else { throw AppError(text: "账号已切换，请重新打开菜单") }
        let k = key(fixed.fullName)
        guard !busy.contains(k), known(fixed.fullName) == !fixed.desired else { return }
        busy.insert(k); revision += 1
        defer { busy.remove(k); revision += 1 }
        // No optimistic state changes: only GitHub's exact 204 acknowledges the write.
        _ = try await api.starRequest(fixed.fullName, method: fixed.desired ? "PUT" : "DELETE")
        try api.requireStarSession()
        guard fixed.generation == AccountStore.generation else { return }
        remember(fixed.fullName, fixed.desired)
        // Count is fetched from the real repository endpoint, never synthesized +/- 1.
        let fresh = try? await api.repository(fixed.fullName)
        try api.requireStarSession()
        if let fresh {
            if metadata.count >= 512 { metadata.removeAll() }
            metadata[k] = fresh
        } else { metadata[k] = nil }
        let supplied = repository.flatMap { key($0.full_name) == k ? $0 : nil }
        api.applyStarChange(name: fixed.fullName, starred: fixed.desired, repository: fresh ?? supplied)
        revision += 1
    }
}
