import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Combine

struct ReleaseManagementDestination: View {
    private let build: () -> AnyView
    init(api: GitHub, repo: String, id: Int? = nil) {
        build = { id.map { AnyView(ReleaseDetailView(api: api, repo: repo, id: $0)) } ?? AnyView(ReleaseListView(api: api, repo: repo)) }
    }
    var body: AnyView { build() }
}

@MainActor final class ReleaseScreenState: ObservableObject {
    let api: GitHub
    @Published var repo: String
    let generation = AccountStore.generation
    @Published var busy = false
    @Published var error = ""
    @Published var progress: Double = 0
    @Published var canWrite = false
    @Published var latestID: Int?
    @Published var rows: [ReleaseSummary] = []
    @Published var assets: [Asset] = []
    @Published var release: ManagedRelease?
    @Published var notice = ""
    @Published var more = false
    @Published var listLoaded = false
    @Published var assetMore = false
    @Published private(set) var assetDownload: ReleaseAssetDownload?
    @Published var completedDownload: URL?
    private var page = 1
    private var removedReleaseIDs = Set<Int>()
    private var assetPage = 1
    private var task: Task<Void, Never>?
    private var operation = UUID()
    private var accountObserver: AnyCancellable?
    private var listObserver: AnyCancellable?
    private let downloader: ReleaseAssetDownloading
    init(api: GitHub, repo: String, downloader: ReleaseAssetDownloading? = nil) {
        self.api = api; self.repo = repo; self.downloader = downloader ?? LiveReleaseAssetDownloader()
        accountObserver = NotificationCenter.default.publisher(for: .githubAccountChanged).sink { [weak self] _ in
            self?.cancel(); self?.completedDownload = nil; self?.canWrite = false; self?.rows = []; self?.assets = []; self?.release = nil; self?.notice = ""; self?.latestID = nil
        }
        listObserver = NotificationCenter.default.publisher(for: .releaseManagementChanged).sink { [weak self] in
            self?.applyListChange($0)
        }
    }
    var valid: Bool { generation == AccountStore.generation && api.isCurrentSession }
    func cancel() {
        operation = UUID(); task?.cancel(); task = nil; busy = false
        if assetDownload?.active == true { assetDownload?.stage = .cancelled }
    }
    func run(_ work: @escaping () async throws -> Void) {
        guard valid, !busy else { return }
        busy = true; error = ""; notice = ""; progress = 0
        assetDownload = nil
        completedDownload = nil
        let token = UUID(); operation = token
        task = Task {
            defer { if operation == token { busy = false; task = nil } }
            do { try await work() }
            catch { if valid && operation == token && !RefreshFailure.isCancellation(error) && !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func check() throws { try Task.checkCancellation(); guard valid else { throw CancellationError() } }
    private func applyListChange(_ notification: Notification) {
        guard valid, listLoaded, let info = notification.userInfo,
              info["generation"] as? UUID == generation,
              let changedRepo = info["repo"] as? String,
              changedRepo.caseInsensitiveCompare(repo) == .orderedSame else { return }
        if let deleted = info["deletedReleaseID"] as? Int, rows.contains(where: { $0.id == deleted }) {
            cancel()
            removedReleaseIDs.insert(deleted)
            rows.removeAll { $0.id == deleted }
            // Deletion shifts page boundaries; re-read the last loaded page and merge by ID.
            if page > ReleaseManagementRules.pageLimit { more = true }
            page = min(page, rows.count / ReleaseManagementRules.pageSize + 1)
            latestID = nil
        }
        if let saved = info["release"] as? ManagedRelease, let index = rows.firstIndex(where: { $0.id == saved.id }) {
            rows[index] = ReleaseSummary(id: saved.id, tag_name: saved.tag_name, name: saved.name,
                draft: saved.draft, prerelease: saved.prerelease, created_at: saved.created_at, published_at: saved.published_at)
            latestID = nil // The server may have changed the official Latest; manual refresh rechecks it.
        }
    }
    func prepareImport() {
        guard valid, !busy else { return }
        assetDownload = nil; error = ""; notice = ""
    }
    func access() async throws {
        canWrite = false
        do {
            let info = try await api.managedRepository(repo); try check()
            canWrite = ReleaseManagementRules.canWrite(info.permissions?.push, session: valid)
        } catch {
            try check() // Cancellation/session changes propagate; permission failures remain read-only.
        }
    }
    func list(reset: Bool) {
        run {
            if reset { self.page = 1; self.rows = []; self.listLoaded = false; self.removedReleaseIDs = []; try await self.access() }
            let p = self.page
            let batch = try await self.api.managedReleases(self.repo, page: p); try self.check()
            self.rows = ReleaseManagementRules.merged(self.rows, batch.filter { !self.removedReleaseIDs.contains($0.id) })
            self.listLoaded = true
            self.more = ReleaseManagementRules.more(count: batch.count, page: p)
            self.page = self.removedReleaseIDs.isEmpty ? p + 1 : min(p + 1, self.rows.count / ReleaseManagementRules.pageSize + 1)
            if reset {
                self.latestID = nil
                do { self.latestID = try await self.api.managedLatestID(self.repo, refresh: true); try self.check() }
                catch { try self.check() } // Unknown stays unmarked; never infer Latest from dates.
            }
        }
    }
    func detail(_ id: Int) {
        run { try await self.access(); try await self.reload(id) }
    }
    func reload(_ id: Int) async throws {
        let r = try await api.managedRelease(repo, id: id); try check()
        release = r; assets = []; assetPage = 1
        try await nextAssets(id)
    }
    func nextAssets(_ id: Int) async throws {
        let p = assetPage
        let batch = try await api.managedAssets(repo, id: id, page: p); try check()
        assets = ReleaseManagementRules.merged(assets, batch)
        assetMore = ReleaseManagementRules.more(count: batch.count, page: p); assetPage = p + 1
    }
    func download(_ asset: Asset) {
        guard valid, !busy else { return }
        let initial = ReleaseAssetDownload(assetID: asset.id)
        run {
            do {
            try await self.downloader.authorize(); try self.check()
            guard self.assetDownload?.request == initial.request else { throw CancellationError() }
            self.assetDownload?.stage = .connecting
            self.downloader.begin(); defer { self.downloader.end() }
            let temporary = try await self.downloader.download(api: self.api, repo: self.repo, asset: asset) { [weak self] value in
                Task { @MainActor in
                    guard let self, self.valid, self.busy, self.assetDownload?.request == initial.request,
                          self.assetDownload?.stage == .connecting || self.assetDownload?.stage == .downloading else { return }
                    self.assetDownload?.stage = .downloading; self.assetDownload?.progress = value
                }
            }
            defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
            try self.check()
            self.assetDownload?.stage = .saving
            let saved = try await self.downloader.persist(temporary, generation: self.generation)
            try self.check()
            self.assetDownload?.stage = .completed
            self.completedDownload = saved
            } catch {
                if self.valid, self.assetDownload?.request == initial.request {
                    self.assetDownload?.stage = RefreshFailure.isCancellation(error) || Task.isCancelled ? .cancelled : .failed
                    self.assetDownload?.message = error.localizedDescription
                }
                throw error
            }
        }
        assetDownload = initial
    }
}

struct ReleaseListView: View {
    @StateObject private var state: ReleaseScreenState
    @State private var creating = false
    init(api: GitHub, repo: String) { _state = StateObject(wrappedValue: ReleaseScreenState(api: api, repo: repo)) }
    var body: some View {
        List {
            Section {
                SoftGroupRows(bottom: !releaseHasStatus(state)) {
                    SoftGroupRow("repository") { Text(state.repo).font(.caption) }
                    for row in state.rows {
                        SoftGroupRow("release-\(row.id)") {
                            NavigationLink { ReleaseManagementDestination(api: state.api, repo: state.repo, id: row.id) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(row.title).lineLimit(2)
                                    Text(row.tag_name + " · " + ChinaDate.day(row.date)).font(.caption)
                                    if row.draft { Text("草稿").font(.caption) }
                                    if row.prerelease { Text("预发行").font(.caption) }
                                    if state.latestID == row.id && !row.draft && !row.prerelease { Text("最新发行版").font(.caption) }
                                }
                                .padding(.vertical, 7)
                            }
                        }
                    }
                    if state.rows.isEmpty && !state.busy {
                        SoftGroupRow("empty") { Text(state.listLoaded && state.error.isEmpty ? "暂无发行版" : "尚未成功加载发行版，可手动刷新。") }
                    }
                    if state.more {
                        SoftGroupRow("next") { Button("加载下一页") { state.list(reset: false) }.disabled(state.busy) }
                    }
                }
                releaseStatus(state)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("发行版")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("刷新") { state.list(reset: true) }.disabled(state.busy)
                if state.canWrite {
                    Button("新建发行版") { creating = true }.disabled(state.busy || !state.valid)
                }
            }
        }
        .task { if !state.listLoaded { state.list(reset: true) } }
        .onDisappear { state.cancel() }
        .sheet(isPresented: $creating, onDismiss: { state.list(reset: true) }) {
            ReleaseEntryView(api: state.api, initialRepo: state.repo).appSheetCornerRadius()
        }
    }
}

private struct ReleaseDeleteTarget: Identifiable {
    let id = UUID()
    let repo: String
    let generation: UUID
    let release: ManagedRelease
    let asset: Asset?
}
struct ReleaseDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state: ReleaseScreenState
    let id: Int
    @State private var expanded = false
    @State private var editing = false
    @State private var picking = false
    @State private var pickingInbox = false
    @State private var inboxSelection: [URL] = []
    @State private var uploading: URL?
    @State private var deleteTarget: ReleaseDeleteTarget?
    @State private var copied = false
    init(api: GitHub, repo: String, id: Int, downloader: ReleaseAssetDownloading? = nil) {
        self.id = id; _state = StateObject(wrappedValue: ReleaseScreenState(api: api, repo: repo, downloader: downloader))
    }
    init(state: ReleaseScreenState, id: Int) { self.id = id; _state = StateObject(wrappedValue: state) }
    var body: some View {
        List {
            Section {
                SoftGroupRows(bottom: state.assetDownload != nil || !releaseHasStatus(state)) {
                    if let r = state.release {
                        SoftGroupRow("title") { Text(r.title) }
                        SoftGroupRow("tag") { Text(r.tag_name + " · " + ChinaDate.day(r.date)).font(.caption) }
                        SoftGroupRow("marker") { Text(r.draft ? "草稿" : (r.prerelease ? "预发行" : "已发布")) }
                        SoftGroupRow("body") {
                            VStack(alignment: .leading, spacing: 0) {
                                DisclosureGroup("发布说明", isExpanded: $expanded) {
                                    if expanded {
                                        VStack(alignment: .leading, spacing: 12) {
                                            Text(ReleaseManagementRules.displayBody(r.body ?? "")).textSelection(.enabled)
                                            if (r.body ?? "").count > ReleaseManagementRules.displayBodyLimit {
                                                Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5)
                                                Text("显示已限额；完整正文保留，编辑不截断。请在 GitHub 查看全文。").font(.caption)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        SoftGroupRow("assets-heading") { Text("附件").font(.subheadline).foregroundStyle(.secondary) }
                        for asset in state.assets {
                            SoftGroupRow("asset-\(asset.id)") {
                                VStack(alignment: .leading, spacing: 6) {
                                    // One presenter per attachment: the icon, text and empty space open the same menu.
                                    Menu {
                                        assetActions(asset)
                                        if state.canWrite {
                                            Button("删除附件", role: .destructive) { prepareDelete(r, asset: asset) }
                                        }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: asset.name.lowercased().hasSuffix(".deb") ? "shippingbox" : "doc.text")
                                                .font(.body).foregroundStyle(.tint).frame(width: 24)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(asset.name).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                                                Text(ByteCountFormatter.string(fromByteCount: Int64(asset.size), countStyle: .file))
                                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                            }
                                        }
                                            .padding(.horizontal, 20).padding(.vertical, 8)
                                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.borderless).disabled(state.busy || !state.valid)
                                        .accessibilityIdentifier("release-asset-\(asset.id)")
                                    if let download = state.assetDownload, download.assetID == asset.id, download.stage != .completed {
                                        ReleaseAssetDownloadStatusView(download: download, cancel: { state.cancel() }, retry: { state.download(asset) })
                                            .padding(.horizontal, 20).padding(.bottom, 10)
                                    }
                                }.listRowInsets(EdgeInsets())
                            }
                        }
                        if state.assets.isEmpty && !state.assetMore { SoftGroupRow("no-assets") { Text("暂无附件") } }
                        if state.assetMore { SoftGroupRow("next-assets") { Button("加载更多附件") { state.run { try await state.nextAssets(id) } }.disabled(state.busy) } }
                        SoftGroupRow("asset-help") { Text("私有附件需在浏览器登录。").font(.caption).foregroundStyle(.secondary) }
                        if state.canWrite && !ReleaseManagementRules.editable(r.body ?? "") {
                            SoftGroupRow("body-limit") { Text("正文超过128 KiB，禁止本地编辑，避免截断保存；请在 GitHub 编辑。").font(.caption) }
                        }
                    }
                }
                if state.assetDownload == nil { releaseStatus(state, top: state.release == nil) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("发行版详情")
        .downloadCompletionNotice($state.completedDownload)
        .alert("下载链接已复制", isPresented: $copied) { Button("好", role: .cancel) {} }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("刷新") { state.detail(id) }.disabled(state.busy)
                if state.canWrite, let r = state.release {
                    Button(r.draft ? "编辑/发布草稿" : "编辑发行版") { editing = true }
                        .disabled(state.busy || !state.valid || !ReleaseManagementRules.editable(r.body ?? ""))
                    NativeActionMenu(title: "更多操作", accessibilityIdentifier: "release-management-actions",
                        enabled: state.canWrite && state.valid && !state.busy, items: managementItems(r))
                        .frame(width: 44, height: 44)
                }
            }
        }
        .task { if state.release == nil { state.detail(id) } }
        .onDisappear { state.cancel() }
        .sheet(isPresented: $editing, onDismiss: { state.detail(id) }) {
            if let r = state.release { ReleaseEditorView(api: state.api, repo: state.repo, original: r).appSheetCornerRadius() }
        }
        .sheet(isPresented: $pickingInbox, onDismiss: {
            uploading = inboxSelection.first; inboxSelection = []
        }) {
            ShareInboxView(multiple: false) { files in inboxSelection = files; pickingInbox = false }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let file): uploading = file
            case .failure(let error): if !RefreshFailure.isCancellation(error) { state.error = error.localizedDescription }
            }
        }
        .sheet(isPresented: Binding(get: { uploading != nil }, set: { if !$0 { uploading = nil } }), onDismiss: { state.detail(id) }) {
            if let file = uploading, let release = state.release {
                ReleaseAttachmentReview(api: state.api, repo: state.repo, original: release, source: file) {
                    ReleaseManagementChanges.changed(api: state.api, repo: state.repo)
                }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { performDelete() }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { Text(deleteDescription) }
    }
    private func managementItems(_ r: ManagedRelease) -> [NativeMenuItem] {
        [
            .submenu("上传附件", symbol: "paperclip", children: [
                NativeMenuItem(id: "upload-file", title: "选择文件", symbol: "folder", perform: {
                    state.prepareImport(); picking = true
                }),
                NativeMenuItem(id: "upload-inbox", title: "从待上传文件选择", symbol: "tray", perform: {
                    state.prepareImport(); pickingInbox = true
                })
            ]),
            NativeMenuItem(id: "delete-release", title: "删除发行版（不删除 git 标签）", symbol: "trash",
                destructive: true, perform: { prepareDelete(r, asset: nil) })
        ]
    }
    private var deleteTitle: String {
        deleteTarget?.asset == nil ? "确认删除整个发行版？" : "确认删除这个附件？"
    }
    @ViewBuilder private func assetActions(_ asset: Asset) -> some View {
        Button("下载并保存") { state.download(asset) }.disabled(state.busy || !state.valid)
        if let link = ReleaseManagementRules.browserDownloadURL(asset.browser_download_url, repo: state.repo) {
            Button("复制下载链接") { UIPasteboard.general.url = link; copied = true }
        }
    }
    private var deleteDescription: String {
        guard let target = deleteTarget else { return "" }
        return "\(target.repo) · Release #\(target.release.id) · \(target.release.tag_name)\n" + (target.asset.map { "附件 #\($0.id) · \($0.name)" } ?? "整个发行版及附件；不删 git 标签") + "\n此操作不可恢复。"
    }
    private func prepareDelete(_ r: ManagedRelease, asset: Asset?) {
        deleteTarget = ReleaseDeleteTarget(repo: state.repo, generation: state.generation, release: r, asset: asset)
    }
    private func performDelete() {
        guard let target = deleteTarget, target.repo == state.repo, target.generation == AccountStore.generation else { deleteTarget = nil; return }
        deleteTarget = nil
        state.run {
            try await state.api.deleteManagedRelease(target.repo, original: target.release, asset: target.asset)
            try state.check()
            ReleaseManagementChanges.changed(api: state.api, repo: target.repo,
                deletedReleaseID: target.asset == nil ? target.release.id : nil)
            if target.asset == nil { dismiss() } else { try await state.reload(id) }
        }
    }

}

struct ReleaseEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state: ReleaseScreenState
    let original: ManagedRelease?
    let initialFiles: [URL]
    let allowsRepositorySelection: Bool
    @State private var repositoryInput: String
    @State private var makeNewRepository = false
    @State private var newRepositoryName = ""
    @State private var newRepositoryPrivate = true
    @State private var createdRepository = false
    @State private var initialFilesLoaded = false
    @State private var reviewFingerprint: String?
    @State private var reviewHead = ""
    @State private var preflighting = false
    @State private var form: ReleaseForm
    @State private var confirm = false
    @StateObject private var targetState = ReleaseBranchState()
    private var targetReady: Bool { state.valid && targetState.ready }
    let initialBranch: String
    @State private var markerReady = false
    @State private var attachments: [ReleaseAttachment] = []
    @State private var pickingAttachments = false
    @State private var pickingInboxAttachments = false
    @State private var inboxAttachmentSelection: [URL] = []
    @State private var staging = false
    @State private var plan = ReleasePublishPlan()
    @State private var retainedDraft: ManagedRelease?
    private var actionTitle: String { original != nil ? "保存" : (form.draft ? "保存草稿" : "发布") }
    init(api: GitHub, repo: String, original: ManagedRelease?, initialBranch: String = "", initialFiles: [URL] = [], allowsRepositorySelection: Bool = false) {
        self.initialFiles = initialFiles
        self.allowsRepositorySelection = allowsRepositorySelection
        _repositoryInput = State(initialValue: repo)
        self.initialBranch = initialBranch
        self.original = original
        _state = StateObject(wrappedValue: ReleaseScreenState(api: api, repo: repo))
        _form = State(initialValue: original.map { ReleaseForm($0) } ?? ReleaseForm())
        _markerReady = State(initialValue: original == nil)
    }
    var body: some View {
        AppNavigationStack {
            Form {
                Section {
                    SoftGroupRows(bottom: false) {
                        if original == nil && allowsRepositorySelection { repositorySection }
                        if !allowsRepositorySelection { SoftGroupRow("repository") { Text(state.repo) } }
                        SoftGroupRow("title") { TextField("标题", text: $form.title).accessibilityIdentifier("release-title") }
                        SoftGroupRow("tag") { TextField("标签（已有或新建）", text: $form.tag).textInputAutocapitalization(.never).accessibilityIdentifier("release-tag") }
                    }
                    if original == nil && !makeNewRepository { ReleaseBranchPicker(api: state.api, repo: state.repo, preferred: initialBranch, state: targetState, selected: $form.branch).disabled(state.busy || plan.draftID != nil) }
                    SoftGroupRows(top: false, bottom: !releaseHasStatus(state)) {
                        SoftGroupRow("body") { TextEditor(text: $form.body).frame(minHeight: 200).accessibilityIdentifier("release-body") }
                        SoftGroupRow("draft") { Toggle("保存为草稿", isOn: $form.draft)
                                .onChange(of: form.draft) { draft in if draft && form.marker == .latest { form.marker = .none } } }
                        SoftGroupRow("marker") { Picker("发行版标记", selection: $form.marker) {
                                Text("无").tag(ReleaseMarker.none)
                                Text("预发行版").tag(ReleaseMarker.prerelease)
                                if !form.draft { Text("最新发行版").tag(ReleaseMarker.latest) }
                        } }
                        if original == nil {
                            attachmentSection
                            if let id = plan.draftID { SoftGroupRow("retained-draft") { Text("已保留草稿 #\(id)，失败或取消不公开、不删除；可在此重试或从发行版详情继续。").font(.caption) } }
                            SoftGroupRow("publish-help") { Text("仅发布所选附件，不会编译、打包或提交本地源码。标签目标请明确选择远端分支或提交。").font(.caption) }
                        }
                        if !markerReady && !state.busy {
                            SoftGroupRow("retry-marker") { Button("重试读取发行版标记") { loadMarker() } }
                        }
                    }
                    releaseStatus(state)
                }
            }.disabled(!state.valid)
            .navigationTitle(original == nil ? "新建发行版" : "编辑发行版")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { targetState.cancel(); plan.cancel(); state.cancel(); dismiss() }.disabled(state.busy || staging)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) { confirm = true }.accessibilityIdentifier("release-publish")
                        .disabled(state.busy || staging || !state.valid)
                }
            }
            .interactiveDismissDisabled(state.busy)
            .task {
                loadMarker()
                if original == nil, !state.repo.isEmpty, !targetState.ready, !targetState.loading {
                    targetState.load(api: state.api, repo: state.repo, preferred: form.branch.isEmpty ? initialBranch : form.branch, selected: $form.branch)
                }
                if !initialFilesLoaded {
                    initialFilesLoaded = true
                    if !initialFiles.isEmpty { stage(.success(initialFiles), cleanupSelection: false) }
                }
            }
            .onChange(of: repositoryInput) { _ in invalidateRepository() }
            .onChange(of: makeNewRepository) { _ in invalidateRepository() }
            .onReceive(NotificationCenter.default.publisher(for: .githubAccountChanged)) { _ in targetState.cancel() }
            .onDisappear { targetState.cancel(); plan.cancel(); state.cancel(); if !staging { cleanupAttachments() } }
            .sheet(isPresented: $pickingInboxAttachments, onDismiss: {
                let files = inboxAttachmentSelection; inboxAttachmentSelection = []
                if !files.isEmpty { stage(.success(files)) }
            }) {
                ShareInboxView(multiple: true) { files in inboxAttachmentSelection = files; pickingInboxAttachments = false }
            }
            .fileImporter(isPresented: $pickingAttachments, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in stage(result) }
            .sheet(isPresented: $confirm) { confirmationPage }
        }
    }
    @SoftGroupRowsBuilder private var repositorySection: [SoftGroupRow] {
        SoftGroupRow("target-heading") { Text("目标仓库").font(.subheadline).foregroundStyle(.secondary) }
        SoftGroupRow("create-repository") { Toggle("新建仓库后发布", isOn: $makeNewRepository).disabled(state.busy || plan.draftID != nil || createdRepository) }
        if makeNewRepository {
            SoftGroupRow("new-repository-name") { TextField("新仓库名称", text: $newRepositoryName).textInputAutocapitalization(.never).autocorrectionDisabled() }
            SoftGroupRow("new-repository-private") { Toggle("私有仓库", isOn: $newRepositoryPrivate) }
            SoftGroupRow("new-repository-help") { Text("确认后才创建仓库；使用新仓库含 README 的默认分支。失败保留已创建仓库，不自动删除。").font(.caption) }
        } else {
            SoftGroupRow("target-repository") { TextField("仓库链接 / owner/repo", text: $repositoryInput).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(state.busy || plan.draftID != nil || createdRepository) }
            SoftGroupRow("load-target") { Button("读取目标分支") { reloadRepository() }.disabled(state.busy || repositoryInput.isEmpty || plan.draftID != nil) }
        }
    }
    private func invalidateRepository() {
        guard plan.draftID == nil, !createdRepository else { return }
        targetState.cancel(); reviewFingerprint = nil; reviewHead = ""; form.branch = ""
        state.repo = (try? RepositoryInput.parse(repositoryInput)) ?? ""
    }
    private func reloadRepository() {
        invalidateRepository()
        guard !state.repo.isEmpty else { return }
        targetState.load(api: state.api, repo: state.repo, preferred: "", selected: $form.branch)
    }
    private var confirmationPage: some View {
        AppNavigationStack {
            List {
                Section("最终预览") {
                    SoftGroupRows(bottom: false) {
                        SoftGroupRow("repository") { AppLabeledContent("仓库", value: makeNewRepository ? newRepositoryName + (newRepositoryPrivate ? "（新建私有）" : "（新建公开）") : state.repo) }
                        SoftGroupRow("tag") { AppLabeledContent("标签", value: form.tag) }
                        SoftGroupRow("target") { AppLabeledContent("目标", value: makeNewRepository ? "新仓库默认分支" : form.branch) }
                        if !reviewHead.isEmpty { SoftGroupRow("head") { Text("HEAD：" + reviewHead).font(.caption) } }
                        SoftGroupRow("title") { Text(form.title) }
                        SoftGroupRow("body") { Text(form.body) }
                        SoftGroupRow("visibility") { Text(form.draft ? "保存后仍为草稿" : "发布后按仓库权限可见") }
                        SoftGroupRow("marker") { Text("标记：" + form.marker.title) }
                        for item in attachments {
                            SoftGroupRow("attachment-" + item.id.uuidString) { Text(item.name + " · " + ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) }
                        }
                    }
                    releaseStatus(state, bottom: false)
                    SoftGroupRows(top: false) {
                        if preflighting { SoftGroupRow("preflighting") { ProgressView("正在检查权限与文件…") } }
                        if targetState.loading { SoftGroupRow("loading-target") { ProgressView("正在重新核验目标分支…") } }
                        if !makeNewRepository && original == nil && !targetState.error.isEmpty { SoftGroupRow("target-error") { Text(targetState.error).foregroundColor(.red) } }
                        SoftGroupRow("retry") { Button("检查并重试") { preflightRelease() }.disabled(state.busy || preflighting) }
                        SoftGroupRow("confirm") { Button(makeNewRepository ? "确认创建仓库并" + actionTitle : "确认保存") { performConfirmedRelease() }
                                .disabled(state.busy || preflighting || reviewFingerprint == nil || !state.valid) }
                    }
                }
            }.navigationTitle("确认发行版")
                .toolbar { Button("取消") { confirm = false; reviewFingerprint = nil }.disabled(state.busy || preflighting) }
                .interactiveDismissDisabled(state.busy || preflighting)
                .task { preflightRelease() }
                .onChange(of: targetState.ready) { ready in
                    if ready && confirm && reviewFingerprint == nil { preflightRelease() }
                }
        }
    }
    private func fingerprint() async throws -> String {
        try state.check()
        if !markerReady, let original {
            let latestID = try await state.api.managedLatestID(state.repo, refresh: true)
            try state.check()
            form.marker = ReleaseForm(original, latestID: latestID).marker
            form.initialLatestID = latestID; markerReady = true
        }
        guard markerReady, form.validMarker, ReleaseManagementRules.validTag(form.tag), ReleaseManagementRules.editable(form.body) else { throw AppError(text: "请检查标签、发布说明及发行标记。") }
        if makeNewRepository {
            let name = newRepositoryName
            guard !name.isEmpty, name != ".", name != "..", name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }) else { throw AppError(text: "请输入有效的新仓库名称。") }
        } else {
            let canonical = try RepositoryInput.parse(state.repo)
            try await state.api.requireWriteAccess(canonical)
            if let original {
                let current = try await state.api.managedRelease(canonical, id: original.id)
                guard current == original else { throw AppError(text: "发行版已变化，请关闭并刷新后重新确认。") }
            }
            if original == nil {
                guard targetReady, !form.branch.isEmpty else { throw AppError(text: "请在同一表单选择并核验目标分支或提交。") }
                if form.branch.count == 40 && form.branch.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
                    let commit = try await state.api.commitDetail(canonical, sha: form.branch, page: 1)
                    guard commit.sha.lowercased() == form.branch.lowercased() else { throw AppError(text: "提交目标已变化。") }
                    reviewHead = commit.sha
                } else {
                    reviewHead = try await state.api.workspaceHead(canonical, branch: form.branch)
                }
            }
        }
        if original == nil && attachments.isEmpty { throw AppError(text: "请明确选择至少一个附件。") }
        var fields = [state.repo, String(makeNewRepository), newRepositoryName, String(newRepositoryPrivate), form.title, form.tag, form.body, form.branch, String(form.draft), form.marker.rawValue, reviewHead]
        for item in attachments {
            let attrs = try FileManager.default.attributesOfItem(atPath: item.file.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.int64Value == item.size else { throw AppError(text: "附件已变化，请重新选择。") }
            let file = item.file
            fields += [item.id.uuidString, item.name, String(item.size), try await Task.detached { try LocalStore.snapshotFileSHA256(file) }.value]
        }
        try state.check()
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }
    private func preflightRelease() {
        guard !state.busy, !preflighting, state.valid else { return }
        if original == nil && !makeNewRepository && !targetReady {
            reviewFingerprint = nil
            guard !targetState.loading else { return }
            targetState.load(api: state.api, repo: state.repo,
                             preferred: form.branch.isEmpty ? initialBranch : form.branch, selected: $form.branch)
            return
        }
        preflighting = true; reviewFingerprint = nil
        state.run {
            defer { preflighting = false }
            reviewFingerprint = try await fingerprint()
        }
    }
    private func performConfirmedRelease() {
        guard let authorized = reviewFingerprint else { return }
        state.run {
            do {
                guard try await fingerprint() == authorized else { throw AppError(text: "目标或文件已变化，请重新检查并确认。") }
                reviewFingerprint = nil
                var captured = form
                if makeNewRepository {
                    let created = try await state.api.createRepository(name: newRepositoryName, isPrivate: newRepositoryPrivate)
                    // Retain an acknowledged repository even when a later step fails.
                    createdRepository = true
                    state.repo = created.full_name; repositoryInput = created.full_name; makeNewRepository = false
                    try state.check()
                    let resolved = try await state.api.resolvedBranch(state.repo, branch: "")
                    captured.branch = try await state.api.workspaceHead(state.repo, branch: resolved)
                    form.branch = captured.branch; targetState.ready = true
                } else if original == nil {
                    captured.branch = reviewHead
                }
                if let original {
                    let saved = try await state.api.saveManagedRelease(state.repo, original: original, form: captured)
                    try state.check()
                    ReleaseManagementChanges.changed(api: state.api, repo: state.repo, release: saved)
                } else {
                    try await publishAttachments(captured)
                    try state.check()
                    ReleaseManagementChanges.changed(api: state.api, repo: state.repo)
                }
                try state.check(); confirm = false; dismiss()
            } catch {
                reviewFingerprint = nil
                throw error
            }
        }
    }
    @SoftGroupRowsBuilder private var attachmentSection: [SoftGroupRow] {
        SoftGroupRow("attachments-heading") { Text("附件").font(.subheadline).foregroundStyle(.secondary) }
        SoftGroupRow("inbox-attachments") { Button("从待上传文件选择") { pickingInboxAttachments = true }.disabled(state.busy || staging || plan.draftID != nil) }
        SoftGroupRow("select-attachments") { Button("选择文件 / 追加附件") { pickingAttachments = true }.disabled(state.busy || staging || plan.draftID != nil) }
        for item in attachments {
            SoftGroupRow("attachment-" + item.id.uuidString) {
                VStack(alignment: .leading) {
                    Text(item.name)
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption)
                    if plan.uploaded[item.name] != nil { Text("已上传，重试时核验后跳过").font(.caption) }
                    Button("移除", role: .destructive) {
                        try? FileManager.default.removeItem(at: item.file.deletingLastPathComponent())
                        attachments.removeAll { $0.id == item.id }
                    }.disabled(state.busy || staging || plan.draftID != nil)
                }
            }
        }
        if attachments.isEmpty { SoftGroupRow("attachments-empty") { Text("请选择至少一个非空附件；每件小于 2 GiB，同名不覆盖。").font(.caption) } }
        if staging { SoftGroupRow("attachments-staging") { ProgressView("正在复制附件…") } }
    }
    private func cleanupAttachments() {
        for item in attachments { try? FileManager.default.removeItem(at: item.file.deletingLastPathComponent()) }
    }
    private func stage(_ result: Result<[URL], Error>, cleanupSelection: Bool = true) {
        guard !state.busy, !staging, state.valid else { return }
        switch result {
        case .failure(let error): if !RefreshFailure.isCancellation(error) { state.error = error.localizedDescription }
        case .success(let urls):
            staging = true
            state.run {
                defer { staging = false; if cleanupSelection { ShareSelectionCleanup.remove(urls) }; if Task.isCancelled || !state.valid { cleanupAttachments() } }
                for source in urls {
                    let item = try await Task.detached { try ReleaseAttachmentRules.copy(source) }.value
                    do {
                        try state.check()
                        guard ReleaseAttachmentRules.valid(size: item.size, name: item.name, existing: attachments.map(\.name)) else { throw AppError(text: "同名附件已选择，请先移除或改名。") }
                        attachments.append(item)
                    } catch { try? FileManager.default.removeItem(at: item.file.deletingLastPathComponent()); throw error }
                }
            }
        }
    }
    private func publishAttachments(_ captured: ReleaseForm) async throws {
        guard targetReady, !attachments.isEmpty, !captured.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError(text: "请添加附件并明确选择远端标签目标后发布。") }
        try state.check()
        plan.begin()
        do {
            if retainedDraft == nil {
                var draft = captured; draft.draft = true; draft.marker = .none
                let created = try await state.api.saveManagedRelease(state.repo, original: nil, form: draft)
                // Record acknowledged draft before cancellation check; never delete it.
                retainedDraft = created; plan.created(created.id)
            }
            try state.check()
            guard let retainedDraft, retainedDraft.tag_name == captured.tag else { throw AppError(text: "重试必须使用原草稿标签；请从发行版详情继续编辑。") }
            var current = try await state.api.managedRelease(state.repo, id: retainedDraft.id)
            guard current.draft else { throw AppError(text: "草稿已被外部公开，请刷新详情核实；未继续写入。") }
            var remote: [Asset] = []; var complete = false
            for page in 1...ReleaseManagementRules.pageLimit {
                let batch = try await state.api.managedAssets(state.repo, id: current.id, page: page)
                try state.check(); remote += batch
                if batch.count < ReleaseManagementRules.pageSize { complete = true; break }
            }
            guard complete else { throw AppError(text: "附件核验超过分页预算，请在 GitHub 继续。") }
            for item in attachments {
                try state.check()
                if let acknowledged = plan.uploaded[item.name] {
                    guard remote.contains(where: { $0.id == acknowledged.id && $0.name == item.name && Int64($0.size) == item.size }) else { throw AppError(text: "已上传附件身份或大小已变化，禁止覆盖。") }
                    continue
                }
                guard !remote.contains(where: { $0.name == item.name }) else { throw AppError(text: "远端存在未知同名附件，请从详情核实；不自动覆盖。") }
                current = try await state.api.managedRelease(state.repo, id: current.id)
                try state.check(); guard current.draft else { throw AppError(text: "发行版已不再是草稿，停止上传。") }
                let asset = try await state.api.uploadManagedAsset(state.repo, original: current, file: item.file) { progress in
                    Task { @MainActor in if state.valid && state.busy { state.progress = progress } }
                }
                guard asset.name == item.name && Int64(asset.size) == item.size else { throw AppError(text: "上传响应附件身份或大小不匹配，请核实草稿。") }
                plan.acknowledge(name: item.name, id: asset.id, size: item.size)
                try state.check()
            }
            try state.check()
            guard plan.mayFinalize(names: attachments.map(\.name)) else { throw CancellationError() }
            current = try await state.api.managedRelease(state.repo, id: current.id)
            try state.check(); guard current.draft else { throw AppError(text: "草稿状态已变化，请刷新核实。") }
            plan.finalizing()
            _ = try await state.api.saveManagedRelease(state.repo, original: current, form: captured)
            try state.check(); plan.finish()
        } catch {
            if RefreshFailure.isCancellation(error) || Task.isCancelled || !state.valid { plan.cancel() } else { plan.fail() }
            throw error
        }
    }
    private func loadMarker() {
        guard let original, !markerReady else { return }
        state.run {
            let latestID = try await state.api.managedLatestID(state.repo, refresh: true)
            try state.check()
            form.marker = ReleaseForm(original, latestID: latestID).marker
            form.initialLatestID = latestID
            markerReady = true
        }
    }
}

@MainActor private func releaseHasStatus(_ state: ReleaseScreenState) -> Bool {
    state.busy || !state.notice.isEmpty || !state.error.isEmpty || !state.valid
}
@MainActor @ViewBuilder private func releaseStatus(_ state: ReleaseScreenState, top: Bool = false, bottom: Bool = true) -> some View {
    SoftGroupRows(top: top, bottom: bottom) {
        if state.busy {
            SoftGroupRow("release-status-progress") { ProgressView(value: state.progress) }
            SoftGroupRow("release-status-help") { Text("请保持前台，勿锁屏。").font(.caption) }
            SoftGroupRow("release-status-cancel") { Button("取消当前操作") { state.cancel() } }
        }
        if !state.notice.isEmpty { SoftGroupRow("release-status-notice") { Text(state.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }
        if !state.error.isEmpty { SoftGroupRow("release-status-error") { Text(state.error).foregroundColor(.red).textSelection(.enabled) } }
        if !state.valid { SoftGroupRow("release-status-account") { Text("账号已切换，请重新打开此页面。") } }
    }
}
