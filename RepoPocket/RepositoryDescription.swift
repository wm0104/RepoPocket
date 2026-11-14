import Foundation

struct RepositoryDescriptionContext: Equatable {
    let accountID: String
    let generation: UUID
    let login: String
    let repositoryID: Int
    let fullName: String
}

// This feature deliberately edits only repositories owned by the signed-in user.
enum RepositoryDescriptionRules {
    static let permissionHelp = "只能编辑当前账号拥有且具备管理权限的仓库描述。Token 还需仓库管理写入权限（Administration: write）。"
    static func canEdit(_ repository: Repository, login: String, sessionMatches: Bool) -> Bool {
        guard sessionMatches, !login.isEmpty, repository.permissions?.admin == true,
              let owner = repository.owner?.login,
              owner.caseInsensitiveCompare(login) == .orderedSame else { return false }
        let parts = repository.full_name.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[1].isEmpty
            && String(parts[0]).caseInsensitiveCompare(login) == .orderedSame
    }
    static func validate(_ context: RepositoryDescriptionContext,
                         current: RepositoryDescriptionContext) throws {
        guard context == current else { throw AppError(text: "账号或仓库已变化，请重新打开编辑描述。") }
    }
    static func validateRepository(_ repository: Repository, context: RepositoryDescriptionContext) throws {
        guard repository.id == context.repositoryID,
              repository.full_name.caseInsensitiveCompare(context.fullName) == .orderedSame else {
            throw AppError(text: "仓库身份已变化，请重新打开编辑描述。")
        }
    }
    static func execute(context: RepositoryDescriptionContext, description: String,
                        current: () -> RepositoryDescriptionContext,
                        fetch: () async throws -> Repository,
                        update: (String) async throws -> Repository) async throws -> Repository {
        try validate(context, current: current())
        try Task.checkCancellation()
        let fresh = try await fetch()
        try validate(context, current: current())
        try validateRepository(fresh, context: context)
        guard canEdit(fresh, login: context.login, sessionMatches: true) else {
            throw AppError(text: permissionHelp)
        }
        try Task.checkCancellation()
        let updated = try await update(description)
        try validate(context, current: current())
        try Task.checkCancellation()
        try validateRepository(updated, context: context)
        return updated
    }
}
