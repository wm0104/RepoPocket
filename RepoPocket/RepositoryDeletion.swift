import Foundation

// Pure orchestration shared by the app and network-free CI mocks.
struct RepositoryDeletionContext: Equatable {
    let accountID: String
    let generation: UUID
    let repositoryID: Int
    let fullName: String
}

enum RepositoryDeletion {
    static let permissionHelp = "删除仓库需要管理员权限；Classic Token 需 delete_repo，细粒度 Token 需所选仓库的 Administration: write。请自行检查权限，本应用不会自动扩大权限。"
    static func validate(_ captured: RepositoryDeletionContext, current: RepositoryDeletionContext,
                         confirmation: String) throws {
        guard captured == current else { throw AppError(text: "账号或仓库已变化，请重新打开删除页面。") }
        guard confirmation == captured.fullName else { throw AppError(text: "请输入完整且完全匹配的 owner/repo 确认删除。") }
    }
    static func execute(context: RepositoryDeletionContext, confirmation: String,
                        current: () -> RepositoryDeletionContext,
                        fetch: () async throws -> Repository,
                        remove: () async throws -> Void) async throws -> String {
        try validate(context, current: current(), confirmation: confirmation)
        try Task.checkCancellation()
        let fresh = try await fetch()
        try validate(context, current: current(), confirmation: confirmation)
        guard fresh.id == context.repositoryID, fresh.full_name == context.fullName else {
            throw AppError(text: "仓库身份已变化，已阻止删除，请重新打开页面。")
        }
        guard fresh.permissions?.admin == true else { throw AppError(text: permissionHelp) }
        try Task.checkCancellation()
        try await remove()
        try validate(context, current: current(), confirmation: confirmation)
        return "已删除远端仓库 \(context.fullName)。本地工作区未删除。"
    }
}
