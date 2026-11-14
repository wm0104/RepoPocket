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
    @EnvironmentObject private var accountPresentation: AccountPresentation
    @State private var selectedTab = 0
    @State private var startupSheetVisible = false
    @State private var startupSheetQueued = false
    var body: some View {
            TabView(selection: $selectedTab) {
                RepositoriesView(api: api).tabItem { Label("主页", systemImage: "house") }.tag(0)
                LocalProjectsView(api: api, store: localGit).tabItem { Label("Git", systemImage: "arrow.triangle.branch") }.tag(1)
                UploadView(api: api).tabItem { Label("提交 / 发布", systemImage: "arrow.up.doc") }.tag(3)
                SettingsView(api: api, updateChecker: updateChecker).tabItem { Label("设置", systemImage: "gear") }.tag(4)
            }
            .task { await updateChecker.automaticCheck(api: api) }
            // Ask the system for network access during launch, not mid-Token or mid-check.
            .task { await NetworkWarmup.runOnceIfNeeded() }
            .onReceive(updateChecker.$startupRelease) { release in
                guard release != nil, !startupSheetQueued else { return }
                startupSheetQueued = true
            }
            .task(id: startupSheetQueued) { await queueStartupSheet() }
            .sheet(isPresented: $startupSheetVisible, onDismiss: {
                // Swiping the sheet away counts as skipping this version, like 暂不更新.
                updateChecker.skipAndDismissStartupRelease(accountID: api.accountID)
                startupSheetQueued = false
            }) {
                if let release = updateChecker.startupRelease {
                    StartupUpdateCard(api: api, checker: updateChecker, release: release) {
                        updateChecker.dismissStartupUpdate()
                        selectedTab = 4
                    }.appSheetCornerRadius()
                }
            }
            .alert("提示", isPresented: Binding(get: { !api.message.isEmpty }, set: { if !$0 { api.message = "" } })) {
                Button("好", role: .cancel) { api.message = "" }
            } message: { Text(api.message) }
    }

    // Reads of other observable objects stay out of body: during view evaluation a
    // missing or mid-transition dependency would trap, and this path must never do that.
    private func queueStartupSheet() async {
        guard startupSheetQueued else { return }
        // Let an existing system presentation finish its native dismissal first.
        do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
        guard !Task.isCancelled, startupSheetQueued, updateChecker.startupRelease != nil,
              api.isCurrentSession, api.message.isEmpty,
              !accountPresentation.showing, DownloadStore.shared.picker == nil else { return }
        startupSheetVisible = true
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
    @State private var attempted = false
    @StateObject private var personalIssues = CommunityPageStore<CollaborationItem>()
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
    var body: some View {
        NavigationStack {
            List {
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
                } else {
                    RepositoryHomeLinksSection(api: api, owned: repos, starred: starred, loaded: loaded)
                    UserConnectionsSection(api: api)
                    PersonalIssuesSection(api: api, store: personalIssues)
                }
                Section {
                    NavigationLink { CommunityDiscoveryView(api: api) } label: { Label("发现与关注动态", systemImage: "safari") }.softGroupedRow(top: true, bottom: true)
                }
                Section {
                    Text("提示：删除仓库、创建发行版等操作需在 GitHub Token 中勾选对应权限，缺失时请前往 GitHub 补选。")
                        .font(.caption).foregroundStyle(.secondary)
                        .softGroupedRow(top: true, bottom: true)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("RepoPocket")
            .adaptiveWorkspaceLayout()
            .toolbar {
                Button { showCreate = true } label: { Image(systemName: "plus") }.accessibilityLabel("新建仓库")
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索仓库或用户")
                Menu {
                    Button("打开仓库") { showOpen = true }
                    Button("刷新") { Task { await refresh(); loadPersonalIssues(reset: true) } }.disabled(busy)
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("仓库操作")
            }
            .refreshable { refreshing = true; await refresh(); loadPersonalIssues(reset: true); refreshing = false }
            .task {
                guard !attempted, !CredentialStore.read().isEmpty else { return }
                attempted = true; await refresh(); loadPersonalIssues()
            }
            .onChange(of: api.starRevision) { _ in
                guard api.isCurrentSession else { return }
                if let cached = api.cachedCollection(.owned) { repos = cached }
                if let cached = api.cachedCollection(.starred) { starred = cached }
                else if loaded && !busy { Task { await refreshStars() } }
            }
            .sheet(isPresented: $showSearch) { RepositorySearchView(api: api).appSheetCornerRadius() }
            .sheet(isPresented: $showOpen) {
                NavigationStack {
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
                NavigationStack {
                    Form {
                        TextField("新仓库名", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow(top: true)
                        Toggle("私有仓库", isOn: $isPrivate).softGroupedRow()
                        Text("在你的 GitHub 账号下创建，包含初始 README。不会覆盖现有仓库。").font(.caption).softGroupedRow()
                        Button("创建仓库") { Task { await create() } }.disabled(busy || newName.isEmpty).softGroupedRow(bottom: true)
                    }.navigationTitle("新建仓库").adaptiveWorkspaceLayout().toolbar { Button("关闭") { showCreate = false } }
                }.appSheetCornerRadius()
            }
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
        do {
            try await api.identify()
            let result = try await api.repositories().filter { RepositoryGroupRules.isOwned($0.full_name, login: api.login) }
            let stars = try await api.starredRepositories()
            try Task.checkCancellation()
            guard generation == AccountStore.generation else { return }
            repos = result; starred = stars; loaded = true
            api.cacheCollection(result, section: .owned); api.cacheCollection(stars, section: .starred)
        } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
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
    @State private var creatingRelease = false
    private var canWrite: Bool { RepositoryWriteRules.canWrite(push: repositoryInfo?.permissions?.push, sessionMatches: api.isCurrentSession) }
    @State private var showBranches = false
    @State private var showingRepositoryOwner = false
    @State private var repositoryDescriptionTarget: RepositoryDescriptionTarget?
    @State private var repositoryDeletionTarget: RepositoryDeletionTarget?
    @Environment(\.dismiss) private var dismiss
    private var activeBranch: String { selectedBranch.isEmpty ? branch : selectedBranch }
    @State private var entries: [Entry] = []
    @State private var loaded = false
    @State private var refreshing = false
    @StateObject private var readmeState = RepositoryReadmeState()
    @StateObject private var homeRelease = RepositoryPageLoadState<ManagedRelease>()
    @StateObject private var homeRuns = RepositoryPageLoadState<[WorkflowRun]>()
    @State private var busy = false
    @State private var downloadedZIP: URL?
    @State private var showUpload = false
    @State private var debEntry: Entry?
    @State private var metadataEntry: Entry?
    @State private var deleteEntry: Entry?
    @State private var deleting = false
    @State private var deleteAccount = ""
    @State private var deleteGeneration = UUID()
    @State private var deleteBranch = ""
    @ViewBuilder private var repositoryHeader: some View {
            Section {
                Group {
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
                }.textSelection(.enabled).softGroupedRow(top: true, bottom: !(path.isEmpty && !showFiles))
                if path.isEmpty && !showFiles {
                    HStack(spacing: 16) {
                        RepositoryStarMenuButton(name: repo, repository: repositoryInfo, api: api)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForkRepositoryMenuButton(repository: repo, api: api, state: forkMenu)
                    }.buttonStyle(.borderless).softGroupedRow(bottom: true)
                }
            }
    }
    @ViewBuilder private var repositoryOverview: some View {
                RepositoryCommunitySection(api: api, repo: repo, branch: activeBranch, avatar: repositoryInfo?.owner?.avatar_url)
                RepositoryHomeHighlights(api: api, repo: repo, releaseState: homeRelease, runState: homeRuns)
                Section {
                    SoftGroupRows {
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
                            NavigationLink { UpstreamSyncView(api: api, repo: repo, branch: activeBranch, canWrite: canWrite, repository: repositoryInfo) } label: { Text("上游同步") }
                        }
                    }
                }
                RepositoryReadmeSection(api: api, repo: repo, branch: activeBranch, canWrite: canWrite, state: readmeState)
    }
    @ViewBuilder private var directoryRows: some View {
            if busy && entries.isEmpty && !refreshing { LoadingRows() }
            if entries.isEmpty && !busy {
                Label("此目录没有文件", systemImage: "folder").foregroundColor(.secondary).padding(.vertical)
            }
            ForEach(entries) { e in
                if e.type == "dir" {
                    NavigationLink { DirectoryBrowserDestination(api: api, repo: repo, path: e.path, branch: activeBranch) } label: { Label(e.name, systemImage: "folder") }
                        .softGroupedRow(top: e.id == entries.first?.id, bottom: e.id == entries.last?.id)
                } else if e.type == "file" {
                    HStack {
                        NavigationLink { FileView(api: api, repo: repo, entry: e, branch: activeBranch, canWrite: canWrite) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: e.name.lowercased().hasSuffix(".deb") ? "shippingbox.fill" : "doc.text.fill")
                                    .font(.title3).foregroundColor(.accentColor)
                                    .frame(width: 40, height: 44)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.045), lineWidth: 0.5)
                    }
                                VStack(alignment: .leading, spacing: 4) { Text(e.name); Text(ByteCountFormatter.string(fromByteCount: Int64(e.size ?? 0), countStyle: .file)).font(.caption).monospacedDigit().foregroundColor(.secondary) }
                            }.padding(.vertical, 6)
                        }
                        if canWrite && e.name.lowercased().hasSuffix(".deb") {
                            Menu { Button("编辑包信息") { debEntry = e } } label: { Image(systemName: "ellipsis").padding(8) }.accessibilityLabel("更多操作：" + e.name)
                        } else if canWrite && e.name.lowercased().hasSuffix(".dylib") {
                            Menu { Button("编辑插件信息") { metadataEntry = e } } label: { Image(systemName: "ellipsis").padding(8) }.accessibilityLabel("更多操作：" + e.name)
                        }
                    }
                    .softGroupedRow(top: e.id == entries.first?.id, bottom: e.id == entries.last?.id)
                    .contextMenu {
                        if canWrite { Button("删除", role: .destructive) {
                            deleteAccount = api.accountID; deleteGeneration = AccountStore.generation
                            deleteBranch = activeBranch; deleteEntry = e
                        }.disabled(deleting || busy || activeBranch.isEmpty) }
                    }
                } else { Text(e.name + " (" + e.type + ")").softGroupedRow(top: e.id == entries.first?.id, bottom: e.id == entries.last?.id) }
            }
    }
    var body: some View {
        List {
            repositoryHeader
            if path.isEmpty && !showFiles { repositoryOverview } else { directoryRows }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(path.isEmpty ? (showFiles ? "代码" : ((try? RepositoryInput.parse(repo))?.split(separator: "/").last.map(String.init) ?? repo)) : (path as NSString).lastPathComponent)
        .adaptiveWorkspaceLayout()
        .refreshable {
            refreshing = true
            defer { refreshing = false }
            await load()

        }
        .toolbar {
            if canWrite { Button("上传") { showUpload = true }.disabled(busy) }
            Menu {
                CopyRepositoryLinkButton(repository: repo, feedback: copyFeedback)
                if !path.isEmpty || showFiles {
                    ForkRepositoryMenuButton(repository: repo, api: api, state: forkMenu)
                    RepositoryStarMenuButton(name: repo, repository: repositoryInfo, api: api)
                }
                Button("切换 / 创建分支") { showBranches = true }
                NavigationLink("提交历史") { HistoryView(api: api, repo: repo, branch: activeBranch) }
                if path.isEmpty && canWrite { Button("新建发行版") { creatingRelease = true } }
                Button("下载整个仓库 ZIP") { Task { await zip() } }
                Button("刷新目录") { Task { await load() } }
                Button("删除远端仓库…", role: .destructive) {
                    if let repositoryInfo, repositoryInfo.permissions?.admin == true {
                        repositoryDeletionTarget = RepositoryDeletionTarget(repository: repositoryInfo, context: api.deletionContext(repositoryInfo))
                    }
                }.disabled(repositoryInfo?.permissions?.admin != true || deleting)
            } label: { Image(systemName: "ellipsis.circle") }.disabled(busy)
        }
        .repositoryCopyNotice(copyFeedback)
        .downloadCompletionNotice($downloadedZIP)
        .repositoryForkConfirmation(forkMenu, api: api)
        .navigationDestination(isPresented: $showingRepositoryOwner) {
            if let repositoryInfo {
                let owner = RepositoryPresentationRules.owner(login: repositoryInfo.owner?.login, fullName: repositoryInfo.full_name)
                UserRepositoriesView(api: api, user: User(id: nil, login: owner, avatar_url: repositoryInfo.owner?.avatar_url, name: nil, followers: nil, following: nil))
            }
        }
        .task { if !loaded { await load() } }
        .sheet(isPresented: $creatingRelease) { if canWrite { ReleaseEditorView(api: api, repo: repo, original: nil).appSheetCornerRadius() } }
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
                selectedBranch = chosen; loaded = false; Task { await load() }
            }
        }
        .sheet(isPresented: $showUpload, onDismiss: { Task { await load() } }) {
            if canWrite { UploadView(api: api, initialRepo: repo, directory: path, initialBranch: activeBranch, openedFromFolder: true) }
        }
        .sheet(item: $metadataEntry) { entry in TrollMetadataView(api: api, repo: repo, entry: entry, branch: activeBranch, canWrite: canWrite) }
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
        guard !busy else { return }
        let generation = AccountStore.generation
        let requestedBranch = activeBranch
        repositoryInfo = nil
        busy = true; defer { busy = false }
        do {
            let resolved = requestedBranch.isEmpty ? try await api.resolvedBranch(repo, branch: "") : requestedBranch
            let result = try await api.contents(repo, path: path, branch: resolved)
            try Task.checkCancellation()
            guard generation == AccountStore.generation, activeBranch == requestedBranch else { return }
            selectedBranch = resolved; entries = result; loaded = true
        } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
        // Statistics are optional metadata: their failure must not block file browsing.
        // Fetch once after contents; do not clear repositoryInfo again here — the
        // initial reset above already cleared it, and a second reset flips canWrite
        // and re-lays out the list (a relayout storm when browsing nested
        // directories that froze the main thread).
        do {
            let info = try await api.repository(repo)
            try Task.checkCancellation()
            guard generation == AccountStore.generation else { return }
            repositoryInfo = info
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
    @State private var showMetadata = false
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
                Menu {
                    Button("文件信息") { showFileInfo = true }
                    Button("下载 / 存到文件") { Task { await download() } }.disabled(busy || deleted)
                    NavigationLink("此文件的历史记录") { NativeFileHistoryView(api: api, repo: repo, path: entry.path, branch: branch) }
                    if editable { Button("重新加载") { Task { await read() } }.disabled(busy || deleted) }
                    if writable && entry.name.lowercased().hasSuffix(".deb") { Button("编辑包信息") { showDeb = true }.disabled(busy || deleted) }
                    if writable && entry.name.lowercased().hasSuffix(".dylib") { Button("编辑插件信息") { showMetadata = true }.disabled(busy || deleted) }
                    if writable { Button("删除仓库里的此文件", role: .destructive) { confirmDelete = true }.disabled(busy || deleted) }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("文件操作")
            }
        }
        .sheet(isPresented: $showFileInfo) { fileInformation }
        .sheet(isPresented: $editing, onDismiss: { text = originalText }) { editor }
        .sheet(isPresented: $showDeb) { DebEditorView(api: api, remote: (repo, entry, branch), canWrite: writable) }
        .sheet(isPresented: $showMetadata) { TrollMetadataView(api: api, repo: repo, entry: entry, branch: branch, canWrite: writable) }
        .downloadCompletionNotice($downloadedFile)
        .confirmationDialog("永久删除仓库中的 \(entry.name)？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("确认删除", role: .destructive) { Task { await remove() } }
        }
    }
    private var fileInformation: some View {
        NavigationStack {
            Form { Section {
                SoftGroupRows {
                    SoftGroupRow("name") { Text(entry.name).font(.headline) }
                    SoftGroupRow("path") { LabeledContent("路径") { Text(entry.path).textSelection(.enabled) } }
                    SoftGroupRow("repo") { LabeledContent("仓库", value: repo) }
                    SoftGroupRow("branch") { LabeledContent("分支", value: branch.isEmpty ? "默认分支" : branch) }
                    SoftGroupRow("language") { LabeledContent("语言", value: SourceLanguage.detect(entry.name).rawValue) }
                }
            } }.navigationTitle("文件信息").adaptiveWorkspaceLayout().toolbar { Button("关闭") { showFileInfo = false } }
        }
    }
    private var editor: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SourceCodeEditor(text: $text, filename: entry.path)
                if text.utf8.count > SourceTextRules.byteLimit { Text("内容超过 1 MiB，请缩小后再提交。").font(.caption).foregroundStyle(.red).padding(.horizontal) }
                Divider()
                Form { Section { TextField("提交说明", text: $commitMessage).softGroupedRow(top: true, bottom: true) } }
                    .scrollDisabled(true).frame(height: 100)
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
    var body: some View {
        NavigationStack {
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
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) { socialCounts }
                                VStack(alignment: .leading, spacing: 4) { socialCounts }
                            }.font(.caption).foregroundColor(.secondary)
                            if savedAccount == nil {
                                Button("添加账号") { accountPresentation.showing = true }.frame(minHeight: 44)
                            }
                        }
                        Spacer(minLength: 0)
                        Button { accountPresentation.showing = true } label: {
                            Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                        }.accessibilityLabel("账号管理：切换、添加或移除本机账号")
                    }.padding(.vertical, 8).softGroupedRow(top: true, bottom: savedAccount == nil)
                    if savedAccount != nil {
                        NavigationLink { SocialAccountsView(api: api) } label: { Label("社交账号", systemImage: "link") }
                            .accessibilityIdentifier("settings-social-accounts").softGroupedRow(bottom: true)
                    }
                }
                Section("账号与安全") {
                    Text("Token 仅保存在本机钥匙串，切换账号自动隔离，账号资料不含 Token。")
                        .font(.caption).foregroundColor(.secondary)
                        .softGroupedRow(top: true, bottom: true)
                }
                Section("通用") {
                    Picker("主题", selection: $appearance) {
                        Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                    }.softGroupedRow(top: true, bottom: true)
                }
                DownloadLocationSection()
                Section("关于") {
                    AppUpdateSection(api: api, checker: updateChecker)
                    // The version is the stable final row of the update group in every state.
                    Text("RepoPocket " + AppUpdateSessionRules.version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—", build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")).foregroundColor(.secondary).softGroupedRow(bottom: true)
                }
            }.formStyle(.grouped).navigationTitle("设置").adaptiveWorkspaceLayout()
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
        do { try await api.identify() }
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
