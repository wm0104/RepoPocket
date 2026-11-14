import SwiftUI

enum ForkPresentation {
    #if FORK_PEOPLE_ONLY
    static let peopleOnly = true
    #else
    static let peopleOnly = false
    #endif
}

private struct RepositorySocialAPIKey: EnvironmentKey { static let defaultValue: GitHub? = nil }
extension EnvironmentValues {
    var repositorySocialAPI: GitHub? {
        get { self[RepositorySocialAPIKey.self] }
        set { self[RepositorySocialAPIKey.self] = newValue }
    }
}

enum RepositorySocialDestination: String, Identifiable {
    case stars, forks
    var id: String { rawValue }
}

/// One attempt on first appearance, including empty/error results. Refresh keeps old rows.
@MainActor final class SocialPageState<Item: Identifiable>: ObservableObject where Item.ID: Hashable {
    @Published private(set) var items: [Item] = []
    @Published private(set) var busy = false
    @Published private(set) var error = ""
    @Published private(set) var attempted = false
    @Published private(set) var more = true
    private var page = 1
    private var failedRefresh = false
    func load(refresh: Bool = false, operation: (Int) async throws -> [Item], valid: () -> Bool) async {
        guard !busy, valid(), refresh || more else { return }
        busy = true; attempted = true
        defer { busy = false }
        let next = refresh ? 1 : page
        do {
            let batch = try await operation(next)
            try Task.checkCancellation(); guard valid() else { return }
            let known = refresh ? Set<Item.ID>() : Set(items.map(\.id))
            var seen = known
            let unique = batch.filter { seen.insert($0.id).inserted }
            items = refresh ? unique : items + unique
            more = batch.count == 30 && next < 10
            page = next + 1; error = ""; failedRefresh = false
        } catch {
            if !RefreshFailure.isCancellation(error), valid() { self.error = error.localizedDescription; failedRefresh = refresh }
        }
    }
    func retry(operation: (Int) async throws -> [Item], valid: () -> Bool) async {
        await load(refresh: failedRefresh, operation: operation, valid: valid)
    }
}

private struct SocialPageFooter<Item: Identifiable>: View where Item.ID: Hashable {
    @ObservedObject var state: SocialPageState<Item>
    let load: () -> Void
    let retry: () -> Void
    var body: some View {
        Section {
            if state.busy { ProgressView("正在加载…") }
            if !state.error.isEmpty { Text(state.error); Button("重试") { retry() }.disabled(state.busy) }
            else if state.attempted && !state.busy {
                if state.items.isEmpty { Text("暂无记录") }
                if state.more { Button("加载更多") { load() } }
                else if state.items.count >= 300 { Text("最多显示 300 条记录。") }
            }
        }
    }
}

struct RepositorySocialView: View {
    @ObservedObject var api: GitHub
    let repository: Repository
    let destination: RepositorySocialDestination
    @StateObject private var stars = SocialPageState<RepositorySocialUser>()
    @StateObject private var forks = SocialPageState<Repository>()
    @Environment(\.dismiss) private var dismiss
    private var isStars: Bool { destination == .stars }
    var body: some View {
        NavigationStack {
            List {
                Section { Text(repository.full_name).font(.caption).softGroupedRow(top: true, bottom: true) }
                if isStars {
                    ForEach(stars.items) { person in
                        NavigationLink { UserRepositoriesView(api: api, user: person.user) } label: { SocialPersonRow(login: person.login, avatar: person.avatar_url) }
                            .softGroupedRow(top: person.id == stars.items.first?.id, bottom: person.id == stars.items.last?.id)
                    }
                    SocialPageFooter(state: stars, load: { Task { await load() } }, retry: { Task { await retry() } })
                } else {
                    ForEach(forks.items) { fork in
                        if ForkPresentation.peopleOnly {
                            NavigationLink { UserRepositoriesView(api: api, user: forkUser(fork)) } label: { SocialPersonRow(login: forkUser(fork).login, avatar: fork.owner?.avatar_url) }
                                .softGroupedRow(top: fork.id == forks.items.first?.id, bottom: fork.id == forks.items.last?.id)
                        } else {
                            NavigationLink { ForkRepositoryView(api: api, base: repository, fork: fork) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    SocialPersonRow(login: forkUser(fork).login, avatar: fork.owner?.avatar_url)
                                    Text(fork.full_name).font(.caption).foregroundStyle(.secondary)
                                }
                            }.softGroupedRow(top: fork.id == forks.items.first?.id, bottom: fork.id == forks.items.last?.id)
                        }
                    }
                    SocialPageFooter(state: forks, load: { Task { await load() } }, retry: { Task { await retry() } })
                }
            }.navigationTitle(isStars ? "星标用户" : "复刻者")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("刷新") { Task { await load(refresh: true) } }.disabled(stars.busy || forks.busy) }
            }
            .task { guard !(isStars ? stars.attempted : forks.attempted) else { return }; await load() }
        }
    }
    private func forkUser(_ fork: Repository) -> User {
        fork.owner ?? User(id: nil, login: String(fork.full_name.split(separator: "/").first ?? ""), avatar_url: nil, name: nil, followers: nil, following: nil)
    }
    @MainActor private func load(refresh: Bool = false) async {
        if isStars { await stars.load(refresh: refresh, operation: { try await api.socialStargazers(repository.full_name, page: $0) }, valid: { api.isCurrentSession }) }
        else { await forks.load(refresh: refresh, operation: { try await api.socialForks(repository.full_name, page: $0) }, valid: { api.isCurrentSession }) }
    }
    @MainActor private func retry() async {
        if isStars { await stars.retry(operation: { try await api.socialStargazers(repository.full_name, page: $0) }, valid: { api.isCurrentSession }) }
        else { await forks.retry(operation: { try await api.socialForks(repository.full_name, page: $0) }, valid: { api.isCurrentSession }) }
    }
}

private struct SocialPersonRow: View {
    let login: String
    let avatar: String?
    var body: some View { HStack { GitHubAvatar(url: avatar, size: 32); Text(login) } }
}

struct ForkRepositoryView: View {
    @ObservedObject var api: GitHub
    let base: Repository
    let fork: Repository
    var body: some View {
        List {
            if let owner = fork.owner {
                NavigationLink { UserRepositoriesView(api: api, user: owner) } label: { SocialPersonRow(login: owner.login, avatar: owner.avatar_url) }.softGroupedRow(top: true)
            }
            NavigationLink("浏览复刻仓库") { BrowserView(api: api, repo: fork.full_name, path: "", branch: fork.default_branch ?? "") }.softGroupedRow(top: fork.owner == nil)
            NavigationLink("相对原仓库的新增提交") { ForkChangesView(api: api, base: base, fork: fork) }.softGroupedRow(bottom: true)
        }.navigationTitle(fork.name)
    }
}

struct ForkChangesView: View {
    @ObservedObject var api: GitHub
    let base: Repository
    let fork: Repository
    @StateObject private var commits = SocialPageState<DesktopCommit>()
    @State private var snapshot: (base: String, head: String)?
    @State private var summary = ""
    var body: some View {
        List {
            Section {
                Text("比较双方默认分支；新增提交不一定由复刻者本人编写。").font(.caption).softGroupedRow(top: true, bottom: summary.isEmpty)
                if !summary.isEmpty { Text(summary).font(.caption).softGroupedRow(bottom: true) }
            }
            ForEach(commits.items) { item in
                NavigationLink { CommitDetailView(api: api, repo: fork.full_name, sha: item.sha) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.commit.message.components(separatedBy: .newlines).first ?? item.commit.message).lineLimit(3)
                        Text(String(item.sha.prefix(7)) + " · " + (item.commit.author?.name ?? "未知作者")).font(.caption).foregroundStyle(.secondary)
                    }
                }.softGroupedRow(top: item.id == commits.items.first?.id, bottom: item.id == commits.items.last?.id)
            }
            SocialPageFooter(state: commits, load: { Task { await load() } }, retry: { Task { await retry() } })
        }.navigationTitle("新增提交")
        .toolbar { Button("刷新") { Task { await load(refresh: true) } }.disabled(commits.busy) }
        .task { guard !commits.attempted else { return }; await load() }
    }
    @MainActor private func load(refresh: Bool = false) async {
        await commits.load(refresh: refresh, operation: fetch, valid: { api.isCurrentSession })
    }
    @MainActor private func retry() async {
        await commits.retry(operation: fetch, valid: { api.isCurrentSession })
    }
    @MainActor private func fetch(_ page: Int) async throws -> [DesktopCommit] {
            if page == 1 {
                let currentBase = try await api.repository(base.full_name)
                let currentFork = try await api.repository(fork.full_name)
                guard let baseBranch = currentBase.default_branch, let headBranch = currentFork.default_branch else { throw AppError(text: "仓库暂无默认分支。") }
                let baseSHA = try await api.workspaceHead(base.full_name, branch: baseBranch)
                let headSHA = try await api.workspaceHead(fork.full_name, branch: headBranch)
                snapshot = (baseSHA, headSHA)
            }
            guard let snapshot else { throw AppError(text: "请刷新后重试比较。") }
            let owner = fork.owner?.login ?? String(fork.full_name.split(separator: "/").first ?? "")
            let result = try await api.socialComparison(base.full_name, base: snapshot.base, owner: owner, head: snapshot.head, page: page)
            summary = "领先 \(result.ahead_by) 个提交，落后 \(result.behind_by) 个提交。"
            return result.commits
    }
}
