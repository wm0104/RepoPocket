import SwiftUI
import Foundation
import Combine

@MainActor final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()
    private let bookmarkKey = "RepoPocket.download.folder.v1"
    @Published var picker: WorkspaceImportRequest?
    @Published private(set) var label: String
    @Published private(set) var error = ""
    @Published private(set) var operations = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var observer: AnyCancellable?

    init() {
        let defaults = UserDefaults.standard
        let cached = defaults.string(forKey: "RepoPocket.download.label.v1")
        label = DownloadRules.initialLabel(cached, hasBookmark: defaults.data(forKey: bookmarkKey) != nil)
        if cached?.hasPrefix("/") != true { defaults.removeObject(forKey: "RepoPocket.download.label.v1") }
        observer = NotificationCenter.default.publisher(for: .githubAccountChanged).sink { [weak self] _ in self?.selected(nil) }
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
    func clearError() { error = "" }
    func choose() {
        guard operations == 0, picker == nil else { return }
        clearError(); picker = WorkspaceImportRequest(kind: .folder)
    }
    func requireAuthorization() async throws {
        try Task.checkCancellation()
        if (try? resolve()) != nil { return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiters[id] = continuation
                if picker == nil { picker = WorkspaceImportRequest(kind: .folder) }
            }
        }, onCancel: {
            Task { @MainActor in
                guard let continuation = self.waiters.removeValue(forKey: id) else { return }
                continuation.resume(throwing: CancellationError())
                if self.waiters.isEmpty { self.picker = nil }
            }
        })
        try Task.checkCancellation()
    }
    func selected(_ urls: [URL]?) {
        picker = nil
        let result: Result<Void, Error>
        do {
            guard let url = urls?.first else { throw CancellationError() }
            guard operations == 0 else { throw AppError(text: "请等待当前下载结束后再更改保存位置。") }
            guard url.startAccessingSecurityScopedResource() else { throw AppError(text: "文件夹未授权，请重选。") }
            defer { url.stopAccessingSecurityScopedResource() }
            try DownloadRules.rejectSymlinks(url)
            let data = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            label = DownloadRules.destinationFolder(in: url).path
            UserDefaults.standard.set(label, forKey: "RepoPocket.download.label.v1")
            clearError(); result = .success(())
        } catch {
            if !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription }
            result = .failure(error)
        }
        let waiting = waiters.values; waiters = [:]
        for waiter in waiting { waiter.resume(with: result) }
    }
    func begin() { operations += 1 }
    func end() { operations = max(0, operations - 1) }
    func persist(_ temporary: URL, session: UUID) async throws -> URL {
        try Task.checkCancellation()
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
        let saved = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, session == AccountStore.generation else { try? FileManager.default.removeItem(at: saved); throw CancellationError() }
        return saved
    }
    func shareBookmark(for url: URL) -> Data? {
        guard let parent = try? resolve(), url.standardizedFileURL.path.hasPrefix(DownloadRules.destinationFolder(in: parent).standardizedFileURL.path + "/") else { return nil }
        return UserDefaults.standard.data(forKey: bookmarkKey)
    }
    func shareScope(for url: URL, bookmark: Data? = nil) -> URL? {
        let parent: URL
        if let bookmark {
            var stale = false
            guard let restored = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
            parent = restored
        } else {
            guard let current = try? resolve() else { return nil }
            parent = current
        }
        guard url.standardizedFileURL.path.hasPrefix(DownloadRules.destinationFolder(in: parent).standardizedFileURL.path + "/"), parent.startAccessingSecurityScopedResource() else { return nil }
        do { try DownloadRules.rejectSymlinks(parent); return parent }
        catch { parent.stopAccessingSecurityScopedResource(); return nil }
    }
}
