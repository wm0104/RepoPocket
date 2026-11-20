import Foundation

enum CommitFileRules {
    struct Failure: LocalizedError { let errorDescription: String? }
    struct Version: Hashable {
        let sha: String
        let path: String
    }
    struct Versions {
        let before: Version?
        let after: Version?
        var notice: String? = nil
    }

    private static let invalidCommit = "提交标识不完整，请返回重新加载提交详情。"
    private static let unprovenBefore = "无法验证修改前版本的提交或路径，未读取其他版本。"
    static func isCommitSHA(_ sha: String) -> Bool {
        sha.utf8.count == 40 && sha.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }
    static func validate(commitSHA: String, status: String) throws {
        guard isCommitSHA(commitSHA) else { throw Failure(errorDescription: invalidCommit) }
        guard status != "removed", status != "deleted" else {
            throw Failure(errorDescription: "该文件已在此提交中删除，此版本没有完整文件；仍可返回查看删除差异。")
        }
    }
    private static func firstParent(commitSHA: String, parents: [DesktopCommit.Parent]?) -> String? {
        guard isCommitSHA(commitSHA), let sha = parents?.first?.sha, isCommitSHA(sha),
              sha.lowercased() != commitSHA.lowercased() else { return nil }
        return sha
    }
    static func mergeParent(commitSHA: String, parents: [DesktopCommit.Parent]?) -> String? {
        guard let parents, parents.count > 1 else { return nil }
        return firstParent(commitSHA: commitSHA, parents: parents)
    }
    static func versions(commitSHA: String, parents: [DesktopCommit.Parent]?, file: DesktopCommit.File,
                         comparison: CommitMediaComparison? = nil) -> Versions {
        guard isCommitSHA(commitSHA) else { return .init(before: nil, after: nil, notice: invalidCommit) }
        guard let existsAfter = Self.existsAfter(file.status), !file.filename.isEmpty else {
            return .init(before: nil, after: nil, notice: "无法验证此差异的文件状态或路径。")
        }
        let after = existsAfter ? Version(sha: commitSHA, path: file.filename) : nil
        let unproven = Versions(before: nil, after: after, notice: unprovenBefore)
        if parents?.isEmpty == true && file.status == "added" { return .init(before: nil, after: after) }
        guard let parent = firstParent(commitSHA: commitSHA, parents: parents) else { return unproven }
        let evidence: DesktopCommit.File
        if let parents, parents.count > 1 {
            guard let comparison, comparison.base_commit.sha.lowercased() == parent.lowercased(),
                  comparison.merge_base_commit.sha.lowercased() == parent.lowercased(),
                  let files = comparison.files, files.count < 300 else { return unproven }
            // Only the comparison's row proves the first-parent path. Other rows,
            // including matches by previous filename, do not prove this change.
            let matches = files.filter { $0.filename.utf8.elementsEqual(file.filename.utf8) }
            guard matches.count == 1, let comparedAfter = Self.existsAfter(matches[0].status),
                  comparedAfter == existsAfter else { return unproven }
            evidence = matches[0]
        } else {
            evidence = file
        }
        switch evidence.status {
        case "added", "copied":
            return .init(before: nil, after: after)
        case "renamed":
            guard let old = evidence.previous_filename, !old.isEmpty,
                  !old.utf8.elementsEqual(evidence.filename.utf8) else { return unproven }
            return .init(before: .init(sha: parent, path: old), after: after)
        default:
            guard evidence.previous_filename == nil else { return unproven }
            return .init(before: .init(sha: parent, path: evidence.filename), after: after)
        }
    }
    private static func existsAfter(_ status: String) -> Bool? {
        switch status {
        case "removed", "deleted": return false
        case "added", "copied", "renamed", "modified", "changed": return true
        default: return nil
        }
    }
}
