import SwiftUI
import Charts

struct NativeHistogramPoint: Identifiable {
    let id: String
    let count: Int
}
struct NativeHistogram: View {
    let points: [NativeHistogramPoint]
    var body: some View {
        if points.isEmpty { Text("暂无可显示的数据").foregroundStyle(.secondary) }
        else {
            Chart(points) { point in
                BarMark(x: .value("月份", point.id), y: .value("数量", point.count))
            }.frame(height: 200).accessibilityLabel("按月统计")
        }
    }
}

struct NativeRepositoryStatisticsView: View {
    @ObservedObject var api: GitHub
    let repo: String
    @State private var languages: [String: Int] = [:]
    @State private var stars: [StarTimestamp] = []
    @State private var starTotal: Int?
    @State private var error = ""
    @State private var revision = 0
    @State private var summary: CodeLineSummary?
    @State private var counting = false
    @State private var counted = 0
    @State private var countError = ""
    @State private var countTask: Task<Void, Never>?
    private var monthly: [NativeHistogramPoint] {
        Dictionary(grouping: stars, by: { String($0.starred_at.prefix(7)) }).map { NativeHistogramPoint(id: $0.key, count: $0.value.count) }.sorted { $0.id < $1.id }
    }
    var body: some View {
        List {
            Section("语言字节数") {
                SoftGroupRows {
                    for language in languages.keys.sorted() {
                        SoftGroupRow(language) { LabeledContent(language, value: ByteCountFormatter.string(fromByteCount: Int64(languages[language, default: 0]), countStyle: .file)) }
                    }
                    if languages.isEmpty { SoftGroupRow("empty") { Text("暂无语言统计") } }
                }
            }
            Section("Star 时间分布") {
                SoftGroupRows {
                    if let starTotal { SoftGroupRow("total") { Text("当前 Star：\(starTotal)") } }
                    SoftGroupRow("chart") { NativeHistogram(points: monthly) }
                    SoftGroupRow("scope") { Text("按当前 Star 用户的加星月份统计，最多读取最近1000条；不包含已经取消的 Star，不等同于完整历史总量。").font(.caption).foregroundStyle(.secondary) }
                    if !error.isEmpty { SoftGroupRow("error") { Text(error).font(.caption) } }
                    SoftGroupRow("reload") { Button("刷新统计") { revision += 1 } }
                }
            }
            Section("源码行数 · App 内计算") {
                SoftGroupRows {
                    if let summary {
                        SoftGroupRow("lines") { Text("已统计 \(summary.files) 个文件，\(summary.lines) 行文本（含空行和注释）") }
                        if summary.skipped > 0 || summary.treeTruncated { SoftGroupRow("partial") { Text("这是受预算限制的部分统计：另有 \(summary.skipped) 个候选文件未统计" + (summary.treeTruncated ? "，GitHub 文件树也已截断。" : "。")).font(.caption) } }
                    }
                    SoftGroupRow("budget") { Text("最多40个 UTF-8 源码文件、每个128 KiB、合计2 MiB。固定当前提交后统计，不修改文件。").font(.caption).foregroundStyle(.secondary) }
                    if counting { SoftGroupRow("progress") { ProgressView("已统计 \(counted) 个文件") }; SoftGroupRow("cancel") { Button("取消统计") { countTask?.cancel() } } }
                    else { SoftGroupRow("count") { Button("开始计算行数") { startCount() } } }
                    if !countError.isEmpty { SoftGroupRow("error") { Text(countError).font(.caption) } }
                }
            }
        }.navigationTitle("仓库统计").adaptiveWorkspaceLayout()
        .task(id: revision) {
            error = ""
            do {
                let info = try await api.repository(repo)
                let languageData = try await api.repositoryLanguages(repo)
                try Task.checkCancellation(); guard api.isCurrentSession else { return }
                languages = languageData; starTotal = info.stargazers_count
                let pages = Int(ceil(Double(info.stargazers_count ?? 0) / 100))
                var result: [StarTimestamp] = []
                if pages > 0 {
                    for page in max(1, pages - 9)...pages {
                        result += try await api.communityStarDates(repo, page: page)
                        try Task.checkCancellation()
                    }
                }
                guard api.isCurrentSession else { return }; stars = result
            } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription } }
        }.onDisappear { countTask?.cancel() }
    }
    private func startCount() {
        guard !counting else { return }; counting = true; counted = 0; countError = ""
        countTask = Task { @MainActor in
            defer { counting = false; countTask = nil }
            do {
                let result = try await api.codeLineSummary(repo, branch: "") { counted = $0 }
                try Task.checkCancellation(); guard api.isCurrentSession else { return }; summary = result
            } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { countError = error.localizedDescription } }
        }
    }
}

struct NativeActivityChartView: View {
    @ObservedObject var api: GitHub
    let login: String
    @StateObject private var store = CommunityPageStore<CommunityEvent>()
    private var points: [NativeHistogramPoint] {
        Dictionary(grouping: store.items, by: { ChinaDate.month($0.created_at) }).map { NativeHistogramPoint(id: $0.key, count: $0.value.count) }.sorted { $0.id < $1.id }
    }
    var body: some View {
        List {
            Section("最近公开活动") {
                SoftGroupRows {
                    SoftGroupRow("chart") { NativeHistogram(points: points) }
                    SoftGroupRow("scope") { Text("统计已加载的 GitHub 公开活动，不冒充全年贡献日历；活动 API 的时间和数量范围有限。").font(.caption).foregroundStyle(.secondary) }
                }
            }
            CommunityPageFooter(store: store, next: { load() })
        }.navigationTitle("活动图表").task { if !store.loaded { load() } }.onDisappear { store.cancel() }
    }
    private func load() { store.load(api: api) { try await api.communityEvents(login, page: $0) } }
}

struct NativeDeveloper: Identifiable { let user: User; var id: String { user.login } }
struct NativeDevelopersView: View {
    @ObservedObject var api: GitHub
    @StateObject private var store = CommunityPageStore<NativeDeveloper>()
    var body: some View {
        List {
            Section("按关注者数量排序的公开开发者") {
                SoftGroupRows {
                    for row in store.items {
                        SoftGroupRow(row.id) {
                            NavigationLink { UserRepositoriesView(api: api, user: row.user) } label: { HStack { GitHubAvatar(url: row.user.avatar_url); Text(row.user.login) } }
                        }
                    }
                }
            }
            CommunityPageFooter(store: store, next: { load() })
        }.navigationTitle("开发者").task { if !store.loaded { load() } }.onDisappear { store.cancel() }
    }
    private func load() {
        store.load(api: api) { page in
            let bytes = try await api.communityRead("/search/users", query: CommunityRules.page(page) + [.init(name: "q", value: "type:user followers:>1000"), .init(name: "sort", value: "followers"), .init(name: "order", value: "desc")])
            return try JSONDecoder().decode(UserSearchResponse.self, from: bytes).items.map { NativeDeveloper(user: $0) }
        }
    }
}
