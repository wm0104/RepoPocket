import Foundation

// Process-only UI state. Never contains credentials and is never serialized.
struct WorkspaceSelectionScope: Hashable {
    let accountID: String
    let workspace: String
    let repository: String
    let branch: String
    init(accountID: String, folder: URL, repository: String, branch: String) {
        self.accountID = accountID
        workspace = folder.resolvingSymlinksInPath().standardizedFileURL.path
        self.repository = repository.lowercased()
        self.branch = branch
    }
}

struct WorkspaceSelectionSession {
    private var selections: [WorkspaceSelectionScope: Set<String>] = [:]
    private var folders: [String: URL] = [:]
    func selected(in scope: WorkspaceSelectionScope) -> Set<String> { selections[scope] ?? [] }
    mutating func toggle(_ path: String, in scope: WorkspaceSelectionScope) {
        if selections[scope, default: []].contains(path) { selections[scope]?.remove(path) }
        else { selections[scope, default: []].insert(path) }
    }
    // Only call after a complete, validated scan. Deletions are valid change paths.
    mutating func scanSucceeded(_ availableChanges: Set<String>, in scope: WorkspaceSelectionScope) {
        selections[scope] = selected(in: scope).intersection(availableChanges)
    }
    mutating func commitSucceeded(_ committed: Set<String>, in scope: WorkspaceSelectionScope) {
        selections[scope] = selected(in: scope).subtracting(committed)
    }
    // Explicit verified first association only. Never copy across repositories/branches.
    mutating func associateLocalSelection(from local: WorkspaceSelectionScope, to remote: WorkspaceSelectionScope) {
        guard local.accountID == remote.accountID, local.workspace == remote.workspace,
              local.repository.isEmpty, local.branch.isEmpty,
              !remote.repository.isEmpty, !remote.branch.isEmpty else { return }
        selections[remote] = selected(in: remote).union(selected(in: local))
        selections[local] = nil
    }
    // Called only after a successful physical+metadata rename; preserve each isolated scope.
    mutating func workspaceRenamed(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path
        let matching = selections.filter { $0.key.workspace == oldPath }
        for (scope, paths) in matching {
            let replacement = WorkspaceSelectionScope(accountID: scope.accountID, folder: new, repository: scope.repository, branch: scope.branch)
            selections[replacement] = Set(paths.map { new.lastPathComponent + "/" + $0.dropFirst(old.lastPathComponent.count + 1) })
            selections[scope] = nil
        }
        for (account, remembered) in folders where remembered.standardizedFileURL.path == oldPath { folders[account] = new }
    }
    mutating func remember(_ folder: URL?, accountID: String) { folders[accountID] = folder }
    // A successful directory scan is the only authority for removed workspaces.
    mutating func reconcileWorkspaces(_ available: Set<String>, accountID: String) {
        selections = selections.filter { $0.key.accountID != accountID || available.contains($0.key.workspace) }
        if let folder = folders[accountID], !available.contains(folder.resolvingSymlinksInPath().standardizedFileURL.path) {
            folders[accountID] = nil
        }
    }
    func rememberedFolder(accountID: String) -> URL? { folders[accountID] }
}

enum RefreshFailure {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let e = error as NSError
        return e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled
    }
    /// The system cellular-data prompt and flaky links can drop a first attempt;
    /// those failures deserve one silent retry instead of re-asking the user.
    static func isTransient(_ error: Error) -> Bool {
        let e = error as NSError
        guard e.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                NSURLErrorDataNotAllowed].contains(e.code)
    }
}
