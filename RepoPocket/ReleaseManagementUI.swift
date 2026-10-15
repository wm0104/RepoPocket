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
    let repo: String
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
    private var page = 1
    private var assetPage = 1
    private var task: Task<Void, Never>?
    private var operation = UUID()
    private var accountObserver: AnyCancellable?
    init(api: GitHub, repo: String) {
        self.api = api; self.repo = repo
        accountObserver = NotificationCenter.default.publisher(for: .githubAccountChanged).sink { [weak self] _ in
            self?.cancel(); self?.canWrite = false; self?.rows = []; self?.assets = []; self?.release = nil; self?.notice = ""; self?.latestID = nil
        }
    }
    var valid: Bool { generation == AccountStore.generation && api.isCurrentSession }
    func cancel() { operation = UUID(); task?.cancel(); task = nil; busy = false }
    func run(_ work: @escaping () async throws -> Void) {
        guard valid, !busy else { return }
        busy = true; error = ""; notice = ""; progress = 0
        let token = UUID(); operation = token
        task = Task {
            defer { if operation == token { busy = false; task = nil } }
            do { try await work() }
            catch { if valid && operation == token && !RefreshFailure.isCancellation(error) && !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func check() throws { try Task.checkCancellation(); guard valid else { throw CancellationError() } }
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
            if reset { self.page = 1; self.rows = []; try await self.access() }
            let p = self.page
            let batch = try await self.api.managedReleases(self.repo, page: p); try self.check()
            self.rows = ReleaseManagementRules.merged(self.rows, batch)
            self.listLoaded = true
            self.more = ReleaseManagementRules.more(count: batch.count, page: p); self.page = p + 1
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
        run {
            try await DownloadStore.shared.requireAuthorization(); try self.check()
            DownloadStore.shared.begin(); defer { DownloadStore.shared.end() }
            let temporary = try await self.api.downloadManagedAsset(self.repo, asset: asset) { p in
                Task { @MainActor in if self.valid && self.busy { self.progress = p } }
            }
            defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
            try self.check()
            _ = try await DownloadStore.shared.persist(temporary, session: self.generation)
            try self.check(); self.notice = "已下载并保存到 " + DownloadStore.shared.label
        }
    }
}

struct ReleaseListView: View {
    @StateObject private var state: ReleaseScreenState
    @State private var creating = false
    init(api: GitHub, repo: String) { _state = StateObject(wrappedValue: ReleaseScreenState(api: api, repo: repo)) }
    var body: some View {
        List {
            Section {
                Text(state.repo).font(.caption)
                    .softGroupedRow(top: true, bottom: true)
            }
            Section {
                ForEach(state.rows) { row in
                    NavigationLink { ReleaseManagementDestination(api: state.api, repo: state.repo, id: row.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.title).lineLimit(2)
                            Text(row.tag_name + " · " + String(row.date.prefix(10))).font(.caption)
                            if row.draft { Text("草稿").font(.caption) }
                            if row.prerelease { Text("预发行").font(.caption) }
                            if state.latestID == row.id && !row.draft && !row.prerelease { Text("最新发行版").font(.caption) }
                        }
                        .padding(.vertical, 7)
                    }
                    .softGroupedRow(top: row.id == state.rows.first?.id,
                                    bottom: row.id == state.rows.last?.id && !state.more)
                }
                if state.rows.isEmpty && !state.busy {
                    Text(state.listLoaded && state.error.isEmpty ? "暂无发行版" : "尚未成功加载发行版，可手动刷新。")
                        .softGroupedRow(top: true, bottom: !state.more)
                }
                if state.more {
                    Button("加载下一页") { state.list(reset: false) }.disabled(state.busy)
                        .softGroupedRow(top: state.rows.isEmpty && state.busy, bottom: true)
                }
            }
            if state.canWrite {
                Section {
                    Button("新建发行版") { creating = true }.disabled(state.busy)
                        .softGroupedRow(top: true, bottom: true)
                }
            }
            Section {
                releaseStatus(state)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("发行版")
        .toolbar { Button("刷新") { state.list(reset: true) }.disabled(state.busy) }
        .task { if state.rows.isEmpty { state.list(reset: true) } }
        .onDisappear { state.cancel() }
        .sheet(isPresented: $creating, onDismiss: { state.list(reset: true) }) {
            ReleaseEditorView(api: state.api, repo: state.repo, original: nil)
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
    @State private var uploading: URL?
    @State private var deleteTarget: ReleaseDeleteTarget?
    @State private var secondDelete = false
    @State private var confirmation = ""
    @State private var copied = false
    init(api: GitHub, repo: String, id: Int) {
        self.id = id; _state = StateObject(wrappedValue: ReleaseScreenState(api: api, repo: repo))
    }
    var body: some View {
        List {
            if let r = state.release {
                Section {
                    Text(r.title).softGroupedRow(top: true); Text(r.tag_name + " · " + String(r.date.prefix(10))).font(.caption).softGroupedRow()
                    Text(r.draft ? "草稿" : (r.prerelease ? "预发行" : "已发布")).softGroupedRow()
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
                    }.softGroupedRow(bottom: true)
                }
                Section {
                    ForEach(state.assets) { asset in
                        let link = ReleaseManagementRules.browserDownloadURL(asset.browser_download_url, repo: state.repo)
                        let isLastAsset = asset.id == state.assets.last?.id && !state.assetMore
                        VStack(alignment: .leading, spacing: 12) {
                            Text(asset.name).lineLimit(2)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(asset.size), countStyle: .file)).font(.caption)
                        }.softGroupedRow(top: asset.id == state.assets.first?.id)
                        // Each action is a native List row, with the same full-width separator.
                        // Explicit borderless buttons also keep List activation independent.
                        Button { state.download(asset) } label: {
                            Text("下载并保存")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(state.busy)
                        .softGroupedRow(bottom: isLastAsset && link == nil && !state.canWrite)
                        if let link = link {
                            Button { UIPasteboard.general.url = link; copied = true } label: {
                                Text("复制下载链接")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .softGroupedRow(bottom: isLastAsset && !state.canWrite)
                        }
                        if state.canWrite {
                            Button(role: .destructive) { prepareDelete(r, asset: asset) } label: {
                                Text("删除附件")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .disabled(state.busy)
                            .softGroupedRow(bottom: isLastAsset)
                        }
                    }
                    if state.assets.isEmpty && !state.assetMore { Text("暂无附件").softGroupedRow(top: true, bottom: true) }
                    if state.assetMore { Button("加载更多附件") { state.run { try await state.nextAssets(id) } }.disabled(state.busy).softGroupedRow(top: state.assets.isEmpty, bottom: true) }
                } header: {
                    Text("附件")
                } footer: {
                    Text("私有附件需在浏览器登录。")
                }
                if state.canWrite {
                    Section("管理") {
                        Button("编辑发行版") { editing = true }.disabled(state.busy || !ReleaseManagementRules.editable(r.body ?? "")).softGroupedRow(top: true)
                        if !ReleaseManagementRules.editable(r.body ?? "") { Text("正文超过128 KiB，禁止本地编辑，避免截断保存；请在 GitHub 编辑。").softGroupedRow() }
                        if r.draft { Button("发布草稿（在编辑表单确认）") { editing = true }.disabled(state.busy).softGroupedRow() }
                        Button("上传附件") { picking = true }.disabled(state.busy).softGroupedRow()
                        Button("从待上传文件选择") { pickingInbox = true }.disabled(state.busy).softGroupedRow()
                        Button("删除发行版（不删除 git 标签）", role: .destructive) { prepareDelete(r, asset: nil) }.disabled(state.busy).softGroupedRow(bottom: true)
                    }
                }
            }
            Section { releaseStatus(state) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("发行版详情")
        .alert("下载链接已复制", isPresented: $copied) { Button("好", role: .cancel) {} }
        .toolbar { Button("刷新") { state.detail(id) }.disabled(state.busy) }
        .task { if state.release == nil { state.detail(id) } }
        .onDisappear { state.cancel() }
        .sheet(isPresented: $editing, onDismiss: { state.detail(id) }) {
            if let r = state.release { ReleaseEditorView(api: state.api, repo: state.repo, original: r) }
        }
        .sheet(isPresented: $pickingInbox) {
            ShareInboxView(multiple: false) { files in
                pickingInbox = false
                uploading = files.first
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let file): uploading = file
            case .failure(let error): if !RefreshFailure.isCancellation(error) { state.error = error.localizedDescription }
            }
        }
        .alert("确认上传附件", isPresented: Binding(get: { uploading != nil }, set: { if !$0 { uploading = nil } })) {
            Button("取消", role: .cancel) { if let file = uploading { ShareSelectionCleanup.remove([file]) }; uploading = nil }
            Button("确认上传") { if let file = uploading, let r = state.release { upload(file, to: r) }; uploading = nil }
        } message: {
            Text("目标：\(state.repo) #\(id)\n附件：\(uploading?.lastPathComponent ?? "")\n单附件小于2 GiB；同名不覆盖。已公开发行版会立即受到影响。请保持前台。")
        }
        .alert("第一次确认删除", isPresented: Binding(get: { deleteTarget != nil && !secondDelete }, set: { _ in })) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("继续", role: .destructive) { confirmation = ""; secondDelete = true }
        } message: { Text(deleteDescription) }
        .sheet(isPresented: $secondDelete, onDismiss: { deleteTarget = nil }) {
            NavigationStack {
                Form {
                    Text(deleteDescription).softGroupedRow(top: true)
                    Text("第二次确认：输入 delete 确认删除。固定仓库/发行版/附件 ID，切换账号后禁止执行。删除发行版不会删除 git 标签。").softGroupedRow()
                    TextField("输入 delete 确认删除", text: $confirmation).textInputAutocapitalization(.never).softGroupedRow()
                    Button("永久删除", role: .destructive) { performDelete() }.disabled(confirmation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "delete").softGroupedRow(bottom: true)
                }.navigationTitle("最终确认").toolbar { Button("取消") { secondDelete = false } }
            }
        }
    }
    private var deleteDescription: String {
        guard let target = deleteTarget else { return "" }
        return "\(target.repo) · Release #\(target.release.id) · \(target.release.tag_name)\n" + (target.asset.map { "附件 #\($0.id) · \($0.name)" } ?? "整个发行版及附件；不删 git 标签")
    }
    private func prepareDelete(_ r: ManagedRelease, asset: Asset?) {
        deleteTarget = ReleaseDeleteTarget(repo: state.repo, generation: state.generation, release: r, asset: asset)
    }
    private func performDelete() {
        guard let target = deleteTarget, confirmation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "delete", target.repo == state.repo, target.generation == AccountStore.generation else { secondDelete = false; return }
        secondDelete = false
        state.run {
            try await state.api.deleteManagedRelease(target.repo, original: target.release, asset: target.asset)
            try state.check()
            ReleaseManagementChanges.changed(api: state.api, repo: target.repo)
            if target.asset == nil { dismiss() } else { try await state.reload(id) }
        }
    }
    private func upload(_ file: URL, to r: ManagedRelease) {
        state.run {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() }; ShareSelectionCleanup.remove([file]) }
            guard FileManager.default.isReadableFile(atPath: file.path) else { throw AppError(text: "文件未授权，请重选。") }
            _ = try await state.api.uploadManagedAsset(state.repo, original: r, file: file) { p in
                Task { @MainActor in if state.valid && state.busy { state.progress = p } }
            }
            try state.check(); try await state.reload(id)
        }
    }
}

struct ReleaseEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state: ReleaseScreenState
    let original: ManagedRelease?
    @State private var form: ReleaseForm
    @State private var confirm = false
    @State private var targetReady = false
    let initialBranch: String
    @State private var markerReady = false
    @State private var attachments: [ReleaseAttachment] = []
    @State private var pickingAttachments = false
    @State private var pickingInboxAttachments = false
    @State private var staging = false
    @State private var plan = ReleasePublishPlan()
    @State private var retainedDraft: ManagedRelease?
    private var actionTitle: String { original != nil ? "保存" : (form.draft ? "保存草稿" : "发布") }
    init(api: GitHub, repo: String, original: ManagedRelease?, initialBranch: String = "") {
        self.initialBranch = initialBranch
        self.original = original
        _state = StateObject(wrappedValue: ReleaseScreenState(api: api, repo: repo))
        _form = State(initialValue: original.map { ReleaseForm($0) } ?? ReleaseForm())
        _markerReady = State(initialValue: original == nil)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(state.repo).softGroupedRow(top: true)
                    TextField("标题", text: $form.title).softGroupedRow()
                    TextField("标签（已有或新建）", text: $form.tag).textInputAutocapitalization(.never).softGroupedRow(bottom: true)
                }
                if original == nil { ReleaseBranchPicker(api: state.api, repo: state.repo, preferred: initialBranch, selected: $form.branch, ready: $targetReady).disabled(state.busy || plan.draftID != nil) }
                Section {
                TextEditor(text: $form.body).frame(minHeight: 200).softGroupedRow(top: true)
                Toggle("保存为草稿", isOn: $form.draft)
                    .onChange(of: form.draft) { draft in if draft && form.marker == .latest { form.marker = .none } }.softGroupedRow()
                Picker("发行版标记", selection: $form.marker) {
                    Text("无").tag(ReleaseMarker.none)
                    Text("预发行版").tag(ReleaseMarker.prerelease)
                    if !form.draft { Text("最新发行版").tag(ReleaseMarker.latest) }
                }.softGroupedRow(bottom: true)
                }
                if original == nil {
                    attachmentSection
                    Section {
                        if let id = plan.draftID { Text("已保留草稿 #\(id)，失败或取消不公开、不删除；可在此重试或从发行版详情继续。").font(.caption).softGroupedRow(top: true) }
                        Text("仅发布所选附件，不会编译、打包或提交本地源码。标签目标请明确选择远端分支或提交。").font(.caption).softGroupedRow(top: plan.draftID == nil, bottom: true)
                    }
                }
                Section {
                Button(actionTitle) { confirm = true }
                    .disabled(state.busy || staging || !markerReady || !form.validMarker || !ReleaseManagementRules.editable(form.body) || (original == nil && (attachments.isEmpty || !targetReady || form.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))).softGroupedRow(top: true, bottom: markerReady || state.busy)
                if !markerReady && !state.busy { Button("重试读取发行版标记") { loadMarker() }.softGroupedRow(bottom: true) }
                }
                Section { releaseStatus(state) }
            }.disabled(!state.valid)
            .navigationTitle(original == nil ? "新建发行版" : "编辑发行版")
            .toolbar { Button("关闭") { plan.cancel(); state.cancel(); dismiss() } }
            .interactiveDismissDisabled(state.busy)
            .task { loadMarker() }
            .onDisappear { plan.cancel(); state.cancel(); if !staging { cleanupAttachments() } }
            .sheet(isPresented: $pickingInboxAttachments) {
                ShareInboxView(multiple: true) { files in pickingInboxAttachments = false; stage(.success(files)) }
            }
            .fileImporter(isPresented: $pickingAttachments, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in stage(result) }
            .alert(form.draft ? "保存草稿？" : "发布此发行版？", isPresented: $confirm) {
                Button("取消", role: .cancel) {}
                Button("确认保存") {
                    let captured = form
                    state.run {
                        if let original {
                            _ = try await state.api.saveManagedRelease(state.repo, original: original, form: captured)
                        } else { try await publishAttachments(captured) }
                        try state.check()
                        ReleaseManagementChanges.changed(api: state.api, repo: state.repo)
                        dismiss()
                    }
                }
            } message: { Text("\(state.repo) · \(form.tag)\n目标：\(form.branch)\n\(form.draft ? "保存后仍为草稿。" : "发布后可见（按仓库权限）。")") }
        }
    }
    private var attachmentSection: some View {
        Section("附件") {
            Button("从待上传文件选择") { pickingInboxAttachments = true }.disabled(state.busy || staging || plan.draftID != nil).softGroupedRow(top: true)
            Button("选择文件 / 追加附件") { pickingAttachments = true }.disabled(state.busy || staging || plan.draftID != nil).softGroupedRow()
            ForEach(attachments) { item in
                VStack(alignment: .leading) {
                    Text(item.name)
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption)
                    if plan.uploaded[item.name] != nil { Text("已上传，重试时核验后跳过").font(.caption) }
                    Button("移除", role: .destructive) {
                        try? FileManager.default.removeItem(at: item.file.deletingLastPathComponent())
                        attachments.removeAll { $0.id == item.id }
                    }.disabled(state.busy || staging || plan.draftID != nil)
                }.softGroupedRow(bottom: item.id == attachments.last?.id && !staging)
            }
            if attachments.isEmpty { Text("请选择至少一个非空附件；每件小于 2 GiB，同名不覆盖。").font(.caption).softGroupedRow(bottom: !staging) }
            if staging { ProgressView("正在复制附件…").softGroupedRow(bottom: true) }
        }
    }
    private func cleanupAttachments() {
        for item in attachments { try? FileManager.default.removeItem(at: item.file.deletingLastPathComponent()) }
    }
    private func stage(_ result: Result<[URL], Error>) {
        guard !state.busy, !staging, state.valid else { return }
        switch result {
        case .failure(let error): if !RefreshFailure.isCancellation(error) { state.error = error.localizedDescription }
        case .success(let urls):
            staging = true
            state.run {
                defer { staging = false; ShareSelectionCleanup.remove(urls); if Task.isCancelled || !state.valid { cleanupAttachments() } }
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

@MainActor @ViewBuilder private func releaseStatus(_ state: ReleaseScreenState) -> some View {
    if state.busy {
        ProgressView(value: state.progress).softGroupedRow(top: true)
        Text("请保持前台，勿锁屏。").font(.caption).softGroupedRow()
        Button("取消当前操作") { state.cancel() }.softGroupedRow(bottom: state.error.isEmpty && state.valid)
    }
    if !state.notice.isEmpty { Text(state.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).softGroupedRow(top: !state.busy && state.error.isEmpty, bottom: state.valid) }
    if !state.error.isEmpty { Text(state.error).foregroundColor(.red).textSelection(.enabled).softGroupedRow(top: !state.busy && state.notice.isEmpty, bottom: state.valid) }
    if !state.valid { Text("账号已切换，请重新打开此页面。").softGroupedRow(top: !state.busy && state.error.isEmpty, bottom: true) }
}
