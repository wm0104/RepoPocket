import SwiftUI
import QuickLook

struct DownloadCenterView: View {
    @ObservedObject var api: GitHub
    @ObservedObject var store: DownloadStore = .shared
    @State private var shared: SharedFile?
    @State private var preview: SharedFile?
    @State private var deleting: DownloadRecord?
    @State private var busyID: UUID?
    @State private var message = ""
    @State private var action: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    if store.records.isEmpty {
                        SoftGroupRow("empty") { Text("暂无下载。下载文件、发行版附件或构建产物后，会显示在这里。").foregroundStyle(.secondary) }
                    }
                    for record in store.records {
                        SoftGroupRow(record.id.uuidString) { row(record) }
                    }
                    if !store.error.isEmpty { SoftGroupRow("error") { Text(store.error).font(.caption).foregroundStyle(.red) } }
                }
            } footer: {
                Text("仅显示当前账号的下载。下载请保持前台；中断后可重试。切换或退出账号不会删除已完成文件。")
            }
        }
        .navigationTitle("下载中心")
        .listStyle(.insetGrouped)
        .sheet(item: $shared) { ShareSheet(url: $0.url).appSheetCornerRadius() }
        .sheet(item: $preview) { DownloadFilePreview(url: $0.url, onClose: { preview = nil }).appSheetCornerRadius() }
        .alert("下载中心", isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) {
            Button("好", role: .cancel) { message = "" }
        } message: { Text(message) }
        .confirmationDialog(deleting?.state == .completed ? "删除下载文件？" : "删除下载记录？",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("确认删除", role: .destructive) {
                if let record = deleting, api.isCurrentSession {
                    do { try store.delete(record) } catch { message = error.localizedDescription }
                }
                deleting = nil
            }
        } message: { Text("仅删除这份下载文件和记录，不影响待上传、已分享或导出的副本。") }
        .onReceive(NotificationCenter.default.publisher(for: .githubAccountChanged)) { _ in
            action?.cancel(); action = nil; busyID = nil
            shared = nil; preview = nil; deleting = nil; message = ""
        }
    }

    private func row(_ record: DownloadRecord) -> some View {
        let size = record.state == .completed ? record.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: record.state == .completed ? "doc" : "arrow.down.circle")
                    .foregroundStyle(.tint).frame(width: 24).accessibilityHidden(true)
                Button {
                    guard record.state == .completed else { return }
                    do { preview = SharedFile(url: try store.file(record)) } catch { message = error.localizedDescription }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(record.fileName ?? record.source.name).foregroundStyle(.primary).lineLimit(2).layoutPriority(1)
                            if let size {
                                Spacer(minLength: 0)
                                Text(size).font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: true, vertical: false).accessibilityHidden(true)
                            }
                        }
                        if record.state != .completed {
                            Text(record.source.repository).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(record.title).font(.caption).foregroundStyle(record.state == .failed ? Color.red : Color.secondary)
                        }
                    }.frame(minHeight: 44).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(record.state != .completed || busyID != nil)
                if record.state == .connecting || record.state == .downloading {
                    Button { store.cancel(record) } label: { Image(systemName: "xmark.circle").frame(width: 44, height: 44) }
                        .buttonStyle(.borderless).accessibilityLabel("取消下载")
                } else if record.retryable {
                    Button("重试") { Task { do { try await store.retry(record, api: api) } catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { message = error.localizedDescription } } } }
                        .buttonStyle(.borderless).frame(minHeight: 44)
                } else if record.active || busyID == record.id { ProgressView() }
            }
            if record.state == .downloading {
                let progress = ReleaseDownloadProgress(received: record.received, total: record.total ?? -1)
                if let fraction = progress.fraction { ProgressView(value: fraction) }
                else { ProgressView() }
                Text(progress.label).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            if record.state != .completed, !record.message.isEmpty { Text(record.message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, record.state == .completed ? 0 : 4)
        .listRowInsets(record.state == .completed ? EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20) : nil)
        .contextMenu {
            if record.state == .completed {
                Button { do { shared = SharedFile(url: try store.file(record)) } catch { message = error.localizedDescription } } label: { Label("分享", systemImage: "square.and.arrow.up") }
                Button {
                    perform(record) { file in
                        let worker = Task.detached(priority: .utility) { try ShareInboxStore.live().importFile(file, cancelled: { Task.isCancelled }) }
                        _ = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                        try Task.checkCancellation()
                        if api.isCurrentSession {
                            NotificationCenter.default.post(name: .externalInboxChanged, object: nil)
                            message = "已加入待上传文件；上传时仍需选择仓库和目标位置。"
                        }
                    }
                } label: { Label("加入待上传文件", systemImage: "tray.and.arrow.up") }
            }
            if !record.active { Button(record.state == .completed ? "删除文件" : "删除记录", role: .destructive) { deleting = record } }
        }
        .disabled(!api.isCurrentSession || busyID != nil)
        .accessibilityIdentifier("download-record-" + record.id.uuidString)
        .accessibilityValue(size.map { record.title + "，" + $0 } ?? record.title)
    }

    private func perform(_ record: DownloadRecord, work: @escaping (URL) async throws -> Void) {
        guard busyID == nil, api.isCurrentSession else { return }
        let generation = AccountStore.generation
        busyID = record.id
        action = Task {
            defer { if generation == AccountStore.generation { busyID = nil; action = nil } }
            do {
                let file = try store.file(record)
                try await work(file)
            } catch { if generation == AccountStore.generation, !RefreshFailure.isCancellation(error) { message = error.localizedDescription } }
        }
    }
}

private struct DownloadFilePreview: UIViewControllerRepresentable {
    let url: URL
    let onClose: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(url, onClose: onClose) }
    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        let done = UIBarButtonItem(barButtonSystemItem: .done, target: context.coordinator, action: #selector(Coordinator.close))
        done.accessibilityIdentifier = "download-preview-done"
        controller.navigationItem.leftBarButtonItem = done
        return UINavigationController(rootViewController: controller)
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let url: URL
        let onClose: () -> Void
        init(_ url: URL, onClose: @escaping () -> Void) { self.url = url; self.onClose = onClose }
        @objc func close() { onClose() }
        func previewControllerDidDismiss(_ controller: QLPreviewController) { onClose() }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
