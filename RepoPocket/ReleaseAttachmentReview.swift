import SwiftUI

/// Existing-release attachments use the same owned-copy and inline review rules
/// as a new release; an importer URL is never uploaded directly after an alert.
struct ReleaseAttachmentReview: View {
    @ObservedObject var api: GitHub
    let repo: String
    let original: ManagedRelease
    let source: URL
    let completed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var attachment: ReleaseAttachment?
    @State private var authorizedHash: String?
    @State private var busy = false
    @State private var error = ""
    @State private var progress: Double = 0
    private let generation = AccountStore.generation
    private var valid: Bool { generation == AccountStore.generation && api.isCurrentSession }

    var body: some View {
        AppNavigationStack {
            List {
                Section("最终附件预览") {
                    SoftGroupRows {
                        SoftGroupRow("release") { Text(repo + " · #\(original.id) · " + original.tag_name) }
                        SoftGroupRow("filename") { Text(source.lastPathComponent) }
                        if let attachment { SoftGroupRow("size") { Text(ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file)) } }
                        SoftGroupRow("help") { Text("单附件小于2 GiB；同名不覆盖。已公开发行版会立即受到影响。请保持前台。").font(.caption) }
                        if busy { SoftGroupRow("progress") { ProgressView(value: progress) } }
                        if !error.isEmpty { SoftGroupRow("error") { Text(error).foregroundColor(.red) } }
                        SoftGroupRow("retry") { Button("检查并重试") { Task { await check() } }.disabled(busy || !valid) }
                        SoftGroupRow("confirm") { Button("确认上传") { Task { await upload() } }
                                .disabled(busy || !valid || authorizedHash == nil) }
                    }
                }
            }.navigationTitle("确认上传附件")
                .toolbar { Button("取消") { dismiss() }.disabled(busy) }
                .interactiveDismissDisabled(busy)
                .task { await check() }
                .onDisappear {
                    if let attachment { try? FileManager.default.removeItem(at: attachment.file.deletingLastPathComponent()) }
                    ShareSelectionCleanup.remove([source])
                }
        }
    }
    private func verify(_ item: ReleaseAttachment) async throws -> String {
        try Task.checkCancellation()
        guard valid else { throw CancellationError() }
        try await api.requireWriteAccess(repo)
        let current = try await api.managedRelease(repo, id: original.id)
        guard current == original else { throw AppError(text: "发行版状态已变化，请关闭并刷新详情。") }
        var complete = false
        for page in 1...ReleaseManagementRules.pageLimit {
            let assets = try await api.managedAssets(repo, id: original.id, page: page)
            guard valid else { throw CancellationError() }
            guard !assets.contains(where: { $0.name == item.name }) else { throw AppError(text: "已有同名附件，未覆盖；请返回选择其他文件。") }
            if assets.count < ReleaseManagementRules.pageSize { complete = true; break }
        }
        guard complete else { throw AppError(text: "附件检查超过分页预算，请在 GitHub 核实。") }
        let file = item.file
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        guard size == item.size else { throw AppError(text: "附件文件已变化，请重新选择。") }
        let hash = try await Task.detached { try LocalStore.snapshotFileSHA256(file) }.value
        guard valid else { throw CancellationError() }
        return hash
    }
    private func check() async {
        guard !busy, valid else { return }
        busy = true; error = ""; authorizedHash = nil; defer { busy = false }
        do {
            if attachment == nil {
                let input = source
                let copy = try await Task.detached { try ReleaseAttachmentRules.copy(input) }.value
                guard valid, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: copy.file.deletingLastPathComponent())
                    throw CancellationError()
                }
                attachment = copy
            }
            if let attachment { authorizedHash = try await verify(attachment) }
        } catch { if valid && !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription } }
    }
    private func upload() async {
        guard !busy, valid, let attachment, let authorizedHash else { return }
        busy = true; error = ""; defer { busy = false }
        do {
            guard try await verify(attachment) == authorizedHash else { throw AppError(text: "附件内容已变化，请重新检查并确认。") }
            self.authorizedHash = nil
            _ = try await api.uploadManagedAsset(repo, original: original, file: attachment.file) { value in
                Task { @MainActor in if valid { progress = value } }
            }
            guard valid else { throw CancellationError() }
            completed(); dismiss()
        } catch {
            self.authorizedHash = nil
            if valid && !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription }
        }
    }
}
