import SwiftUI

struct CacheSettingsSection: View {
    @ObservedObject var api: GitHub
    @ObservedObject var checker: UpdateChecker
    @ObservedObject private var downloads = DownloadStore.shared
    @State private var confirm = false
    @State private var clearing = false
    @State private var message = ""
    @State private var noticeTask: Task<Void, Never>?
    private var blocked: Bool { clearing || checker.checking || checker.downloading || downloads.operations > 0 }
    var body: some View {
        Section("存储") {
            Button("清除缓存") { confirm = true }.disabled(blocked).softGroupedRow(top: true, bottom: message.isEmpty)
            if !message.isEmpty { Text(message).font(.caption).softGroupedRow(bottom: true) }
        }
        .onDisappear { noticeTask?.cancel(); noticeTask = nil }
        .confirmationDialog("清除 App 缓存？", isPresented: $confirm, titleVisibility: .visible) {
            Button("清除缓存", role: .destructive) {
                guard !blocked else { return }
                clearing = true
                let before = Self.usedBytes()
                Task { @MainActor in
                    defer { clearing = false }
                    do {
                        guard try await AvatarPipeline.shared.clearIfIdle() else { throw AppError(text: "头像正在加载，请稍后重试。") }
                        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        try CacheRules.clear(root: root, busy: checker.checking || checker.downloading || downloads.operations > 0) { try FileManager.default.removeItem(at: $0) }
                        URLCache.shared.removeAllCachedResponses()
                        api.clearMemoryCaches()
                        show(before > 0
                            ? "已清除 " + ByteCountFormatter.string(fromByteCount: before, countStyle: .file) + " 缓存；工作区、草稿、账号和下载文件均保留。"
                            : "已清除缓存；工作区、草稿、账号和下载文件均保留。")
                    } catch { show("清除失败：" + error.localizedDescription) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("仅清除 App 专属缓存和头像缓存，不删除工作区、草稿、钥匙串或下载文件。") }
    }
    /// One short-lived notice; it clears itself so the page never keeps stale text.
    private func show(_ text: String) {
        noticeTask?.cancel()
        message = text
        noticeTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            message = ""
            noticeTask = nil
        }
    }
    /// Bytes held by the two dedicated cache folders plus the shared URL cache.
    private static func usedBytes() -> Int64 {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folders = ["RepoPocketCache", "RepoPocketAvatars"].map { root.appendingPathComponent($0, isDirectory: true) }
        var total = folders.reduce(Int64(0)) { $0 + CacheRules.directorySize($1) }
        total += Int64(URLCache.shared.currentDiskUsage)
        return max(0, total)
    }
}
