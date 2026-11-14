import SwiftUI

struct PersonalIssuesSection: View {
    @ObservedObject var api: GitHub
    @ObservedObject var store: CommunityPageStore<CollaborationItem>
    @ObservedObject private var deletions: IssueDeletionState
    @State private var deletionTarget: IssueDeletionConfirmation?
    private var visible: [CollaborationItem] { deletions.visible(store.items) }
    init(api: GitHub, store: CommunityPageStore<CollaborationItem>) {
        self.api = api; self.store = store; deletions = api.issueDeletions
    }
    var body: some View {
        Section("议题") {
            SoftGroupRows {
                for item in visible.prefix(3) {
                    if let repo = PersonalIssueRules.repository(item) {
                        SoftGroupRow(String(item.id)) {
                            NavigationLink { CollaborationDetailView(api: api, repo: repo, kind: .issues, number: item.number) }
                            label: { PersonalIssueRow(item: item, repo: repo) }
                            .accessibilityIdentifier("home-issue-\(item.number)")
                            .issueDeletionMenu(api: api, state: deletions, subject: IssueDeletionSubject(item, repo: repo), target: $deletionTarget)
                        }
                    }
                }
                if store.busy && store.items.isEmpty { SoftGroupRow("loading") { ProgressView("加载相关议题…") } }
                if store.loaded && visible.isEmpty { SoftGroupRow("empty") { Text("暂无相关议题").foregroundStyle(.secondary) } }
                if !store.error.isEmpty {
                    SoftGroupRow("error") { Text(store.error).font(.caption).foregroundStyle(.secondary) }
                    SoftGroupRow("retry") { Button("重试议题") { load() }.disabled(store.busy) }
                }
                SoftGroupRow("all") {
                    NavigationLink { PersonalIssuesView(api: api, login: api.login) }
                    label: { Label("查看全部议题", systemImage: "exclamationmark.circle") }
                    .disabled(api.login.isEmpty).accessibilityIdentifier("home-personal-issues")
                }
            }
        }
        .issueDeletionPresenter(api: api, state: deletions, target: $deletionTarget)
        .onChange(of: store.items.map(\.id)) { _ in loadPermissions() }
        .onChange(of: deletions.deleted) { _ in loadPermissions() }
        .task { loadPermissions() }
    }
    private func loadPermissions() {
        deletions.load(visible.prefix(3).compactMap { item in PersonalIssueRules.repository(item).flatMap { IssueDeletionSubject(item, repo: $0) } }, api: api)
    }
    private func load() {
        let login = api.login
        deletions.resetPermissions()
        store.load(reset: true, api: api) { try await api.personalIssues(login, filter: .involved, page: $0) }
    }
}

struct PersonalIssueRow: View {
    let item: CollaborationItem
    let repo: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.state == "open" ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(item.state == "open" ? Color.green : Color.purple).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(repo + " #\(item.number)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(item.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                HStack {
                    Text(item.state == "open" ? "开放" : "已关闭")
                    if let date = item.updated_at { Text(ChinaDate.dateTime(date)).lineLimit(1) }
                    Spacer(minLength: 2)
                    Label("\(item.comments ?? 0)", systemImage: "bubble.right")
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

struct PersonalIssuesView: View {
    @ObservedObject var api: GitHub
    let login: String
    @StateObject private var store = CommunityPageStore<CollaborationItem>()
    @State private var filter = PersonalIssueFilter.involved
    @State private var attempted = false
    @ObservedObject private var deletions: IssueDeletionState
    @State private var deletionTarget: IssueDeletionConfirmation?
    private var visible: [CollaborationItem] { deletions.visible(store.items) }
    init(api: GitHub, login: String) { self.api = api; self.login = login; deletions = api.issueDeletions }
    var body: some View {
        List {
            Section {
                Picker("议题范围", selection: $filter) {
                    ForEach(PersonalIssueFilter.allCases) { Text($0.title).tag($0) }
                }.softGroupedRow(top: true, bottom: true)
            }
            if !visible.isEmpty {
                Section {
                    SoftGroupRows {
                        for item in visible {
                            if let repo = PersonalIssueRules.repository(item) {
                                SoftGroupRow(String(item.id)) {
                                    NavigationLink { CollaborationDetailView(api: api, repo: repo, kind: .issues, number: item.number) }
                                    label: { PersonalIssueRow(item: item, repo: repo) }
                                    .issueDeletionMenu(api: api, state: deletions, subject: IssueDeletionSubject(item, repo: repo), target: $deletionTarget)
                                    .accessibilityIdentifier("personal-issue-\(item.number)")
                                }
                            }
                        }
                    }
                }
            }
            if store.loaded && visible.isEmpty && store.error.isEmpty {
                Section { Text("没有符合条件的议题").foregroundStyle(.secondary).softGroupedRow(top: true, bottom: true) }
            }
            CommunityPageFooter(store: store, next: { load() })
        }.listStyle(.insetGrouped).navigationTitle("我的议题").adaptiveWorkspaceLayout()
        .toolbar { Button("刷新") { load(reset: true) }.disabled(store.busy) }
        .onChange(of: filter) { _ in load(reset: true) }
        .task { guard !attempted else { return }; attempted = true; load() }
        .onDisappear { if store.busy { attempted = false }; store.cancel() }
        .issueDeletionPresenter(api: api, state: deletions, target: $deletionTarget)
        .onChange(of: store.items.map(\.id)) { _ in loadPermissions() }
        .task { loadPermissions() }
    }
    private func loadPermissions() {
        deletions.load(visible.compactMap { item in PersonalIssueRules.repository(item).flatMap { IssueDeletionSubject(item, repo: $0) } }, api: api)
    }
    private func load(reset: Bool = false) {
        let requested = filter
        if reset { deletions.resetPermissions() }
        store.load(reset: reset, api: api) { try await api.personalIssues(login, filter: requested, page: $0) }
    }
}
