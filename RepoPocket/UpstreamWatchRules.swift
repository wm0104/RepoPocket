import Foundation

struct UpstreamWatch: Codable, Identifiable, Equatable {
    let repository: String
    let branch: String
    var seenHead: String?
    var seenBranches: [String]?
    var id: String { repository.lowercased() + ":" + branch }
}

struct UpstreamWatchUpdate {
    let head: String
    let branches: [String]
    let comparison: UpstreamCompare?
    let changed: Bool
    let newBranches: [String]
    var count: Int { comparison?.ahead_by ?? comparison?.total_commits ?? 0 }
}

enum UpstreamWatchRules {
    static func key(_ account: String) -> String { "RepoPocket.upstreamWatch.v1." + account }
    static func watch(repository: String, branch: String) throws -> UpstreamWatch {
        let target = try UpstreamSyncRules.target(repository: repository, branch: branch)
        return UpstreamWatch(repository: target.repository, branch: target.branch)
    }
    static func newBranches(seen: [String]?, current: [String]) -> [String] {
        guard let seen else { return [] }
        return Array(Set(current).subtracting(seen)).sorted()
    }
    static func comparePath(_ watch: UpstreamWatch, head: String) throws -> String? {
        guard let before = watch.seenHead, before != head else { return nil }
        guard UpstreamSyncRules.validSHA(before), UpstreamSyncRules.validSHA(head) else {
            throw AppError(text: "上游提交编号无效，请重新检查。")
        }
        return UpstreamSyncRules.repositoryPath(watch.repository) + "/compare/" + before + "..." + head
    }
    static func acknowledge(_ watch: UpstreamWatch, head: String, branches: [String]) -> UpstreamWatch {
        var value = watch
        value.seenHead = head
        value.seenBranches = branches
        return value
    }
}
