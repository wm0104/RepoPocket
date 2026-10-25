import SwiftUI

extension Notification.Name { static let releaseManagementChanged = Notification.Name("releaseManagementChanged") }
@MainActor enum ReleaseManagementChanges {
    static func changed(api: GitHub, repo: String, release: ManagedRelease? = nil, deletedReleaseID: Int? = nil) {
        api.invalidateManagedPresence(repo)
        var info: [String: Any] = ["repo": repo, "generation": AccountStore.generation]
        info["release"] = release
        info["deletedReleaseID"] = deletedReleaseID
        NotificationCenter.default.post(name: .releaseManagementChanged, object: nil,
            userInfo: info)
    }
}
@MainActor final class ReleasePresenceState: ObservableObject {
    @Published private(set) var exists = false
    private var token = UUID()
    private var task: Task<Void, Never>?
    func cancel() { token = UUID(); task?.cancel(); task = nil }
    func load(api: GitHub, repo: String, refresh: Bool = false) {
        cancel()
        let generation = AccountStore.generation
        let expected = UUID(); token = expected
        task = Task {
            do {
                let found = try await api.managedReleasePresence(repo, refresh: refresh)
                try Task.checkCancellation()
                guard token == expected, generation == AccountStore.generation, api.isCurrentSession else { return }
                exists = found
            } catch { /* Unknown is not falsely classified as an empty repository. */ }
        }
    }
    func reset() { cancel(); exists = false }
}
