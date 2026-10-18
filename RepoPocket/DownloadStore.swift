import SwiftUI
import Foundation

@MainActor final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()
    private let bookmarkKey = "RepoPocket.download.folder.v1"
    @Published var picker: WorkspaceImportRequest?
    @Published private(set) var label: String
    @Published private(set) var operations = 0
    private var waiters: [CheckedContinuation<Void, Error>] = []
    init() {
        let defaults = UserDefaults.standard
        let cached = defaults.string(forKey: "RepoPocket.download.label.v1")
        label = DownloadRules.initialLabel(cached, hasBookmark: defaults.data(forKey: bookmarkKey) != nil)
        if cached?.hasPrefix("/") != true { defaults.removeObject(forKey: "RepoPocket.download.label.v1") }
    }
    private func resolve() throws -> URL {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { throw AppError(text: "请选择保存位置；建议选择“我的 iPhone → 下载”。") }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { throw AppError(text: "下载位置授权失效，请重新选择文件夹。") }
        defer { url.stopAccessingSecurityScopedResource() }
        try DownloadRules.rejectSymlinks(url)
        label = DownloadRules.destinationFolder(in: url).path
        UserDefaults.standard.set(label, forKey: "RepoPocket.download.label.v1")
        if stale { UserDefaults.standard.set(try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: bookmarkKey) }
        return url
    }
    func choose() { guard operations == 0 else { return }; picker = WorkspaceImportRequest(kind: .folder) }
    func requireAuthorization() async throws {
        if (try? resolve()) != nil { return }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
            if picker == nil { picker = WorkspaceImportRequest(kind: .folder) }
        }
        try Task.checkCancellation()
    }
    func selected(_ urls: [URL]?) {
        picker = nil
        let result: Result<Void, Error>
        do {
            guard let url = urls?.first else { throw CancellationError() }
            guard url.startAccessingSecurityScopedResource() else { throw AppError(text: "文件夹未授权，请重选。") }
            defer { url.stopAccessingSecurityScopedResource() }
            try DownloadRules.rejectSymlinks(url)
            let data = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            label = DownloadRules.destinationFolder(in: url).path
            UserDefaults.standard.set(label, forKey: "RepoPocket.download.label.v1")
            result = .success(())
        } catch { result = .failure(error) }
        let waiting = waiters; waiters = []
        for waiter in waiting { waiter.resume(with: result) }
    }
    func begin() { operations += 1 }
    func end() { operations = max(0, operations - 1) }
    func persist(_ temporary: URL, session: UUID) async throws -> URL {
        guard session == AccountStore.generation else { throw CancellationError() }
        let parent: URL
        do { parent = try resolve() }
        catch { label = "授权失效，请重新选择保存位置"; throw AppError(text: "保存位置不可用，请在设置重新选择下载位置。") }
        guard parent.startAccessingSecurityScopedResource() else { throw AppError(text: "请重新授权下载位置。") }
        defer { parent.stopAccessingSecurityScopedResource() }
        let worker = Task.detached(priority: .utility) { () throws -> URL in
            try Task.checkCancellation()
            guard session == AccountStore.generation else { throw CancellationError() }
            let sourceBytes = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
            if let available = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               available < sourceBytes { throw AppError(text: "保存位置空间不足，请释放空间或选择其他文件夹。") }
            var coordinationError: NSError?
            var result: Result<URL, Error>?
            NSFileCoordinator().coordinate(writingItemAt: parent, options: [], error: &coordinationError) { coordinated in
                result = Result {
                    try DownloadRules.save(temporary, parent: coordinated,
                        valid: { session == AccountStore.generation && !Task.isCancelled },
                        fingerprint: LocalStore.snapshotFileSHA256)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw AppError(text: "文件提供器未完成保存，请重试。") }
            return try result.get()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
    func shareScope(for url: URL) -> URL? {
        guard let parent = try? resolve(), url.standardizedFileURL.path.hasPrefix(DownloadRules.destinationFolder(in: parent).standardizedFileURL.path + "/"), parent.startAccessingSecurityScopedResource() else { return nil }
        return parent
    }
}

struct DownloadLocationSection: View {
    @ObservedObject private var store = DownloadStore.shared
    var body: some View {
        Section("下载位置") {
            Button("选择文件夹") { store.choose() }.disabled(store.operations > 0).softGroupedRow(top: true)
            Text(store.label).font(.caption).textSelection(.enabled).softGroupedRow()
            DisclosureGroup {
                Text("文件会存到所选目录的 RepoPocket 子文件夹，清缓存不删除。下载请保持前台，中断后重试。")
                    .font(.caption).foregroundColor(.secondary)
            } label: {
                Text("下载位置说明").font(.caption)
            }.softGroupedRow(bottom: true)
        }
    }
}
