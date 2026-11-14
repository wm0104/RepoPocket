import Foundation

/// Independent from LocalGitStatus: a path can appear on BOTH sides with different content.
struct LocalGitStageStatus: Decodable {
    let head: String
    let reference: String
    let branch: String
    let indexFingerprint: String
    let staged: [LocalGitChange]
    let unstaged: [LocalGitChange]
    var arguments: [String: Any] {
        ["expectedHead": head, "expectedRef": reference, "indexFingerprint": indexFingerprint]
    }
    var canCommit: Bool { !staged.isEmpty && staged.allSatisfy { $0.blocked.isEmpty } }
    func arguments(selecting paths: Set<String>, staged side: Bool) -> [String: Any] {
        var args = arguments
        args["files"] = (side ? staged : unstaged).filter { paths.contains($0.path) }.map {
            ["path": $0.path, "fingerprint": $0.fingerprint]
        }
        return args
    }
}
