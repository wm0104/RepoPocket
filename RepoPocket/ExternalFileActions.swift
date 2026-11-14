import SwiftUI

extension Notification.Name {
    static let externalInboxChanged = Notification.Name("RepoPocket.externalInboxChanged")
}

/// The caller retains its source; each destination makes its own private copy.
/// Cancelling a route never consumes an inbox item or the generated deb.
struct ExternalFileActions: View {
    @ObservedObject var api: GitHub
    let file: URL
    var repo = ""
    var branch = ""
    var allowsDebEditing = false
    @State private var route: Route?
    private enum Route: String, Identifiable {
        case repository, release, share, editor
        var id: String { rawValue }
    }
    var body: some View {
        NativeActionMenu(title: "文件用途：" + file.lastPathComponent, symbol: nil,
                         accessibilityIdentifier: "external-file-actions", items: [
            NativeMenuItem(id: "repository", title: "提交到仓库", symbol: "arrow.up.doc", perform: { route = .repository }),
            NativeMenuItem(id: "release", title: "作为发行附件", symbol: "paperclip", perform: { route = .release }),
            NativeMenuItem(id: "share", title: "存储 / 分享", symbol: "square.and.arrow.up", perform: { route = .share })
        ] + (allowsDebEditing && file.pathExtension.lowercased() == "deb" ? [
            NativeMenuItem(id: "editor", title: "编辑包信息（导出副本）", symbol: "shippingbox", perform: { route = .editor })
        ] : []))
        .sheet(item: $route) { route in
            switch route {
            case .repository:
                UploadView(api: api, initialRepo: repo, initialBranch: branch, initialFile: file)
            case .release:
                ReleaseEntryView(api: api, initialRepo: repo, initialBranch: branch, initialFiles: [file])
            case .share:
                ShareSheet(url: file)
            case .editor:
                DebEditorView(api: api, initialFile: file)
            }
        }
    }
}

/// Contextual inbox rows only exist when there are real share-in files.
/// The durable inbox owns them before a route is chosen and after cancellation.
struct ExternalInboxSection: View {
    @ObservedObject var api: GitHub
    @State private var files: [URL] = []
    @State private var loading = false
    var body: some View {
        Group {
            if !files.isEmpty {
                Section("外部文件") {
                    ForEach(files, id: \.self) { file in
                        ExternalFileActions(api: api, file: file, allowsDebEditing: true)
                            .softGroupedRow(top: file == files.first, bottom: file == files.last)
                    }
                }
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .externalInboxChanged)) { _ in Task { await load() } }
    }
    private func load() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            files = try await Task.detached {
                let inbox = try ShareInboxStore.live()
                return try inbox.items().map { try inbox.file($0) }
            }.value
        } catch { files = [] } // An unavailable app group must not create an empty tools home.
    }
}
