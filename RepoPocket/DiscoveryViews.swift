import SwiftUI

struct CommunityProfileSection: View {
    @ObservedObject var api: GitHub
    let login: String
    let avatar: String?
    @State private var profile: CommunityProfile?
    @State private var error = ""
    @State private var revision = 0

    var body: some View {
        Section("用户资料") {
            SoftGroupRows {
                SoftGroupRow("profile") {
                    HStack(alignment: .top) {
                        GitHubAvatar(url: profile?.avatar_url ?? avatar, size: 56)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(profile?.name ?? login).font(.headline)
                            Text("@" + login).font(.subheadline).foregroundStyle(.secondary)
                            if let bio = profile?.bio, !bio.isEmpty { Text(bio).textSelection(.enabled) }
                        }
                    }
                }
                if let profile {
                    if let count = profile.public_repos { SoftGroupRow("repos") { Text("\(count) 个公开仓库").font(.caption) } }
                    if let count = profile.followers { SoftGroupRow("followers") { Text("\(count) 位关注者 · 正在关注 \(profile.following ?? 0) 人").font(.caption) } }
                    if let company = profile.company, !company.isEmpty { SoftGroupRow("company") { Label(company, systemImage: "building.2") } }
                    if let location = profile.location, !location.isEmpty { SoftGroupRow("location") { Label(location, systemImage: "mappin") } }
                    if let site = profile.blog, !site.isEmpty { SoftGroupRow("site") { Text(site).font(.caption).textSelection(.enabled) } }
                }
                SoftGroupRow("events") { NavigationLink("公开活动") { CommunityEventsView(api: api, login: login) } }
                SoftGroupRow("chart") { NavigationLink("活动图表") { NativeActivityChartView(api: api, login: login) } }
                if !error.isEmpty { SoftGroupRow("error") { Text(error).font(.caption) }; SoftGroupRow("retry") { Button("重试资料加载") { revision += 1 } } }
            }
        }.task(id: revision) {
            error = ""
            do {
                let value = try await api.communityProfile(login)
                try Task.checkCancellation(); guard api.isCurrentSession else { return }; profile = value
            } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = "资料加载失败，仓库浏览仍可使用。" } }
        }
    }
}

struct CommunityEventsView: View {
    @ObservedObject var api: GitHub
    let login: String
    var received = false
    @StateObject private var store = CommunityPageStore<CommunityEvent>()

    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    for event in store.items {
                        SoftGroupRow(event.id) {
                            NavigationLink { BrowserView(api: api, repo: event.repo.name, path: "", branch: "") } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack { GitHubAvatar(url: event.actor.avatar_url, size: 24); Text(event.actor.login + " " + event.summary) }
                                    Text(event.repo.name).font(.headline)
                                    if let date = event.created_at { Text(ChinaDate.dateTime(date)).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    if store.loaded && store.items.isEmpty { SoftGroupRow("empty") { Text("暂无可见活动") } }
                    SoftGroupRow("scope") { Text("GitHub 活动流可能延迟，且仅提供有限时间内的记录。").font(.caption).foregroundStyle(.secondary) }
                }
            }
            CommunityPageFooter(store: store, next: { load() })
        }.navigationTitle(received ? "关注动态" : "公开活动").adaptiveWorkspaceLayout()
        .toolbar { Button("刷新") { load(reset: true) }.disabled(store.busy) }
        .task { if !store.loaded { load() } }.onDisappear { store.cancel() }
    }
    private func load(reset: Bool = false) {
        store.load(reset: reset, api: api) { try await api.communityEvents(login, received: received, page: $0) }
    }
}

struct CommunityDiscoveryView: View {
    @ObservedObject var api: GitHub
    @State private var language = ""
    @State private var days = 7
    @StateObject private var store = CommunityPageStore<Repository>()

    var body: some View {
        List {
            Section("近期新建的热门仓库") {
                SoftGroupRows {
                    SoftGroupRow("time") { Picker("时间范围", selection: $days) { Text("一天").tag(1); Text("一周").tag(7); Text("一月").tag(30) } }
                    SoftGroupRow("language") { Picker("语言", selection: $language) { ForEach(RepositorySearchOptions.languages, id: \.self) { Text($0.isEmpty ? "所有语言" : $0).tag($0) } } }
                    SoftGroupRow("refresh") { Button("加载 / 刷新") { load(reset: true) }.disabled(store.busy) }
                    SoftGroupRow("scope") { Text("按所选时间内新建仓库的累计 Star 排序。").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section {
                SoftGroupRows {
                    for repository in store.items {
                        SoftGroupRow(String(repository.id)) {
                            NavigationLink { BrowserView(api: api, repo: repository.full_name, path: "", branch: repository.default_branch ?? "") } label: { RepositoryCard(repository: repository, account: api.login, api: api) }
                        }
                    }
                    if store.loaded && store.items.isEmpty { SoftGroupRow("empty") { Text("没有符合条件的仓库") } }
                }
            }
            CommunityPageFooter(store: store, next: { load() })
            Section {
                SoftGroupRows {
                    SoftGroupRow("developers") { NavigationLink("浏览公开开发者") { NativeDevelopersView(api: api) } }
                    if !api.login.isEmpty { SoftGroupRow("following") { NavigationLink("关注动态") { CommunityEventsView(api: api, login: api.login, received: true) } } }
                }
            }
        }.navigationTitle("发现").adaptiveWorkspaceLayout()
        .onChange(of: language) { _ in load(reset: true) }
        .onChange(of: days) { _ in load(reset: true) }
        .task { if !store.loaded { load() } }.onDisappear { store.cancel() }
    }
    private func load(reset: Bool = false) {
        let requestedDays = days, requestedLanguage = language
        // Anchor the calendar once per request set; never change the query mid-page.
        if reset || dateQuery.isEmpty {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
            dateQuery = "created:>=" + formatter.string(from: Date().addingTimeInterval(-Double(requestedDays) * 86400))
        }
        let query = dateQuery
        store.load(reset: reset, api: api) { page in
            try await api.searchRepositories(query, page: page, options: .init(language: requestedLanguage, sort: .stars)).items
        }
    }
    @State private var dateQuery = ""
}

struct RepositoryContributorsView: View {
    @ObservedObject var api: GitHub
    let repo: String
    @StateObject private var store = CommunityPageStore<RepositoryContributor>()

    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    for person in store.items {
                        SoftGroupRow(person.id) {
                            NavigationLink { UserRepositoriesView(api: api, user: User(id: nil, login: person.login, avatar_url: person.avatar_url, name: nil, followers: nil, following: nil)) } label: {
                                HStack { GitHubAvatar(url: person.avatar_url); Text(person.login); Spacer(); Text("\(person.contributions) 次提交").font(.caption) }
                            }
                        }
                    }
                    if store.loaded && store.items.isEmpty { SoftGroupRow("empty") { Text("暂无贡献者") } }
                }
            }
            CommunityPageFooter(store: store, next: { load() })
        }.navigationTitle("贡献者").adaptiveWorkspaceLayout()
        .task { if !store.loaded { load() } }.onDisappear { store.cancel() }
    }
    private func load() { store.load(api: api) { try await api.contributors(repo, page: $0) } }
}

struct RepositoryToolsView: View {
    @ObservedObject var api: GitHub
    let repo: String
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    SoftGroupRow("contributors") { NavigationLink("贡献者") { RepositoryContributorsView(api: api, repo: repo) } }
                    SoftGroupRow("statistics") { NavigationLink("语言、Star 图表与源码行数") { NativeRepositoryStatisticsView(api: api, repo: repo) } }
                }
            }
        }.navigationTitle("统计与工具").adaptiveWorkspaceLayout()
    }
}
