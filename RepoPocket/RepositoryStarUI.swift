import SwiftUI

/// Attached only inside menu content, not to scrolling repository rows.
struct RepositoryStarMenuButton: View {
    let name: String
    let repository: Repository?
    @ObservedObject var api: GitHub
    @ObservedObject var store: RepositoryStarStore
    @State private var value: Bool?
    @State private var loading = true
    @State private var error: String?
    init(name: String, repository: Repository?, api: GitHub) {
        self.name = name; self.repository = repository; self.api = api
        self.store = api.stars
    }
    var body: some View {
        Group {
            if !api.canCheckAppUpdate {
                Button { if api.isCurrentSession { api.message = "请登录账号" } } label: { Label("加星标", systemImage: "star") }
            } else if loading {
                Button {} label: { Label("正在查询星标…", systemImage: "hourglass") }.disabled(true)
            } else if let value = store.known(name) ?? value {
                Button {
                    // Capture canonical repository, account and desired state before suspension.
                    do {
                        let fixed = try store.target(name, desired: !value)
                        Task {
                            do { try await store.perform(fixed, repository: repository) }
                            catch { if api.isCurrentSession, fixed.generation == AccountStore.generation { api.message = error.localizedDescription } }
                        }
                    } catch { if api.isCurrentSession { api.message = error.localizedDescription } }
                } label: { Label(value ? "取消星标" : "加星标", systemImage: value ? "star.fill" : "star") }
                .disabled(store.isBusy(name) || !api.isCurrentSession)
            } else {
                Button { api.message = error ?? "星标状态未知，请重新打开菜单" } label: { Label("星标状态查询失败", systemImage: "exclamationmark.circle") }
            }
        }
        .task(id: name) {
            guard api.canCheckAppUpdate else { loading = false; return }
            loading = true
            do { let result = try await store.status(name); if api.isCurrentSession { value = result; error = nil } }
            catch { if api.isCurrentSession { self.error = error.localizedDescription } }
            loading = false
        }
    }
}

struct StarAwareRepositoryStatistics: View {
    let repository: Repository
    @ObservedObject var store: RepositoryStarStore
    var body: some View { RepositoryStatistics(repository: store.display(repository)) }
}
