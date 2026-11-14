import SwiftUI
import UIKit

@main
struct RepoPocketApp: App {
    @State private var accountID = AccountStore.generation
    @StateObject private var selectionStore = WorkspaceSelectionStore()
    @StateObject private var accountPresentation = AccountPresentation()
    @StateObject private var downloads = DownloadStore.shared
    @AppStorage("appearance.mode") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            Group {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-style-preview") {
                    StylePreviewGallery()
                } else {
                    ZStack { AccountRootView().id(accountID) }
                }
#else
            ZStack { AccountRootView().id(accountID) }
#endif
            }
                .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
                .background(WindowStyleApplier(style: appearance == "dark" ? .dark : (appearance == "light" ? .light : .unspecified)))
                .environmentObject(selectionStore)
                .environmentObject(accountPresentation)
                .sheet(isPresented: $accountPresentation.showing, onDismiss: { accountPresentation.accountSheetDismissed() }) { accountManager.id(accountID).environmentObject(accountPresentation).appSheetCornerRadius() }
                .alert("GitHub 授权成功", isPresented: Binding(get: { accountPresentation.authorizationNotice != nil }, set: { if !$0 { accountPresentation.authorizationNotice = nil } })) {
                    Button("好", role: .cancel) { accountPresentation.authorizationNotice = nil }
                } message: { Text(accountPresentation.authorizationNotice ?? "") }
                .sheet(item: $downloads.picker, onDismiss: { downloads.selected(nil) }) { request in
                    WorkspaceDocumentPicker(request: request, allowsMultipleSelection: false, cancelTitle: "取消") { downloads.selected($0) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .githubAccountChanged)) { _ in
                    accountID = AccountStore.generation
                }
        }
    }
    @MainActor @ViewBuilder private var accountManager: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-account-session-style-preview") {
            AccountManagementView(configuration: AccountSessionStylePreview.configuration)
        } else { AccountManagementView() }
        #else
        AccountManagementView()
        #endif
    }
}

struct AccountRootView: View {
    @StateObject private var api = GitHub()
    @StateObject private var localGit = LocalGitRegistry()
    @StateObject private var updateChecker = UpdateChecker()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    var body: some View {
            TabView(selection: $selectedTab) {
                RepositoriesView(api: api).tabItem { Label("主页", systemImage: "house") }.tag(0)
                LocalProjectsView(api: api, store: localGit).tabItem { Label("Git", systemImage: "arrow.triangle.branch") }.tag(1)
                SettingsView(api: api, updateChecker: updateChecker).tabItem { Label("设置", systemImage: "gear") }.tag(4)
            }
            // `tabItem` keeps only the label's image and title, so the dot is drawn on the tab bar.
            .background(UpdateTabBadge(tabIndex: 2, isVisible: updateChecker.hasUpdate).frame(width: 1, height: 1))
            // Launch and every return to the foreground notify about updates; the per-account
            // 15-minute window inside the checker bounds automatic network use.
            .task { await updateChecker.appEntryCheck(api: api) }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                NotificationCenter.default.post(name: .externalInboxChanged, object: nil)
                NotificationCenter.default.post(name: Notification.Name("RepoPocket.upstreamForegroundCheck"), object: api.accountID)
                Task { await updateChecker.appEntryCheck(api: api) }
            }
            // Ask the system for network access during launch, not mid-Token or mid-check.
            .task { await NetworkWarmup.runOnceIfNeeded() }
            .onOpenURL { url in
                guard url.isFileURL else { return }
                Task {
                    do {
                        _ = try await Task.detached { try ShareInboxStore.live().importFile(url) }.value
                        NotificationCenter.default.post(name: .externalInboxChanged, object: nil)
                    } catch { api.message = error.localizedDescription }
                }
            }
            .alert("提示", isPresented: Binding(get: { !api.message.isEmpty }, set: { if !$0 { api.message = "" } })) {
                Button("好", role: .cancel) { api.message = "" }
            } message: { Text(api.message) }
    }
}

struct SharedFile: Identifiable { let id = UUID(); let url: URL }
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        context.coordinator.scope = DownloadStore.shared.shareScope(for: url)
        controller.completionWithItemsHandler = { _, _, _, _ in context.coordinator.release() }
        return controller
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleUIViewController(_ vc: UIActivityViewController, coordinator: Coordinator) { coordinator.release() }
    final class Coordinator {
        var scope: URL?
        func release() { scope?.stopAccessingSecurityScopedResource(); scope = nil }
        deinit { release() }
    }
}

struct RepositoriesView: View {
    @ObservedObject var api: GitHub
    @EnvironmentObject private var accountPresentation: AccountPresentation
    @StateObject private var personalIssues = CommunityPageStore<CollaborationItem>()
    @StateObject private var upstreamUpdates = UpstreamUpdatesStore()
    @State private var repos: [Repository] = []
    @State private var starred: [Repository] = []
    @State private var showOpen = false
    @State private var showSearch = false
    @State private var loaded = false
    @State private var refreshing = false
    @State private var input = ""
    @State private var busy = false
    @State private var newName = ""
    @State private var isPrivate = true
    @State private var showCreate = false
    @State private var showUpstreamWatch = false
    @State private var updatedAt: Date?
    @State private var loadError = ""
    init(api: GitHub) {
        self.api = api
        let owned = api.cachedCollection(.owned), stars = api.cachedCollection(.starred)
        _repos = State(initialValue: owned ?? [])
        _starred = State(initialValue: stars ?? [])
        _loaded = State(initialValue: owned != nil && stars != nil)
        _updatedAt = State(initialValue: api.cachedContent([Repository].self, key: "collection:owned")?.savedAt)
    }
    var body: some View {
        AppNavigationStack {
            List {
                ExternalInboxSection(api: api)
                if CredentialStore.read().isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.largeTitle)
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                            Text("连接 GitHub 账号").font(.headline)
                            Text("添加账号后即可浏览仓库、管理发布与同步本地 Git 项目。")
                                .font(.footnote).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("添加账号") { accountPresentation.showing = true }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .listRowBackground(Color.clear)
                    }
                }
                Section {
                    if !CredentialStore.read().isEmpty {
                        RepositoryHomeLinksSection(api: api, owned: repos, starred: starred, loaded: loaded, connected: true)
                        UpstreamUpdatesSection(api: api, store: upstreamUpdates, connected: true) { showUpstreamWatch = true }
                            .id(api.accountID + ":" + AccountStore.generation.uuidString)
                        UserConnectionsSection(api: api, connected: true)
                        PersonalIssuesSection(api: api, store: personalIssues, connected: true)
                    }
                    SoftGroupRows(spacingBefore: CredentialStore.read().isEmpty ? 0 : 10) {
                        SoftGroupRow("discovery") {
                            NavigationLink { CommunityDiscoveryView(api: api) } label: { Label("发现与关注动态", systemImage: "safari") }
                        }
                        SoftGroupRow("permission-help") {
                            Text("提示：删除仓库、创建发行版等操作需在 GitHub Token 中勾选对应权限，缺失时请前往 GitHub 补选。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if updatedAt != nil {
                            SoftGroupRow("freshness") { ContentFreshnessText(updatedAt: updatedAt, updating: busy, error: loadError) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("RepoPocket")
            .adaptiveWorkspaceLayout()
            .toolbar {
                Button { showCreate = true } label: { Image(systemName: "plus") }.accessibilityLabel("新建仓库")
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索仓库或用户")
                    .accessibilityHint("也可粘贴网址搜索代码内容")
                NativeActionMenu(title: "仓库操作", symbol: "ellipsis", items: [
                    NativeMenuItem(id: "open", title: "打开仓库", symbol: "folder", perform: { showOpen = true }),
                    NativeMenuItem(id: "refresh", title: "刷新", symbol: "arrow.clockwise", enabled: !busy, perform: {
                        guard !busy else { return }; Task { await refresh(); loadPersonalIssues(reset: true) }
                    })
                ])
            }
            .refreshable { refreshing = true; await refresh(); loadPersonalIssues(reset: true); refreshing = false }
            .task {
                guard !CredentialStore.read().isEmpty else { return }
                await refresh(); loadPersonalIssues()
            }
            .onChange(of: api.starRevision) { _ in
                guard api.isCurrentSession else { return }
                if let cached = api.cachedCollection(.owned) { repos = cached }
                if let cached = api.cachedCollection(.starred) { starred = cached }
                else if loaded && !busy { Task { await refreshStars() } }
            }
            .sheet(isPresented: $showSearch) { RepositorySearchView(api: api).appSheetCornerRadius() }
            .sheet(isPresented: $showOpen) {
                AppNavigationStack {
                    Form {
                        TextField("仓库链接", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow(top: true)
                        NavigationLink("浏览") { BrowserView(api: api, repo: input, path: "", branch: "") }
                            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).softGroupedRow()
                        Button("Fork 到我的账号") { Task { await fork() } }
                            .disabled(busy || isOwnRepository || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).softGroupedRow(bottom: !isOwnRepository)
                        if isOwnRepository { Text("自己的仓库无需 Fork，直接浏览或上传。").font(.caption).foregroundColor(.secondary).softGroupedRow(bottom: true) }
                    }.navigationTitle("打开仓库").toolbar { Button("关闭") { showOpen = false } }
                }.appSheetCornerRadius()
            }
            .sheet(isPresented: $showCreate) {
                AppNavigationStack {
                    Form {
                        TextField("新仓库名", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow(top: true)
                        Toggle("私有仓库", isOn: $isPrivate).softGroupedRow()
                        Text("在你的 GitHub 账号下创建，包含初始 README。不会覆盖现有仓库。").font(.caption).softGroupedRow()
                        Button("创建仓库") { Task { await create() } }.disabled(busy || newName.isEmpty).softGroupedRow(bottom: true)
                    }.navigationTitle("新建仓库").adaptiveWorkspaceLayout().toolbar { Button("关闭") { showCreate = false } }
                }.appSheetCornerRadius()
            }
        }
        .sheet(isPresented: $showUpstreamWatch) {
            AppNavigationStack {
                UpstreamWatchAddView(api: api) { watch in
                    upstreamUpdates.add(watch, api: api)
                    Task { await upstreamUpdates.refresh(api: api, force: true) }
                }
            }.appSheetCornerRadius()
        }
    }
    private func refreshStars() async {
        guard api.canCheckAppUpdate else { return }
        do {
            let list = try await api.starredRepositories()
            guard api.isCurrentSession else { return }
            starred = list; api.cacheCollection(list, section: .starred)
        } catch { if api.isCurrentSession { api.message = error.localizedDescription } }
    }
    private func loadPersonalIssues(reset: Bool = false) {
        guard !Task.isCancelled, api.isCurrentSession, !api.login.isEmpty else { return }
        if reset { api.issueDeletions.resetPermissions() }
        let login = api.login
        personalIssues.load(reset: reset, api: api) { try await api.personalIssues(login, filter: .involved, page: $0) }
    }
    private var isOwnRepository: Bool {
        guard !api.login.isEmpty else { return false }
        let owner = (try? RepositoryInput.parse(input))?.split(separator: "/").first.map(String.init) ?? ""
        return owner.caseInsensitiveCompare(api.login) == .orderedSame
    }
    private func refresh() async {
        guard !busy else { return }
        let generation = AccountStore.generation
        busy = true; defer { busy = false }
        loadError = ""
        do {
            try await api.identify()
            let result = try await api.repositories().filter { RepositoryGroupRules.isOwned($0.full_name, login: api.login) }
            let stars = try await api.starredRepositories()
            try Task.checkCancellation()
            guard generation == AccountStore.generation else { return }
            repos = result; starred = stars; loaded = true; updatedAt = Date()
            api.cacheCollection(result, section: .owned); api.cacheCollection(stars, section: .starred)
            if refreshing, api.isCurrentSession {
                NotificationCenter.default.post(name: Notification.Name("RepoPocket.avatarRefreshRequested"), object: UUID())
                NotificationCenter.default.post(name: Notification.Name("RepoPocket.upstreamRefreshRequested"), object: api.accountID)
            }
        } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { loadError = error.localizedDescription; api.message = loadError } }
    }
    private func fork() async {
        guard !busy, api.isCurrentSession else { return }
        busy = true; defer { busy = false }
        do { let repo = try await api.fork(input); guard api.isCurrentSession else { return }; api.message = "复刻请求已接受：\(repo.full_name)，正在准备，请稍后刷新。" }
        catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
    private func create() async {
        busy = true; defer { busy = false }
        do { let r = try await api.createRepository(name: newName, isPrivate: isPrivate); input = r.full_name; showCreate = false; api.message = "已创建 \(r.full_name)"; repos = try await api.repositories().filter { RepositoryGroupRules.isOwned($0.full_name, login: api.login) } }
        catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
}

struct BrowserView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let path: String
    let branch: String
    var showFiles = false
    @State private var selectedBranch = ""
    @State private var repositoryInfo: Repository?
    @StateObject private var copyFeedback = RepositoryCopyFeedback()
    @StateObject private var forkMenu = RepositoryForkMenuState()
    private var canWrite: Bool { metadataFresh && RepositoryWriteRules.canWrite(push: repositoryInfo?.permissions?.push, sessionMatches: api.isCurrentSession) }
    @State private var metadataFresh = false
    @StateObject private var metadata = PathCommitMetadataState()
    @State private var openedPathCommit: PathCommitMetadata?
    @State private var loadID: UUID?
    @State private var contentBranch = ""
    @State private var updatedAt: Date?
    @State private var loadError = ""
    @State private var showBranches = false
    @State private var showingHistory = false
    @State private var showingUpstreamSync = false
    @State private var showingRepositoryOwner = false
    @State private var repositoryDescriptionTarget: RepositoryDescriptionTarget?
    @State private var repositoryDeletionTarget: RepositoryDeletionTarget?
    @Environment(\.dismiss) private var dismiss
    private var activeBranch: String { selectedBranch.isEmpty ? branch : selectedBranch }
    @State private var entries: [Entry] = []
    @State private var refreshing = false
    @StateObject private var readmeState = RepositoryReadmeState()
    @State private var revalidationID = UUID()
    @StateObject private var homeRelease = RepositoryPageLoadState<ManagedRelease>()
    @StateObject private var homeRuns = RepositoryPageLoadState<[WorkflowRun]>()
    @State private var busy = false
    @State private var downloadedZIP: URL?
    @State private var showUpload = false
    @State private var debEntry: Entry?
    @State private var deleteEntry: Entry?
    @State private var deleting = false
    @State private var deleteAccount = ""
    @State private var deleteGeneration = UUID()
    @State private var deleteBranch = ""
    init(api: GitHub, repo: String, path: String, branch: String, showFiles: Bool = false) {
        self.api = api; self.repo = repo; self.path = path; self.branch = branch; self.showFiles = showFiles
        let info = api.cachedRepository(repo)
        let selected = branch.isEmpty ? (info?.value.default_branch ?? "") : branch
        let cached = api.cachedContents(repo, path: path, branch: selected)
        _repositoryInfo = State(initialValue: info?.value)
        _selectedBranch = State(initialValue: selected)
        _contentBranch = State(initialValue: selected)
        _entries = State(initialValue: cached?.value ?? [])
        _updatedAt = State(initialValue: cached?.savedAt ?? info?.savedAt)
    }
    @ViewBuilder private var repositorySummary: some View {
                    if let repositoryInfo {
                        HStack(alignment: .top, spacing: 8) {
                            RepositoryCard(repository: repositoryInfo, account: api.login, api: api, descriptionLineLimit: nil, copyLinkContextMenu: false, openOwner: { showingRepositoryOwner = true })
                                .environment(\.repositorySocialAPI, api)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if RepositoryDescriptionRules.canEdit(repositoryInfo, login: api.login, sessionMatches: api.isCurrentSession) {
                                Menu {
                                    Button {
                                        repositoryDescriptionTarget = RepositoryDescriptionTarget(repository: repositoryInfo, context: api.descriptionContext(repositoryInfo))
                                    } label: { Label("编辑描述", systemImage: "pencil") }
                                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                                .buttonStyle(.borderless).accessibilityLabel("仓库描述操作").disabled(busy)
                            }
                        }
                    } else {
                        CompactRepositorySummary(fullName: repo, name: "")
                    }
    }
    @ViewBuilder private var repositoryHeader: some View {
                repositorySummary.textSelection(.enabled).softGroupedRow(top: true)
                if path.isEmpty && !showFiles {
                    HStack(spacing: 16) {
                        RepositoryStarMenuButton(name: repo, repository: repositoryInfo, api: api)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForkRepositoryMenuButton(repository: repo, api: api, state: forkMenu)
                    }.buttonStyle(.borderless).softGroupedRow(bottom: true)
                }
    }
    @ViewBuilder private var repositoryOverview: some View {
                RepositoryCommunitySection(api: api, repo: repo, branch: activeBranch, avatar: repositoryInfo?.owner?.avatar_url, connected: true)
                RepositoryHomeHighlights(api: api, repo: repo, releaseState: homeRelease, runState: homeRuns, connected: true, revalidationID: revalidationID)
                     SoftGroupRows(spacingBefore: 10) {
                        SoftGroupRow("branch") {
                            Button { showBranches = true } label: {
                                HStack { Label(activeBranch.isEmpty ? "默认分支" : activeBranch, systemImage: "arrow.triangle.branch"); Spacer(); Text("更改分支").font(.subheadline) }
                            }
                        }
                        SoftGroupRow("code") {
                            NavigationLink { RepositoryCodeDestination(api: api, repo: repo, branch: activeBranch) } label: { RepositoryFeatureLabel(title: "代码", symbol: "chevron.left.forwardslash.chevron.right", color: .gray) }
                        }
                        SoftGroupRow("history") {
                            NavigationLink { HistoryView(api: api, repo: repo, branch: activeBranch) } label: { RepositoryFeatureLabel(title: "提交", symbol: "clock.arrow.circlepath", color: .gray) }
                        }
                        SoftGroupRow("upstream-sync") {
                            Button("上游同步") { showingUpstreamSync = true }
                                .accessibilityIdentifier("repository-upstream-sync")
                        }
                    }
                RepositoryReadmeSection(api: api, repo: repo, branch: activeBranch, canWrite: canWrite, state: readmeState, connected: true, revalidationID: revalidationID)
    }
    private static func directoryEntryPrecedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if (lhs.type == "dir") != (rhs.type == "dir") { return lhs.type == "dir" }
        let order = lhs.name.localizedStandardCompare(rhs.name)
        if order != .orderedSame { return order == .orderedAscending }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.path < rhs.path
    }
    @SoftGroupRowsBuilder private var directoryRows: [SoftGroupRow] {
            if busy && entries.isEmpty && !refreshing { SoftGroupRow("loading") { LoadingRows() } }
            if entries.isEmpty && !busy {
                SoftGroupRow("empty") { Label("此目录没有文件", systemImage: "folder").foregroundColor(.secondary).padding(.vertical, 4) }
            }
            for e in entries.sorted(by: Self.directoryEntryPrecedes) {
              SoftGroupRow("entry-" + e.id) {
                if e.type == "dir" {
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder").font(.body).frame(width: 20).foregroundStyle(Color.accentColor)
                            Text(e.name).lineLimit(1).truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 28)
                        .accessibilityHidden(true)
                        // Keep the link hit area on the name, without List disclosure indicators.
                        .overlay {
                            NavigationLink { DirectoryBrowserDestination(api: api, repo: repo, path: e.path, branch: activeBranch) } label: { Color.clear.contentShape(Rectangle()) }
                                .buttonStyle(.plain).opacity(0)
                                .accessibilityHidden(false)
                                .accessibilityLabel(e.name)
                                .accessibilityIdentifier("repository-entry-" + e.path)
                        }
                        .contextMenu {
                            Button { copyFeedback.copy(url: RepositoryLinkRules.contentURL(repo, branch: activeBranch, path: e.path, folder: true)) } label: { Label("复制文件夹链接", systemImage: "doc.on.doc") }
                        }
                        PathCommitMetadataLink(path: e.path, commit: metadata.commits[e.path]) { openedPathCommit = $0 }
                    }
                } else if e.type == "file" {
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: e.name.lowercased().hasSuffix(".deb") ? "shippingbox" : "doc.text")
                                .font(.body).frame(width: 20).foregroundStyle(Color.accentColor)
                            Text(e.name).lineLimit(1).truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 28)
                        .accessibilityHidden(true)
                        .overlay {
                            NavigationLink { FileView(api: api, repo: repo, entry: e, branch: activeBranch, canWrite: canWrite) } label: { Color.clear.contentShape(Rectangle()) }
                                .buttonStyle(.plain).opacity(0)
                                .accessibilityHidden(false)
                                .accessibilityLabel(e.name)
                                .accessibilityIdentifier("repository-entry-" + e.path)
                        }
                        PathCommitMetadataLink(path: e.path, commit: metadata.commits[e.path]) { openedPathCommit = $0 }
                        if canWrite && e.name.lowercased().hasSuffix(".deb") {
                            Menu { Button("编辑包信息") { debEntry = e } } label: { Image(systemName: "ellipsis").padding(8) }.accessibilityLabel("更多操作：" + e.name)
                        }
                    }
                    .contextMenu {
                        Button { copyFeedback.copy(url: RepositoryLinkRules.contentURL(repo, branch: activeBranch, path: e.path)) } label: { Label("复制文件链接", systemImage: "doc.on.doc") }
                        Button { copyFeedback.copy(url: RepositoryLinkRules.contentURL(repo, branch: activeBranch, path: e.path, raw: true)) } label: { Label("复制 raw 链接", systemImage: "link") }
                        if canWrite { Button("删除", role: .destructive) {
                            deleteAccount = api.accountID; deleteGeneration = AccountStore.generation
                            deleteBranch = activeBranch; deleteEntry = e
                        }.disabled(deleting || busy || activeBranch.isEmpty) }
                    }
                } else { Text(e.name + " (" + e.type + ")") }
              }
            }
            if updatedAt != nil {
                SoftGroupRow("freshness") { ContentFreshnessText(updatedAt: updatedAt, updating: busy, error: loadError) }
            }
            if !metadata.error.isEmpty { SoftGroupRow("commit-error") { Text(metadata.error).font(.caption).foregroundStyle(.secondary) } }
    }
    var body: some View {
        List {
            if path.isEmpty && !showFiles {
                Section {
                    repositoryHeader
                    repositoryOverview
                }
            } else {
                Section {
                    SoftGroupRows {
                        SoftGroupRow("repository-summary") {
                            repositorySummary.textSelection(.enabled).accessibilityIdentifier("repository-code-summary")
                        }
                        directoryRows
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .appScrollContentBackgroundHidden()
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(path.isEmpty ? (showFiles ? "代码" : ((try? RepositoryInput.parse(repo))?.split(separator: "/").last.map(String.init) ?? repo)) : (path as NSString).lastPathComponent)
        .adaptiveWorkspaceLayout()
        .refreshable {
            refreshing = true
            defer { refreshing = false }
            await load()

        }
        .toolbar {
            if showFiles || !path.isEmpty {
                NavigationLink {
                    RepositoryFileSearchView(api: api, repo: repo, branch: activeBranch, canWrite: canWrite)
                        .id(api.accountID + ":" + activeBranch)
                } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("搜索文件和文件夹").disabled(busy || activeBranch.isEmpty)
            }
            if canWrite && (showFiles || !path.isEmpty) { Button("上传") { showUpload = true }.disabled(busy) }
            RepositoryBrowserActionMenu(api: api, repo: repo, repository: repositoryInfo, forkState: forkMenu,
                includesSocialActions: !path.isEmpty || showFiles, includesBranchHistory: !path.isEmpty || showFiles, enabled: !busy,
                copyLink: NativeMenuItem(id: "copy-link", title: "复制仓库链接", symbol: "doc.on.doc",
                    enabled: RepositoryLinkRules.canonicalURL(repo) != nil, perform: { copyFeedback.copy(repo) }),
                switchBranch: NativeMenuItem(id: "branches", title: "切换 / 创建分支", symbol: "arrow.triangle.branch", perform: {
                    guard !busy, api.isCurrentSession else { return }; showBranches = true
                }),
                items: [
                    NativeMenuItem(id: "download-zip", title: "下载整个仓库 ZIP", symbol: "arrow.down.circle", perform: {
                        guard !busy, api.isCurrentSession else { return }; Task { await zip() }
                    }),
                    NativeMenuItem(id: "refresh", title: "刷新目录", symbol: "arrow.clockwise", perform: {
                        guard !busy, api.isCurrentSession else { return }
                        Task { refreshing = true; defer { refreshing = false }; await load() }
                    }),
                    NativeMenuItem(id: "delete-repository", title: "删除远端仓库…", symbol: "trash", enabled: repositoryInfo?.permissions?.admin == true && !deleting, destructive: true, perform: {
                        guard !busy, !deleting, api.isCurrentSession else { return }
                        if let repositoryInfo, repositoryInfo.permissions?.admin == true {
                            repositoryDeletionTarget = RepositoryDeletionTarget(repository: repositoryInfo, context: api.deletionContext(repositoryInfo))
                        }
                    })
                ], showHistory: { guard !busy, api.isCurrentSession else { return }; showingHistory = true })
        }
        .repositoryCopyNotice(copyFeedback)
        .downloadCompletionNotice($downloadedZIP)
        .repositoryForkConfirmation(forkMenu, api: api)
        .appNavigationDestination(isPresented: Binding(get: { openedPathCommit != nil }, set: { if !$0 { openedPathCommit = nil } })) {
            if let commit = openedPathCommit {
                CommitDetailView(api: api, repo: repo, sha: commit.oid)
            }
        }
        .appNavigationDestination(isPresented: $showingHistory) {
            HistoryView(api: api, repo: repo, branch: activeBranch)
        }
        .appNavigationDestination(isPresented: $showingUpstreamSync) {
            UpstreamSyncView(api: api, repo: repo, branch: activeBranch, canWrite: canWrite, repository: repositoryInfo)
        }
        .appNavigationDestination(isPresented: $showingRepositoryOwner) {
            if let repositoryInfo {
                let owner = RepositoryPresentationRules.owner(login: repositoryInfo.owner?.login, fullName: repositoryInfo.full_name)
                UserRepositoriesView(api: api, user: User(id: nil, login: owner, avatar_url: repositoryInfo.owner?.avatar_url, name: nil, followers: nil, following: nil))
            }
        }
        .task { await load() }
        .onAppear { revalidationID = UUID() }
        .onDisappear { metadata.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .repositoryHistoryChanged)) { notice in
            if notice.userInfo?["repo"] as? String == repo, notice.userInfo?["branch"] as? String == activeBranch,
               notice.userInfo?["account"] as? String == api.accountID, notice.userInfo?["generation"] as? UUID == AccountStore.generation {
                metadata.cancel(); Task { await load() }
            }
        }
        .sheet(item: $repositoryDescriptionTarget) { target in
            RepositoryDescriptionView(api: api, target: target) { updated in
                guard api.isCurrentSession, updated.id == target.repository.id,
                      updated.full_name.caseInsensitiveCompare(repo) == .orderedSame else { return }
                repositoryInfo = updated
            }
        }
        .sheet(item: $repositoryDeletionTarget) { target in
            RepositoryDeletionView(api: api, repository: target.repository, context: target.context) {
                entries = []; repositoryInfo = nil; dismiss()
            }
        }
        .sheet(isPresented: $showBranches) {
            BranchPickerView(api: api, repo: repo, current: activeBranch, canWrite: canWrite) { chosen in
                selectedBranch = chosen; Task { await load() }
            }
        }
        .sheet(isPresented: $showUpload, onDismiss: { Task { await load() } }) {
            if canWrite { UploadView(api: api, initialRepo: repo, directory: path, initialBranch: activeBranch, openedFromFolder: true) }
        }
        .sheet(item: $debEntry) { entry in DebEditorView(api: api, remote: (repo, entry, activeBranch), canWrite: canWrite) }
        .confirmationDialog("永久删除仓库中的文件？", isPresented: Binding(get: { deleteEntry != nil }, set: { if !$0 { deleteEntry = nil } }), titleVisibility: .visible) {
            Button("确认删除", role: .destructive) { if let entry = deleteEntry, !deleting {
                let account = deleteAccount, generation = deleteGeneration, branch = deleteBranch
                deleting = true
                Task { await deleteRemote(entry, account: account, generation: generation, branch: branch) }
            } }
            Button("取消", role: .cancel) { deleteEntry = nil }
        } message: { Text(deleteEntry?.path ?? "") }
    }
    private func load() async {
        let token = UUID(); loadID = token
        let generation = AccountStore.generation
        let requestedBranch = activeBranch
        if contentBranch != requestedBranch {
            let cached = api.cachedContents(repo, path: path, branch: requestedBranch)
            entries = cached?.value ?? []; updatedAt = cached?.savedAt
            contentBranch = requestedBranch
        }
        metadataFresh = false; loadError = ""
        busy = true; defer { if loadID == token { busy = false } }
        self.metadata.load(api: api, repo: repo, branch: requestedBranch, entries: entries)
        async let metadata = api.repository(repo)
        do {
            let resolved: String
            if requestedBranch.isEmpty {
                guard let branch = try await metadata.default_branch, !branch.isEmpty else { throw AppError(text: "仓库没有默认分支") }
                resolved = branch
            } else { resolved = requestedBranch }
            let result: [Entry] = path.isEmpty && !showFiles ? [] : try await api.contents(repo, path: path, branch: resolved)
            try Task.checkCancellation()
            guard loadID == token, api.isCurrentSession, generation == AccountStore.generation, activeBranch == requestedBranch else { return }
            selectedBranch = resolved; contentBranch = resolved; entries = result; updatedAt = Date()
            self.metadata.load(api: api, repo: repo, branch: resolved, entries: result)
            if refreshing, api.isCurrentSession {
                NotificationCenter.default.post(name: Notification.Name("RepoPocket.avatarRefreshRequested"), object: UUID())
            }
        } catch { if loadID == token, api.isCurrentSession, !RefreshFailure.isCancellation(error) { loadError = error.localizedDescription; api.message = loadError } }
        // Optional metadata cannot block files, and cached permissions never enable writes.
        do {
            let info = try await metadata
            try Task.checkCancellation()
            guard loadID == token, api.isCurrentSession, generation == AccountStore.generation else { return }
            repositoryInfo = info; metadataFresh = true
        } catch { /* Unavailable metadata stays hidden; contents errors remain visible. */ }
    }
    private func deleteRemote(_ entry: Entry, account: String, generation: UUID, branch: String) async {
        defer { deleting = false; deleteEntry = nil }
        do {
            guard api.accountID == account, AccountStore.generation == generation,
                  activeBranch == branch, !branch.isEmpty,
                  entries.contains(where: { $0.path == entry.path && $0.sha == entry.sha }) else {
                throw AppError(text: "账号、分支或列表已变化，请刷新后重试")
            }
            let fresh = try await api.file(repo, path: entry.path, branch: branch)
            guard fresh.type == "file", fresh.sha == entry.sha,
                  api.accountID == account, AccountStore.generation == generation, activeBranch == branch else {
                throw AppError(text: "远端文件已变化，拒绝删除新内容；请刷新后重试")
            }
            try Task.checkCancellation()
            // GitHub DELETE uses the originally confirmed SHA, never the refreshed one.
            try await api.delete(repo, entry: entry, message: "Delete \(entry.name) via RepoPocket", branch: branch)
            entries.removeAll { $0.path == entry.path && $0.sha == entry.sha }
            api.message = "已删除并提交：\(entry.name)"
        } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
    private func zip() async {
        busy = true; defer { busy = false }
        do {
            downloadedZIP = nil
            let generation = AccountStore.generation
            try await DownloadStore.shared.requireAuthorization()
            guard api.isCurrentSession else { throw CancellationError() }
            DownloadStore.shared.begin(); defer { DownloadStore.shared.end() }
            let temporary = try await api.downloadZIP(repo, branch: activeBranch)
            defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
            let saved = try await DownloadStore.shared.persist(temporary, session: generation)
            guard api.isCurrentSession else { throw CancellationError() }
            downloadedZIP = saved
        }
        catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
}

struct FileView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let entry: Entry
    let branch: String
    var canWrite: Bool = false
    private var writable: Bool { canWrite && api.isCurrentSession }
    @State private var text = ""
    @State private var currentSHA = ""
    @State private var editable = false
    @State private var busy = false
    @State private var downloadedFile: URL?
    @State private var commitMessage = "Update file via RepoPocket"
    @State private var showDeb = false
    @State private var confirmSave = false
    @State private var confirmDelete = false
    @State private var deleted = false
    private struct LoadedText { let text: String; let sha: String }
    @StateObject private var sourceRequest = RepositoryPageLoadState<LoadedText>()
    @State private var readingError = ""
    @State private var editing = false
    @State private var originalText = ""
    @State private var showFileInfo = false
    @State private var showingHistory = false
    private var showsDownloadInBody: Bool { !deleted && !editable && !busy }
    private var fileMenuItems: [NativeMenuItem] {
        var items = [NativeMenuItem(id: "info", title: "文件信息", symbol: "info.circle", perform: { showFileInfo = true })]
        // Loading and deleted states have no fallback body; keep the disabled menu action visible.
        if !showsDownloadInBody {
            items.append(NativeMenuItem(id: "download", title: "下载 / 存到文件", symbol: "arrow.down.circle", enabled: !busy && !deleted, perform: {
                guard !busy, !deleted, api.isCurrentSession else { return }; Task { await download() }
            }))
        }
        items.append(NativeMenuItem(id: "history", title: "此文件的历史记录", symbol: "clock.arrow.circlepath", perform: { showingHistory = true }))
        if editable {
            items.append(NativeMenuItem(id: "reload", title: "重新加载", symbol: "arrow.clockwise", enabled: !busy && !deleted, perform: {
                guard !busy, !deleted, api.isCurrentSession else { return }; Task { await read() }
            }))
        }
        if writable && entry.name.lowercased().hasSuffix(".deb") {
            items.append(NativeMenuItem(id: "deb", title: "编辑包信息", symbol: "shippingbox", enabled: !busy && !deleted, perform: {
                guard writable, !busy, !deleted else { return }; showDeb = true
            }))
        }
        if writable {
            items.append(NativeMenuItem(id: "delete", title: "删除仓库里的此文件", symbol: "trash", enabled: !busy && !deleted, destructive: true, perform: {
                guard writable, !busy, !deleted else { return }; confirmDelete = true
            }))
        }
        return items
    }
    var body: some View {
        VStack(spacing: 0) {
            if deleted { Text("文件已删除，请返回目录刷新。").padding(); Spacer() }
            else if editable { FileReadingView(text: originalText, path: entry.path, repo: repo, branch: branch, api: api) }
            else if busy { ProgressView("正在加载文件…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                VStack(spacing: 16) {
                    Image(systemName: "doc").font(.largeTitle).foregroundStyle(.secondary)
                    Text(readingError.isEmpty ? "此文件需下载后使用对应应用打开。" : readingError).foregroundStyle(.secondary)
                    if !readingError.isEmpty { Button("重试读取") { Task { await read() } } }
                    Button("下载 / 存到文件") { Task { await download() } }.disabled(busy)
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !readingError.isEmpty && editable { Text(readingError).font(.caption).foregroundStyle(.secondary).padding() }
        }.background(Color(uiColor: .systemBackground))
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if SourceTextRules.automaticallyLoads(filename: entry.name, size: entry.size) { await read(refresh: false) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if writable && editable && !deleted { Button("编辑") { text = originalText; editing = true }.disabled(busy || currentSHA.isEmpty) }
                NativeActionMenu(title: "文件操作", items: fileMenuItems)
            }
        }
        .appNavigationDestination(isPresented: $showingHistory) {
            NativeFileHistoryView(api: api, repo: repo, path: entry.path, branch: branch)
        }
        .sheet(isPresented: $showFileInfo) { fileInformation }
        .sheet(isPresented: $editing, onDismiss: { text = originalText }) { editor }
        .sheet(isPresented: $showDeb) { DebEditorView(api: api, remote: (repo, entry, branch), canWrite: writable) }
        .downloadCompletionNotice($downloadedFile)
        .confirmationDialog("永久删除仓库中的 \(entry.name)？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("确认删除", role: .destructive) { Task { await remove() } }
        }
    }
    private var fileInformation: some View {
        AppNavigationStack {
            Form { Section {
                SoftGroupRows {
                    SoftGroupRow("name") { Text(entry.name).font(.headline) }
                    SoftGroupRow("path") { AppLabeledContent("路径") { Text(entry.path).textSelection(.enabled) } }
                    SoftGroupRow("repo") { AppLabeledContent("仓库", value: repo) }
                    SoftGroupRow("branch") { AppLabeledContent("分支", value: branch.isEmpty ? "默认分支" : branch) }
                    SoftGroupRow("language") { AppLabeledContent("语言", value: SourceLanguage.detect(entry.name).rawValue) }
                }
            } }.navigationTitle("文件信息").adaptiveWorkspaceLayout().toolbar { Button("关闭") { showFileInfo = false } }
        }
    }
    private var editor: some View {
        AppNavigationStack {
            VStack(spacing: 0) {
                SourceCodeEditor(text: $text, filename: entry.path).disabled(busy)
                if text.utf8.count > SourceTextRules.byteLimit { Text("内容超过 1 MiB，请缩小后再提交。").font(.caption).foregroundStyle(.red).padding(.horizontal) }
                Divider()
                TextField("提交说明", text: $commitMessage)
                    .textFieldStyle(.roundedBorder).frame(minHeight: 44)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }.navigationTitle("编辑 " + entry.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = false }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button(busy ? "提交中…" : "提交") {
                    // End input before presenting, so dismissing confirmation cannot restore the keyboard.
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    confirmSave = true
                }
                    .disabled(busy || !writable || text == originalText || text.utf8.count > SourceTextRules.byteLimit || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .confirmationDialog("把修改提交到 \(repo)？", isPresented: $confirmSave, titleVisibility: .visible) { Button("确认提交") { Task { await save() } } }
            .interactiveDismissDisabled(busy)
        }
    }
    private func read(refresh: Bool = true) async {
        guard !busy, !deleted, api.isCurrentSession else { return }
        if editable && !refresh { return }
        readingError = ""
        busy = true; defer { busy = false }
        await sourceRequest.load(key: api.accountID + ":" + repo + ":" + branch + ":" + entry.path, refresh: refresh, operation: {
            guard entry.size == nil || (entry.size ?? 0) <= SourceTextRules.byteLimit else { throw AppError(text: "编辑器只加载 1 MiB 内文本；其他文件可下载或替换上传。") }
            let f = try await api.file(repo, path: entry.path, branch: branch)
            guard f.encoding == "base64", let s = f.content,
                  let bytes = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else { throw AppError(text: "此文件未提供可读取的文本内容，请下载后打开。") }
            let t = try SourceTextRules.decode(bytes)
            return LoadedText(text: t, sha: f.sha)
        }, isValid: { api.isCurrentSession })
        guard api.isCurrentSession else { return }
        if sourceRequest.error.isEmpty, let document = sourceRequest.value {
            text = document.text; originalText = document.text; currentSHA = document.sha; editable = true
        }
        readingError = sourceRequest.error
    }
    private func save() async {
        guard writable, !busy, !currentSHA.isEmpty, text.utf8.count <= SourceTextRules.byteLimit else { return }
        busy = true; defer { busy = false }
        do {
            try await api.requireWriteAccess(repo)
            try await api.commit(repo, path: entry.path, bytes: Data(text.utf8), sha: currentSHA, message: commitMessage, branch: branch)
            originalText = text; editing = false; currentSHA = ""
            api.message = "修改已提交到 GitHub。"
            // A failed post-save read must not permit another PUT with an old SHA.
            do {
                let fresh = try await api.file(repo, path: entry.path, branch: branch)
                guard let content = fresh.content, let bytes = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { throw AppError(text: "无法重新读取文本") }
                let confirmed = try SourceTextRules.decode(bytes)
                if confirmed != originalText { originalText = confirmed; text = confirmed; api.message = "提交成功；远端随后有新修改，已重新载入，请确认后编辑。" }
                currentSHA = fresh.sha
            } catch { if api.isCurrentSession { readingError = "提交已成功，但无法重新读取当前文件；请从菜单重新加载后再编辑。" } }
        } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
    private func remove() async {
        busy = true; defer { busy = false }
        do {
            let fresh = try await api.file(repo, path: entry.path, branch: branch)
            try await api.delete(repo, entry: fresh, message: "Delete \(entry.name) via RepoPocket", branch: branch)
            deleted = true; api.message = "删除已提交。"
        } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
    private func download() async {
        busy = true; defer { busy = false }
        do {
            downloadedFile = nil
            let generation = AccountStore.generation
            try await DownloadStore.shared.requireAuthorization()
            guard api.isCurrentSession else { throw CancellationError() }
            DownloadStore.shared.begin(); defer { DownloadStore.shared.end() }
            let temporary = try await api.downloadFile(repo, entry: entry, branch: branch)
            defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
            let saved = try await DownloadStore.shared.persist(temporary, session: generation)
            guard api.isCurrentSession else { throw CancellationError() }
            downloadedFile = saved
        }
        catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
}

struct SettingsView: View {
    @ObservedObject var api: GitHub
    @ObservedObject var updateChecker: UpdateChecker
    @State private var pendingRemoval: GitHubAccount?
    @EnvironmentObject private var accountPresentation: AccountPresentation
    @State private var token = ""
    @State private var busy = false
    @AppStorage("appearance.mode") private var appearance = "system"
    @ObservedObject private var downloads = DownloadStore.shared
    var body: some View {
        AppNavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        GitHubAvatar(url: api.profile?.avatar_url ?? savedAccount?.avatarURL, size: 56)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(api.profile?.name.flatMap { $0.isEmpty ? nil : $0 } ?? api.profile?.login ?? savedAccount?.login ?? "尚未登录")
                                .font(.title3.weight(.semibold))
                            if let login = api.profile?.login ?? savedAccount?.login {
                                Text("@" + login).font(.subheadline).foregroundColor(.secondary)
                            }
                            AppAdaptiveLayout {
                                HStack(spacing: 12) { socialCounts }
                            } vertical: {
                                VStack(alignment: .leading, spacing: 4) { socialCounts }
                            }.font(.caption).foregroundColor(.secondary)
                            if savedAccount == nil {
                                Button("添加账号") { accountPresentation.showing = true }.frame(minHeight: 44)
                            }
                        }
                        Spacer(minLength: 0)
                        if savedAccount != nil {
                            Button { accountPresentation.showing = true } label: {
                                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                            }.accessibilityLabel("账号管理：切换、添加或移除本机账号")
                        }
                    }.padding(.vertical, 8).softGroupedRow(top: true, bottom: savedAccount == nil)
                    if savedAccount != nil {
                        NavigationLink { SocialAccountsView(api: api) } label: { Label("社交账号", systemImage: "link") }
                            .accessibilityIdentifier("settings-social-accounts").softGroupedRow(bottom: true)
                    }
                    Text("关于").font(.subheadline).foregroundStyle(.secondary).softGroupedRow(top: true, spacingBefore: 10)
                    AppUpdateSection(api: api, checker: updateChecker, connected: true)
                    // The version is the stable final row of the update group in every state.
                    Text("RepoPocket " + AppUpdateSessionRules.version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—", build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")).foregroundColor(.secondary).softGroupedRow(bottom: true)
                }
            }.appGroupedFormStyle().navigationTitle("设置").navigationBarTitleDisplayMode(.inline).adaptiveWorkspaceLayout()
            .toolbar {
                NativeActionMenu(title: "设置选项", accessibilityIdentifier: "settings-options", items: [
                    NativeMenuItem.submenu("通用", symbol: "gearshape", children: [
                        NativeMenuItem.submenu("主题", symbol: "circle.lefthalf.filled", singleSelection: true, children:
                            [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")].map { mode, title in
                                NativeMenuItem(id: "theme-" + mode, title: title, selectedState: { appearance == mode }) { appearance = mode }
                            })
                    ]),
                    NativeMenuItem(id: "download-folder", title: "选择文件夹", symbol: "folder", enabled: downloads.operations == 0, hint: downloads.label) {
                        guard downloads.operations == 0 else { return }; downloads.choose()
                    }
                ]).frame(width: 44, height: 44)
            }
            .task { if !CredentialStore.read().isEmpty { try? await api.identify() } }
            .task { updateChecker.enterPage() }
            .onDisappear { if !updateChecker.sharing { updateChecker.leavePage() } }
            .refreshable { await refreshProfile() }

        }
    }
    private var savedAccount: GitHubAccount? {
        AccountStore.accounts.first { $0.id == api.accountID }
    }
    @ViewBuilder private var socialCounts: some View {
        if let followers = api.profile?.followers { Text("关注者 \(followers.formatted())") }
        if let following = api.profile?.following { Text("正在关注 \(following.formatted())") }
    }
    private func refreshProfile() async {
        guard !busy, !CredentialStore.read().isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            try await api.identify()
            guard api.isCurrentSession else { return }
            NotificationCenter.default.post(name: Notification.Name("RepoPocket.avatarRefreshRequested"), object: UUID())
        }
        catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
    private func verify() async {
        busy = true; defer { busy = false }
        let credential = token
        do {
            try await TokenVerification.submit(credential) { try await api.addAccount(token: $0) }
            token = ""
        }
        catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
}
