import Foundation
import Combine

enum UserFollowRules {
    static func login(_ input: String) throws -> String {
        guard !input.isEmpty, input.utf8.count <= 39,
              input.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else {
            throw AppError(text: "无效的 GitHub 用户名。")
        }
        return input.lowercased()
    }
    static func status(_ code: Int, checking: Bool) throws -> Bool {
        if code == 204 { return true }
        if checking && code == 404 { return false }
        if code == 401 { throw AppError(text: "登录已失效，请重新登录账号。") }
        if code == 403 { throw AppError(text: "无法操作关注：请检查请求限制及权限。浏览器登录需开启关注授权；Token 需 user:follow 或 Followers 写入权限。") }
        if code == 429 { throw AppError(text: "请求过于频繁，请稍后重试。") }
        throw AppError(text: "关注请求失败，请稍后重试（\(code)）。")
    }
}

/// Shared only by profiles belonging to this GitHub account/session. No polling or optimistic writes.
@MainActor final class UserFollowStore: ObservableObject {
    private weak var api: GitHub?
    @Published private(set) var revision = 0
    private var states: [String: (Date, Bool)] = [:]
    private var pending: [String: (UUID, Task<Bool, Error>)] = [:]
    private var busy: Set<String> = []
    init(api: GitHub) { self.api = api }
    func known(_ login: String) -> Bool? { api?.isCurrentSession == true ? states[login.lowercased()]?.1 : nil }
    func isBusy(_ login: String) -> Bool { busy.contains(login.lowercased()) }
    func invalidate() {
        pending.values.forEach { $0.1.cancel() }; pending.removeAll(); states.removeAll(); busy.removeAll(); revision += 1
    }
    private func remember(_ login: String, _ value: Bool) {
        if states.count >= 128, let oldest = states.min(by: { $0.value.0 < $1.value.0 })?.key { states[oldest] = nil }
        states[login] = (Date(), value); revision += 1
    }
    func load(_ input: String, refresh: Bool = false) async throws -> Bool {
        guard let api else { throw CancellationError() }
        let viewer = try api.followIdentity(), login = try UserFollowRules.login(input)
        guard login != viewer else { throw AppError(text: "不能关注自己。") }
        if busy.contains(login), let value = known(login) { return value }
        if !refresh, let entry = states[login], Date().timeIntervalSince(entry.0) < 300 { return entry.1 }
        if let task = pending[login]?.1 { return try await task.value }
        let id = UUID()
        let task = Task { [weak self] () async throws -> Bool in
            defer { if self?.pending[login]?.0 == id { self?.pending[login] = nil } }
            let value = try await api.followRequest(login, method: "GET")
            try Task.checkCancellation(); _ = try api.followIdentity()
            guard let self, self.pending[login]?.0 == id else { throw CancellationError() }
            self.remember(login, value)
            return value
        }
        pending[login] = (id, task)
        return try await task.value
    }
    func setFollowing(_ input: String, desired: Bool) async throws {
        guard let api else { throw CancellationError() }
        let viewer = try api.followIdentity(), login = try UserFollowRules.login(input)
        guard login != viewer, known(login) != nil, !busy.contains(login) else { return }
        busy.insert(login); revision += 1
        defer { busy.remove(login); revision += 1 }
        // Recheck before writing: another client may have changed the relationship since this page opened.
        pending[login]?.1.cancel(); pending[login] = nil
        let current = try await api.followRequest(login, method: "GET")
        try Task.checkCancellation(); _ = try api.followIdentity()
        remember(login, current)
        guard current != desired else { return }
        _ = try await api.followRequest(login, method: desired ? "PUT" : "DELETE")
        try Task.checkCancellation(); _ = try api.followIdentity()
        remember(login, desired)
    }
}
