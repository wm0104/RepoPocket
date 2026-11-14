import SwiftUI
import UIKit

@main
struct RepoPocketApp: App {
    @State private var accountID = AccountStore.generation
    @StateObject private var selectionStore = WorkspaceSelectionStore()
    @StateObject private var accountPresentation = AccountPresentation()
    @StateObject private var downloads = DownloadStore.shared
    var body: some Scene {
        WindowGroup {
            ZStack { AccountRootView().id(accountID) }
                .environmentObject(selectionStore)
                .environmentObject(accountPresentation)
                .sheet(isPresented: $accountPresentation.showing) { AccountManagementView().environmentObject(accountPresentation) }
                .sheet(item: $downloads.picker, onDismiss: { downloads.selected(nil) }) { request in
                    WorkspaceDocumentPicker(request: request, allowsMultipleSelection: false, cancelTitle: "取消") { downloads.selected($0) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .githubAccountChanged)) { _ in
                    accountID = AccountStore.generation
                }
        }
    }
}

struct AccountRootView: View {
    @StateObject private var api = GitHub()
    @StateObject private var gitCore = GitCore()
    var body: some View {
            TabView {
                RepositoriesView(api: api).tabItem { Label("仓库", systemImage: "shippingbox") }
                GitWorkspaceView().environmentObject(gitCore).tabItem { Label("Git", systemImage: "arrow.triangle.branch") }
                WorkspaceView(api: api).tabItem { Label("本地", systemImage: "folder.badge.gearshape") }
                UploadView(api: api).tabItem { Label("提交 / 发布", systemImage: "arrow.up.doc") }
                SettingsView(api: api).tabItem { Label("设置", systemImage: "gear") }
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
    @State private var ownedExpanded = true
    @State private var starredExpanded = true
    @State private var repos: [Repository] = []
    @State private var starred: [Repository] = []
    @State private var showOpen = false
    @State private var showSearch = false
    @State private var collectionSearch: RepositoryHomeSection?
    @State private var pendingFork: Repository?
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
                if CredentialStore.read().isEmpty { Button("添加账号") { accountPresentation.showing = true } }
                RepositoryInlineSection(api: api, section: .owned, expanded: $ownedExpanded,
                    repositories: repos, loaded: loaded, busy: busy, fork: { pendingFork = $0 }, search: { collectionSearch = .owned })
                RepositoryInlineSection(api: api, section: .starred, expanded: $starredExpanded,
                    repositories: starred, loaded: loaded, busy: busy, fork: { pendingFork = $0 }, search: { collectionSearch = .starred })
            }
            .listStyle(.insetGrouped)
            .navigationTitle("RepoPocket")
            .adaptiveWorkspaceLayout()
            .toolbar {
                Button { showCreate = true } label: { Image(systemName: "plus") }.accessibilityLabel("新建仓库")
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索仓库或用户")
                Menu {
                    Button("打开仓库") { showOpen = true }
                    Button("刷新") { Task { await refresh() } }.disabled(busy)
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("仓库操作")
            }
            .refreshable { refreshing = true; await refresh(); refreshing = false }
            .task { if !loaded && !CredentialStore.read().isEmpty { await refresh() } }
            .onChange(of: api.starRevision) { _ in
                guard api.isCurrentSession else { return }
                if let cached = api.cachedCollection(.owned) { repos = cached }
                if let cached = api.cachedCollection(.starred) { starred = cached }
                else if loaded && !busy { Task { await refreshStars() } }
            }
            .sheet(item: $collectionSearch) { section in
                NavigationStack {
                    RepositoryCollectionView(api: api, section: section, initialRepositories: loaded ? (section == .owned ? repos : starred) : nil)
                        .toolbar { Button("关闭") { collectionSearch = nil } }
                }
            }
            .sheet(isPresented: $showSearch) { RepositorySearchView(api: api) }
            .sheet(isPresented: $showOpen) {
                NavigationStack {
                    Form {
                        TextField("仓库链接", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled()
                        NavigationLink("浏览") { BrowserView(api: api, repo: input, path: "", branch: "") }
                            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Fork 到我的账号") { Task { await fork() } }
                            .disabled(busy || isOwnRepository || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if isOwnRepository { Text("自己的仓库无需 Fork，直接浏览或上传。").font(.caption).foregroundColor(.secondary) }
                    }.navigationTitle("打开仓库").toolbar { Button("关闭") { showOpen = false } }
                }
            }
            .confirmationDialog("复刻到我的仓库？", isPresented: Binding(get: { pendingFork != nil }, set: { if !$0 { pendingFork = nil } }), titleVisibility: .visible) {
                if let repository = pendingFork {
                    Button("复刻") { input = repository.full_name; pendingFork = nil; Task { await fork() } }
                }
                Button("取消", role: .cancel) { pendingFork = nil }
            } message: { Text(pendingFork?.full_name ?? "") }
            .sheet(isPresented: $showCreate) {
                NavigationStack {
                    Form {
                        TextField("新仓库名", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Toggle("私有仓库", isOn: $isPrivate)
                        Text("在你的 GitHub 账号下创建，包含初始 README。不会覆盖现有仓库。").font(.caption)
                        Button("创建仓库") { Task { await create() } }.disabled(busy || newName.isEmpty)
                    }.navigationTitle("新建仓库").adaptiveWorkspaceLayout().toolbar { Button("关闭") { showCreate = false } }
                }
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
    @State private var selectedBranch = ""
    @State private var repositoryInfo: Repository?
    @StateObject private var copyFeedback = RepositoryCopyFeedback()
    @StateObject private var forkMenu = RepositoryForkMenuState()
    private var canWrite: Bool { RepositoryWriteRules.canWrite(push: repositoryInfo?.permissions?.push, sessionMatches: api.isCurrentSession) }
    @State private var showBranches = false
    @State private var repositoryDeletionTarget: RepositoryDeletionTarget?
    @Environment(\.dismiss) private var dismiss
    private var activeBranch: String { selectedBranch.isEmpty ? branch : selectedBranch }
    @State private var entries: [Entry] = []
    @State private var loaded = false
    @State private var refreshing = false
    @State private var busy = false
    @State private var share: SharedFile?
    @State private var showUpload = false
    @State private var debEntry: Entry?
    @State private var metadataEntry: Entry?
    @State private var deleteEntry: Entry?
    @State private var deleting = false
    @State private var deleteAccount = ""
    @State private var deleteGeneration = UUID()
    @State private var deleteBranch = ""
    var body: some View {
        List {
            Section {
                Group {
                    if let repositoryInfo {
                        RepositoryCard(repository: repositoryInfo, account: api.login, api: api, descriptionLineLimit: nil, copyLinkContextMenu: false)
                    } else {
                        CompactRepositorySummary(fullName: repo, name: "")
                    }
                }.textSelection(.enabled).softGroupedRow(top: true, bottom: true)
            }
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if canWrite { Button("删除", role: .destructive) {
                            deleteAccount = api.accountID; deleteGeneration = AccountStore.generation
                            deleteBranch = activeBranch; deleteEntry = e
                        }.disabled(deleting || busy || activeBranch.isEmpty) }
                    }
                } else { Text(e.name + " (" + e.type + ")").softGroupedRow(top: e.id == entries.first?.id, bottom: e.id == entries.last?.id) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(path.isEmpty ? "仓库文件" : (path as NSString).lastPathComponent)
        .adaptiveWorkspaceLayout()
        .refreshable { refreshing = true; await load(); refreshing = false }
        .toolbar {
            if canWrite { Button("上传") { showUpload = true }.disabled(busy) }
            Menu {
                CopyRepositoryLinkButton(repository: repo, feedback: copyFeedback)
                ForkRepositoryMenuButton(repository: repo, api: api, state: forkMenu)
                RepositoryStarMenuButton(name: repo, repository: repositoryInfo, api: api)
                Button("切换 / 创建分支") { showBranches = true }
                NavigationLink("提交历史") { HistoryView(api: api, repo: repo, branch: activeBranch) }
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
        .repositoryForkConfirmation(forkMenu, api: api)
        .task { if !loaded { await load() } }
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
        .sheet(item: $share) { ShareSheet(url: $0.url) }
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
            let generation = AccountStore.generation
            try await DownloadStore.shared.requireAuthorization()
            guard api.isCurrentSession else { throw CancellationError() }
            DownloadStore.shared.begin(); defer { DownloadStore.shared.end() }
            let temporary = try await api.downloadZIP(repo, branch: activeBranch)
            defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
            let saved = try DownloadStore.shared.persist(temporary, session: generation)
            guard api.isCurrentSession else { throw CancellationError() }
            api.message = "已保存到 " + DownloadStore.shared.label
            share = SharedFile(url: saved)
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
    @State private var commitMessage = "Update file via RepoPocket"
    @State private var share: SharedFile?
    @State private var showMetadata = false
    @State private var showDeb = false
    @State private var confirmSave = false
    @State private var confirmDelete = false
    @State private var deleted = false
    var body: some View {
        Form {
            Section("文件") {
                Label(entry.name, systemImage: entry.name.lowercased().hasSuffix(".deb") ? "shippingbox.fill" : "doc.text.fill")
                    .font(.headline).foregroundColor(.primary).padding(.vertical, 4).softGroupedRow(top: true)
                LabeledContent("路径") { Text(entry.path).textSelection(.enabled) }
                LabeledContent("仓库", value: repo)
                LabeledContent("分支", value: branch.isEmpty ? "默认分支" : branch).softGroupedRow(bottom: true)
            }
            Section {
                if writable && entry.name.lowercased().hasSuffix(".deb") { Button("编辑包信息") { showDeb = true }.disabled(busy || deleted) }
                if writable && entry.name.lowercased().hasSuffix(".dylib") { Button("编辑插件信息") { showMetadata = true }.disabled(busy || deleted) }
                Button("下载 / 存到文件") { Task { await download() } }.disabled(busy || deleted)
                Button("加载文本（最多 1 MiB）") { Task { await read() } }.disabled(busy || deleted)
                if busy { ProgressView() }
            }
            if editable && !deleted {
                if !writable { Section("文本预览") { Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled) } }
                else {
                Section("编辑") { TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 260).softGroupedRow(top: true, bottom: true) }
                Section("提交") {
                    TextField("提交说明", text: $commitMessage).softGroupedRow(top: true)
                    Button("提交文本修改") { confirmSave = true }.disabled(busy).softGroupedRow(bottom: true)
                }
            }
            }
            if writable { Section { Button("删除仓库里的此文件", role: .destructive) { confirmDelete = true }.disabled(busy || deleted).softGroupedRow(top: true, bottom: true) } }
            if deleted { Text("文件已删除，请返回目录刷新。") }
        }
        .navigationTitle(entry.name)
        .adaptiveWorkspaceLayout()
        .sheet(item: $share) { ShareSheet(url: $0.url) }
        .sheet(isPresented: $showDeb) { DebEditorView(api: api, remote: (repo, entry, branch), canWrite: writable) }
        .sheet(isPresented: $showMetadata) { TrollMetadataView(api: api, repo: repo, entry: entry, branch: branch, canWrite: writable) }
        .confirmationDialog("把修改提交到 \(repo)？", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("确认提交") { Task { await save() } }
        }
        .confirmationDialog("永久删除仓库中的 \(entry.name)？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("确认删除", role: .destructive) { Task { await remove() } }
        }
    }
    private func read() async {
        busy = true; defer { busy = false }
        do {
            guard (entry.size ?? Int.max) <= 1024 * 1024 else { throw AppError(text: "编辑器只加载 1 MiB 内文本；其他文件可下载或替换上传。") }
            let f = try await api.file(repo, path: entry.path, branch: branch)
            guard f.encoding == "base64", let s = f.content,
                  let bytes = Data(base64Encoded: s, options: .ignoreUnknownCharacters), !bytes.contains(0),
                  let t = String(data: bytes, encoding: .utf8) else { throw AppError(text: "不是支持的 UTF-8 文本，不会强行编辑二进制文件。") }
            text = t; currentSHA = f.sha; editable = true
        } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
    private func save() async {
        busy = true; defer { busy = false }
        do {
            try await api.commit(repo, path: entry.path, bytes: Data(text.utf8), sha: currentSHA, message: commitMessage, branch: branch)
            currentSHA = try await api.file(repo, path: entry.path, branch: branch).sha
            api.message = "修改已提交到 GitHub。"
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
            let generation = AccountStore.generation
            try await DownloadStore.shared.requireAuthorization()
            guard api.isCurrentSession else { throw CancellationError() }
            DownloadStore.shared.begin(); defer { DownloadStore.shared.end() }
            let temporary = try await api.downloadFile(repo, entry: entry, branch: branch)
            defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
            let saved = try DownloadStore.shared.persist(temporary, session: generation)
            guard api.isCurrentSession else { throw CancellationError() }
            api.message = "已保存到 " + DownloadStore.shared.label
            share = SharedFile(url: saved)
        }
        catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
}

struct SettingsView: View {
    @ObservedObject var api: GitHub
    @StateObject private var updateChecker = UpdateChecker()
    @State private var pendingRemoval: GitHubAccount?
    @EnvironmentObject private var accountPresentation: AccountPresentation
    @State private var token = ""
    @State private var busy = false
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
                    }.padding(.vertical, 8).softGroupedRow(top: true, bottom: true)
                }
                Section {
                    NavigationLink {
                        RepositoryCollectionView(api: api, section: .owned)
                    } label: { Label("我的仓库", systemImage: "folder") }
                        .softGroupedRow(top: true)
                    NavigationLink {
                        RepositoryCollectionView(api: api, section: .starred)
                    } label: { Label("已加星标", systemImage: "star") }
                        .softGroupedRow(bottom: true)
                }
                DownloadLocationSection()
                CacheSettingsSection(api: api, checker: updateChecker)
                Section("安全") {
                    Text("每个账号的 Token 独立保存于本机钥匙串。切换账号会关闭旧页面，防止将旧仓库操作提交给新账号。账号资料不含 Token。").softGroupedRow(top: true, bottom: true)
                }
                Section {
                    AppUpdateSection(api: api, checker: updateChecker)
                    // The version is the stable final row of the update group in every state.
                    Text("RepoPocket \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") · iOS 16+").foregroundColor(.secondary).softGroupedRow(bottom: true)
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
        do { let credential = token; token = ""; try await api.addAccount(token: credential) }
        catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription } }
    }
}
