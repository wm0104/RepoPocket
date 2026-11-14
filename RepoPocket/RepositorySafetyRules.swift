import Foundation

enum RepositoryWriteRules {
    static func canWrite(push: Bool?, sessionMatches: Bool = true) -> Bool {
        sessionMatches && push == true
    }
}
enum RepositoryGroupRules {
    static func isOwned(_ fullName: String, login: String) -> Bool {
        guard !login.isEmpty, let owner = fullName.split(separator: "/").first else { return false }
        return String(owner).caseInsensitiveCompare(login) == .orderedSame
    }
}
enum UpdateNoticeRules {
    static let latestNanoseconds: UInt64 = 2_000_000_000
    static let failureNanoseconds: UInt64 = 6_000_000_000
}
