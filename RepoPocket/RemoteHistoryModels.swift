import Foundation

struct RemoteHistoryRefRejection: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct RemoteHistoryCommit: Codable, Identifiable {
    struct Object: Codable { let sha: String }
    struct Author: Codable {
        let name: String
        let email: String
        let date: String
    }
    struct Info: Codable {
        let message: String
        let tree: Object
        let author: Author
        let committer: Author
    }
    let sha: String
    let commit: Info
    let parents: [Object]
    var id: String { sha }
}

struct RemoteHistorySnapshot: Codable {
    let accountID: String
    let generation: UUID
    let repository: String
    let repositoryID: String
    let branch: String
    let head: String
    let commits: [RemoteHistoryCommit]
    var tree: String { commits.first { $0.sha == head }?.commit.tree.sha ?? "" }
}

enum RemoteHistoryAction: String, Codable { case clear, squash, versions }

struct RemoteHistoryVersion: Codable, Identifiable, Equatable {
    var id = UUID()
    var version = ""
    var finalCommit = ""
    var notes = ""
}

struct RemoteHistoryStep: Codable {
    let key: String
    let tree: String
    let parents: [String]
    let message: String
    let author: RemoteHistoryCommit.Author?
    let committer: RemoteHistoryCommit.Author?
    let recreate: Bool
}

struct RemoteHistoryCreatedCommit: Decodable {
    let sha: String
    let tree: RemoteHistoryCommit.Object
    let parents: [RemoteHistoryCommit.Object]
    let message: String
}

struct RemoteHistoryPreview: Identifiable {
    let id = UUID()
    let snapshot: RemoteHistorySnapshot
    let action: RemoteHistoryAction
    let selected: Set<String>
    let steps: [RemoteHistoryStep]
    let resultKey: String
    var versions: [RemoteHistoryVersion] = []
    var baseline: String? = nil
    var recreatedCount: Int { steps.filter(\.recreate).count }
}

enum RemoteHistoryRules {
    static let maximumCommits = 5000
    static let snapshotMessage = "整理提交历史：保留当前代码快照"
    static func topologicalOrder(_ snapshot: RemoteHistorySnapshot) throws -> [RemoteHistoryCommit] {
        let commits = snapshot.commits
        guard !commits.isEmpty, commits.count <= maximumCommits,
              Set(commits.map(\.sha)).count == commits.count,
              commits.contains(where: { $0.sha == snapshot.head }),
              commits.allSatisfy({ RemoteBranchMergeRules.sha($0.sha) && RemoteBranchMergeRules.sha($0.commit.tree.sha) }) else {
            throw AppError(text: "提交历史不完整、重复或超过5000条，本次不整理。")
        }
        let objects = Dictionary(uniqueKeysWithValues: commits.map { ($0.sha, $0) })
        var children: [String: [String]] = [:], remaining: [String: Int] = [:]
        for commit in commits {
            let parents = commit.parents.map(\.sha)
            guard Set(parents).count == parents.count, parents.allSatisfy({ objects[$0] != nil }) else {
                throw AppError(text: "未取得完整祖先历史，不能将已加载部分当成全部。")
            }
            remaining[commit.sha] = parents.count
            for parent in parents { children[parent, default: []].append(commit.sha) }
        }
        var reachable: Set<String> = [], pending = [snapshot.head]
        while let sha = pending.popLast() {
            if reachable.insert(sha).inserted { pending += objects[sha]?.parents.map(\.sha) ?? [] }
        }
        guard reachable.count == commits.count else { throw AppError(text: "历史包含当前HEAD不可达的记录，未继续。") }
        var queue = commits.filter { $0.parents.isEmpty }.map(\.sha), index = 0
        var ordered: [RemoteHistoryCommit] = []
        while index < queue.count {
            let sha = queue[index]; index += 1
            guard let commit = objects[sha] else { throw AppError(text: "提交图无效。") }
            ordered.append(commit)
            for child in children[sha] ?? [] {
                remaining[child, default: 0] -= 1
                if remaining[child] == 0 { queue.append(child) }
            }
        }
        guard ordered.count == commits.count else { throw AppError(text: "提交图无法完整排序，未继续。") }
        return ordered
    }
    static func preview(_ snapshot: RemoteHistorySnapshot, selected: Set<String>, action: RemoteHistoryAction, message: String) throws -> RemoteHistoryPreview {
        guard action != .versions else { throw AppError(text: "按版本整理需要先确认每版最终快照和更新要点。") }
        let ordered = try topologicalOrder(snapshot)
        guard !selected.isEmpty, selected.isSubset(of: Set(ordered.map(\.sha))) else { throw AppError(text: "请选择当前分支中的提交记录。") }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.utf8.count <= 60_000 else { throw AppError(text: "新提交说明不能为空，且不能超过60 KB。") }
        func snapshotStep(parents: [String]) -> RemoteHistoryStep {
            .init(key: "current-snapshot", tree: snapshot.tree, parents: parents, message: message, author: nil, committer: nil, recreate: true)
        }
        if selected.count == ordered.count {
            return .init(snapshot: snapshot, action: action, selected: selected, steps: [snapshotStep(parents: [])], resultKey: "current-snapshot")
        }
        if action == .squash {
            guard selected.count >= 2 else { throw AppError(text: "请至少选择最新连续的两条提交，或全选。") }
            let objects = Dictionary(uniqueKeysWithValues: ordered.map { ($0.sha, $0) })
            var cursor = snapshot.head, count = 0
            while selected.contains(cursor), let commit = objects[cursor] {
                guard commit.parents.count == 1 else { throw AppError(text: "所选范围跨越合并点或根提交；请选择最新线性连续记录，或全选生成快照。") }
                count += 1; cursor = commit.parents[0].sha
            }
            guard count == selected.count else { throw AppError(text: "只能压缩从最新提交开始的连续记录，不会夹带未选记录。") }
            return .init(snapshot: snapshot, action: action, selected: selected, steps: [snapshotStep(parents: [cursor])], resultKey: "current-snapshot")
        }
        var mapping: [String: [String]] = [:], rewritten: Set<String> = [], steps: [RemoteHistoryStep] = []
        for commit in ordered {
            var seen: Set<String> = []
            let parents = commit.parents.flatMap { mapping[$0.sha] ?? [] }.filter { seen.insert($0).inserted }
            if selected.contains(commit.sha) { mapping[commit.sha] = parents; continue }
            let recreate = parents != commit.parents.map(\.sha) || parents.contains { rewritten.contains($0) }
            if recreate { rewritten.insert(commit.sha) }
            steps.append(.init(key: commit.sha, tree: commit.commit.tree.sha, parents: parents,
                message: commit.commit.message, author: commit.commit.author, committer: commit.commit.committer, recreate: recreate))
            mapping[commit.sha] = [commit.sha]
        }
        let result: String
        if selected.contains(snapshot.head) {
            steps.append(snapshotStep(parents: mapping[snapshot.head] ?? [])); result = "current-snapshot"
        } else { result = snapshot.head }
        return .init(snapshot: snapshot, action: action, selected: selected, steps: steps, resultKey: result)
    }

    static func versionPreview(_ snapshot: RemoteHistorySnapshot, baseline: String?, versions: [RemoteHistoryVersion]) throws -> RemoteHistoryPreview {
        let ordered = try topologicalOrder(snapshot)
        let objects = Dictionary(uniqueKeysWithValues: ordered.map { ($0.sha, $0) })
        guard !versions.isEmpty, versions.count <= 100,
              Set(versions.map(\.id)).count == versions.count,
              versions.last?.finalCommit == snapshot.head else {
            throw AppError(text: "请按旧到新确认1至100个版本，最后一版必须使用当前HEAD的完整代码快照。")
        }
        func ancestors(_ sha: String) throws -> Set<String> {
            guard objects[sha] != nil else { throw AppError(text: "保留基线或版本最终快照不在当前分支历史中。") }
            var visited: Set<String> = [], pending = [sha]
            while let current = pending.popLast() {
                if visited.insert(current).inserted { pending += objects[current]?.parents.map(\.sha) ?? [] }
            }
            return visited
        }
        let preserved = try baseline.map { try ancestors($0) } ?? []
        var previous = baseline, previousKey = baseline, titles: Set<String> = []
        var normalized: [RemoteHistoryVersion] = [], steps: [RemoteHistoryStep] = []
        for var version in versions {
            version.version = version.version.trimmingCharacters(in: .whitespacesAndNewlines)
            version.notes = version.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard version.version.range(of: #"^[vV]?[0-9][0-9A-Za-z.+:~_-]{0,79}$"#, options: .regularExpression) != nil,
                  titles.insert(version.version).inserted else {
                throw AppError(text: "提交标题只能填写不重复的版本号，不能包含换行或过程说明。")
            }
            let message = version.version + "\n\n" + version.notes
            guard !version.notes.isEmpty, !version.notes.contains("\0"), message.utf8.count <= 60_000 else {
                throw AppError(text: "请填写该版本最终保留的功能、优化和关键修复；版本号与更新要点合计不能超过60 KB。")
            }
            let reachable = try ancestors(version.finalCommit)
            if let previous {
                guard previous != version.finalCommit, reachable.contains(previous) else {
                    throw AppError(text: "各版本最终快照必须按祖先关系从旧到新排列，且位于保留基线之后；不会自动猜测版本边界。")
                }
            }
            guard let commit = objects[version.finalCommit] else { throw AppError(text: "版本最终快照无效。") }
            let key = "version-" + version.id.uuidString
            steps.append(.init(key: key, tree: commit.commit.tree.sha, parents: previousKey.map { [$0] } ?? [],
                message: message, author: nil, committer: nil, recreate: true))
            normalized.append(version); previous = version.finalCommit; previousKey = key
        }
        guard let resultKey = steps.last?.key else { throw AppError(text: "尚未确认版本。") }
        return .init(snapshot: snapshot, action: .versions, selected: Set(ordered.map(\.sha)).subtracting(preserved),
            steps: steps, resultKey: resultKey, versions: normalized, baseline: baseline)
    }
}
