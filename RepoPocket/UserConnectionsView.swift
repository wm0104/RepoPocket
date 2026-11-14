import SwiftUI

/// Counts come from the home page's existing identify request, never from scrolling.
struct UserConnectionsSection: View {
    @ObservedObject var api: GitHub
    private var login: String {
        if !api.login.isEmpty { return api.login }
        return AccountStore.accounts.first { $0.id == api.accountID }?.login ?? ""
    }
    var body: some View {
        Section("我的关注") {
            SoftGroupRows {
                for kind in UserConnectionKind.allCases {
                    SoftGroupRow(kind.id) {
                        NavigationLink {
                            UserConnectionsView(api: api, login: login, kind: kind).id(login + ":" + kind.id)
                        } label: {
                            HStack {
                                Label(kind.title, systemImage: kind.symbol)
                                Spacer()
                                Text(count(kind).map { $0.formatted() } ?? "—").foregroundStyle(.secondary)
                            }
                        }
                        .disabled(login.isEmpty)
                        .accessibilityIdentifier("account-connections-" + kind.id)
                    }
                }
            }
        }
    }
    private func count(_ kind: UserConnectionKind) -> Int? {
        kind == .followers ? api.profile?.followers : api.profile?.following
    }
}

struct UserConnectionsView: View {
    @ObservedObject var api: GitHub
    let login: String
    let kind: UserConnectionKind
    @StateObject private var store = CommunityPageStore<RepositorySocialUser>()
    @State private var attempted = false
    @State private var query = ""
    @State private var searchVisible = false
    private var visiblePeople: [RepositorySocialUser] {
        store.items.filter { HomeListSearch.matches(query, fields: [$0.login]) }
    }
    var body: some View {
        List {
            if searchVisible {
                Section {
                    SoftGroupRows {
                        SoftGroupRow("search") { ListSearchField(query: $query, title: kind.title) }
                        if store.more || store.limited {
                            SoftGroupRow("scope") {
                                Text(store.limited ? "搜索已加载的 \(store.items.count) 位用户，已达读取上限，更多用户请在 GitHub 查看。" : "搜索已加载的 \(store.items.count) 位用户，可继续加载更多。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                Text(login).font(.caption).foregroundStyle(.secondary).softGroupedRow(top: true, bottom: true)
            }
            if !visiblePeople.isEmpty {
                Section {
                    SoftGroupRows {
                        for person in visiblePeople {
                            SoftGroupRow(String(person.id)) {
                                NavigationLink {
                                    UserRepositoriesView(api: api, user: person.user)
                                } label: {
                                    HStack(spacing: 12) {
                                        GitHubAvatar(url: person.avatar_url, size: 36)
                                        Text(person.login).foregroundStyle(.primary)
                                    }
                                }.accessibilityIdentifier("connection-person-" + person.login)
                            }
                        }
                    }
                }
            }
            if store.loaded && store.items.isEmpty && !store.busy && store.error.isEmpty {
                Section {
                    Text(kind == .followers ? "暂无关注者" : "暂未关注任何人")
                        .foregroundStyle(.secondary).softGroupedRow(top: true, bottom: true)
                }
            }
            if store.loaded && !store.items.isEmpty && visiblePeople.isEmpty {
                Section { Text("没有匹配用户").foregroundStyle(.secondary).softGroupedRow(top: true, bottom: true) }
            }
            CommunityPageFooter(store: store, next: { load() })
        }
        .listStyle(.insetGrouped)
        .navigationTitle(kind.title)
        .adaptiveWorkspaceLayout()
        .toolbar {
            ListSearchButton(visible: $searchVisible, query: $query, title: kind.title)
            Button("刷新") { load(reset: true) }.disabled(store.busy)
        }
        .task { guard !attempted else { return }; attempted = true; load() }
        .onDisappear {
            // Resume an interrupted request on return, retaining completed pages.
            if store.busy { attempted = false }
            store.cancel()
        }
    }
    private func load(reset: Bool = false) {
        store.load(reset: reset, api: api) { try await api.userConnections(login, kind: kind, page: $0) }
    }
}
