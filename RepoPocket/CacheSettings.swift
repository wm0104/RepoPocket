import SwiftUI

struct CacheSettingsSection: View {
    @ObservedObject var api: GitHub
    @ObservedObject var checker: UpdateChecker
    @ObservedObject private var downloads = DownloadStore.shared
    @State private var confirm = false
    @State private var clearing = false
    @State private var message = ""
    private var blocked: Bool { clearing || checker.checking || checker.downloading || downloads.operations > 0 }
    var body: some View {
        Section {
            Button("清除缓存") { confirm = true }.disabled(blocked).softGroupedRow(top: true, bottom: message.isEmpty)
            if !message.isEmpty { Text(message).font(.caption).softGroupedRow(bottom: true) }
        }.confirmationDialog("清除 App 缓存？", isPresented: $confirm, titleVisibility: .visible) {
            Button("清除缓存", role: .destructive) {
                guard !blocked else { return }
                clearing = true
                Task { @MainActor in
                    defer { clearing = false }
                    do {
                        guard try await AvatarPipeline.shared.clearIfIdle() else { throw AppError(text: "头像正在加载，请稍后重试。") }
                        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        try CacheRules.clear(root: root, busy: checker.checking || checker.downloading || downloads.operations > 0) { try FileManager.default.removeItem(at: $0) }
                        URLCache.shared.removeAllCachedResponses()
                        api.clearMemoryCaches()
                        message = "已清除缓存；工作区、草稿、账号和下载文件均保留。"
                    } catch { message = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("仅清除 App 专属缓存和头像缓存，不删除工作区、草稿、钥匙串或下载文件。") }
    }
}
