import SwiftUI

struct UserFollowRow: View {
    @ObservedObject var api: GitHub
    @ObservedObject private var store: UserFollowStore
    let login: String
    @State private var attempted = false
    @State private var loading = false
    @State private var error = ""
    init(api: GitHub, login: String) {
        self.api = api; self.login = login; _store = ObservedObject(wrappedValue: api.follows)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let followed = store.known(login) {
                Button {
                    Task {
                        error = ""
                        do { try await store.setFollowing(login, desired: !followed) }
                        catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription } }
                    }
                } label: {
                    HStack {
                        Label(followed ? "取消关注" : "关注", systemImage: followed ? "person.badge.minus" : "person.badge.plus")
                        Spacer()
                        if store.isBusy(login) { ProgressView() }
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.borderless).disabled(store.isBusy(login) || loading || !api.isCurrentSession)
                    .accessibilityIdentifier("user-follow-action")
            } else if loading { ProgressView("正在检查关注状态…") }
            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("user-follow-error")
                Button("重试关注状态") { Task { await load(refresh: true) } }.buttonStyle(.borderless)
                    .disabled(loading || store.isBusy(login) || !api.isCurrentSession)
            }
        }.task {
            guard !attempted else { return }; attempted = true; await load()
        }
    }
    private func load(refresh: Bool = false) async {
        guard !loading, api.isCurrentSession else { return }
        loading = true; defer { loading = false }
        do {
            _ = try await store.load(login, refresh: refresh); try Task.checkCancellation()
            if api.isCurrentSession { error = "" }
        } catch {
            if RefreshFailure.isCancellation(error) { attempted = false }
            else if api.isCurrentSession { self.error = error.localizedDescription }
        }
    }
}
