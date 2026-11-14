import SwiftUI

/// Shared by repository menus and the single repository-home action row.
struct RepositoryStarMenuButton: View {
    let name: String
    let repository: Repository?
    @ObservedObject var api: GitHub

    var body: some View {
        RepositoryStarActionHost(name: name, repository: repository, api: api) { action in
            Button(action: action.perform) { Label(action.title, systemImage: action.symbol ?? "star") }
                .disabled(!action.enabled)
                .accessibilityHint(action.hint ?? "")
        }
    }
}

/// Both SwiftUI rows and the UIKit menu use one query lifecycle and one mutation path.
struct RepositoryStarActionHost<Content: View>: View {
    let name: String
    let repository: Repository?
    @ObservedObject var api: GitHub
    @ObservedObject var store: RepositoryStarStore
    @State private var value: Bool?
    @State private var loading = true
    @State private var error: String?
    let content: (NativeMenuItem) -> Content
    init(name: String, repository: Repository?, api: GitHub, @ViewBuilder content: @escaping (NativeMenuItem) -> Content) {
        self.name = name; self.repository = repository; self.api = api
        self.store = api.stars; self.content = content
    }
    var body: some View {
        content(action).task(id: name) { await load() }
    }
    private var action: NativeMenuItem {
        if !api.canCheckAppUpdate {
            return NativeMenuItem(id: "star", title: "加星标", symbol: "star", perform: {
                if api.isCurrentSession { api.message = "请登录账号" }
            })
        } else if loading {
            return NativeMenuItem(id: "star", title: "正在查询星标…", symbol: "hourglass", enabled: false)
        } else if let value = store.known(name) ?? value {
            return NativeMenuItem(id: "star", title: value ? "取消星标" : "加星标", symbol: value ? "star.fill" : "star",
                                  enabled: !store.isBusy(name) && api.isCurrentSession, perform: {
                guard api.isCurrentSession, !store.isBusy(name) else { return }
                // Capture canonical repository, account and desired state before suspension.
                do {
                    let fixed = try store.target(name, desired: !value)
                    Task {
                        do { try await store.perform(fixed, repository: repository) }
                        catch { if api.isCurrentSession, fixed.generation == AccountStore.generation { api.message = error.localizedDescription } }
                    }
                } catch { if api.isCurrentSession { api.message = error.localizedDescription } }
            })
        } else {
            return NativeMenuItem(id: "star", title: "星标状态查询失败，点击重试", symbol: "arrow.clockwise",
                                  enabled: api.isCurrentSession, hint: error ?? "重新查询当前仓库的星标状态", perform: { Task { await load() } })
        }
    }
    private func load() async {
            guard api.canCheckAppUpdate else { loading = false; return }
            loading = true
            do { let result = try await store.status(name); if api.isCurrentSession { value = result; error = nil } }
            catch { if api.isCurrentSession { self.error = error.localizedDescription } }
            loading = false
    }
}

struct StarAwareRepositoryStatistics: View {
    let repository: Repository
    @ObservedObject var store: RepositoryStarStore
    var body: some View { RepositoryStatistics(repository: store.display(repository)) }
}
