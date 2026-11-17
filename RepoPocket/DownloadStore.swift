import SwiftUI
import Foundation
import Combine

@MainActor final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()
    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var error = ""
    @Published private(set) var operations = 0
    let label = "App 内下载中心"
    private let root: URL
    private var accountID = AccountStore.activeID
    private var tasks: [UUID: Task<URL, Error>] = [:]
    private var attempts: [UUID: UUID] = [:]
    private var historyLoaded = false
    private var observer: AnyCancellable?
    private var history: DownloadHistory { DownloadHistory(root: root, accountID: accountID) }

    init(root: URL? = nil, container: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        // Resolve the system container once, before appending any App-managed components.
        // Explicit download roots remain untrusted, including preview/test overrides.
        self.root = root ?? DownloadRules.canonicalContainer(container)
            .appendingPathComponent("Library/Application Support/Downloads", isDirectory: true)
        load()
        observer = NotificationCenter.default.publisher(for: .githubAccountChanged).sink { [weak self] _ in self?.changedAccount() }
    }
    private func load() {
        do { records = try history.load(); historyLoaded = true; error = "" }
        catch { historyLoaded = false; self.error = "无法读取下载记录：" + error.localizedDescription }
    }
    /// Called by an explicit user download/retry, never a background error-swallowing loop.
    func retryHistory() throws {
        guard tasks.isEmpty else { throw AppError(text: "请等待当前下载结束后重试读取记录。") }
        load()
        guard historyLoaded else { throw AppError(text: error) }
    }
    private func saveHistory() {
        guard historyLoaded else { return }
        do { try history.save(records); error = "" }
        catch { self.error = "下载记录保存失败：" + error.localizedDescription }
    }
    private func changedAccount() {
        for task in tasks.values { task.cancel() }
        for index in records.indices where records[index].active { records[index].state = .interrupted }
        saveHistory()
        tasks = [:]; attempts = [:]; records = []; accountID = AccountStore.activeID; load()
    }
    func begin() { operations += 1 }
    func end() { operations = max(0, operations - 1) }
    // Self-update retains its verification flow; saving no longer opens a folder picker.
    func requireAuthorization() async throws {
        try Task.checkCancellation()
        if !historyLoaded { try retryHistory() }
        try DownloadRules.rejectSymlinks(history.folder)
        try FileManager.default.createDirectory(at: history.folder, withIntermediateDirectories: true)
    }
    func download(_ source: DownloadSource, api: GitHub,
                  progress: @escaping (ReleaseDownloadProgress) -> Void = { _ in }) async throws -> URL {
        try await run(DownloadRecord(id: UUID(), source: source, created: Date()), api: api, progress: progress)
    }
    func retry(_ record: DownloadRecord, api: GitHub) async throws {
        guard records.contains(record), record.retryable, tasks[record.id] == nil else { return }
        var retried = record
        retried.state = .connecting; retried.message = ""; retried.received = 0; retried.total = nil
        _ = try await run(retried, api: api, progress: { _ in })
    }
    private func run(_ record: DownloadRecord, api: GitHub,
                     progress: @escaping (ReleaseDownloadProgress) -> Void) async throws -> URL {
        try Task.checkCancellation()
        guard api.isCurrentSession, api.accountID == accountID, accountID != "legacy" else {
            throw AppError(text: "请登录原账号后下载。")
        }
        if !historyLoaded { try retryHistory() }
        let generation = AccountStore.generation, owner = accountID, id = record.id, attempt = UUID()
        if let index = records.firstIndex(where: { $0.id == id }) { records[index] = record }
        else { records.insert(record, at: 0) }
        do { try history.save(records) }
        catch { update(id) { $0.state = .failed; $0.message = "无法保存下载记录。" }; throw error }
        attempts[id] = attempt
        let task = Task { () throws -> URL in
            begin(); defer { end(); if attempts[id] == attempt { tasks[id] = nil; attempts[id] = nil } }
            do {
                let temporary = try await api.downloadForCenter(record.source) { [weak self] value in
                    Task { @MainActor in
                        guard let self, generation == AccountStore.generation, self.accountID == owner, self.attempts[id] == attempt,
                              let index = self.records.firstIndex(where: { $0.id == id }),
                              self.records[index].state == .connecting || self.records[index].state == .downloading else { return }
                        self.records[index].state = .downloading
                        self.records[index].received = value.received; self.records[index].total = value.total
                        progress(value)
                    }
                }
                defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
                try Task.checkCancellation()
                guard generation == AccountStore.generation, accountID == owner else { throw CancellationError() }
                update(id) { $0.state = .saving }
                let saved = try await persist(temporary, session: generation, recordID: id)
                do {
                    guard generation == AccountStore.generation, accountID == owner,
                          let index = records.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                    records[index].state = .completed; records[index].fileName = saved.lastPathComponent; records[index].message = ""
                    records[index].fileSize = history.fileSize(records[index])
                    try history.save(records)
                } catch { try? FileManager.default.removeItem(at: saved); throw error }
                return saved
            } catch {
                if generation == AccountStore.generation, accountID == owner {
                    update(id) {
                        $0.state = RefreshFailure.isCancellation(error) || Task.isCancelled ? .cancelled : .failed
                        $0.message = $0.state == .failed ? error.localizedDescription : ""
                    }
                }
                throw error
            }
        }
        tasks[id] = task
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private func update(_ id: UUID, _ change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index]); saveHistory()
    }
    func cancel(_ record: DownloadRecord) { tasks[record.id]?.cancel() }
    func file(_ record: DownloadRecord) throws -> URL {
        guard records.contains(record) else { throw CancellationError() }
        return try history.file(record)
    }
    func delete(_ record: DownloadRecord) throws { records = try history.delete(record, from: records) }
    func persist(_ temporary: URL, session: UUID, recordID: UUID? = nil) async throws -> URL {
        try Task.checkCancellation()
        guard session == AccountStore.generation else { throw CancellationError() }
        if !historyLoaded { try retryHistory() }
        let parent = history.folder
        let worker = Task.detached(priority: .utility) { () throws -> URL in
            try Task.checkCancellation()
            guard session == AccountStore.generation else { throw CancellationError() }
            try DownloadRules.rejectSymlinks(parent)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let sourceBytes = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
            if let available = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               available < sourceBytes { throw AppError(text: "本机空间不足，请释放空间后重试。") }
            return try DownloadRules.save(temporary, parent: parent,
                valid: { session == AccountStore.generation && !Task.isCancelled }, fingerprint: LocalStore.snapshotFileSHA256)
        }
        let saved = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, session == AccountStore.generation else { try? FileManager.default.removeItem(at: saved); throw CancellationError() }
        if recordID == nil {
            guard historyLoaded else { try? FileManager.default.removeItem(at: saved); throw AppError(text: error) }
            var record = DownloadRecord(id: UUID(), source: .local(name: saved.lastPathComponent), created: Date(), state: .completed, fileName: saved.lastPathComponent)
            record.fileSize = history.fileSize(record)
            do { try history.save([record] + records); records.insert(record, at: 0) }
            catch { try? FileManager.default.removeItem(at: saved); throw error }
        }
        return saved
    }
}
