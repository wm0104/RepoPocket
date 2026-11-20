import Foundation

@MainActor protocol ReleaseAssetDownloading {
    var label: String { get }
    func authorize() async throws
    func begin()
    func end()
    func download(api: GitHub, repo: String, asset: Asset, update: @escaping (ReleaseDownloadProgress) -> Void) async throws -> URL
    func persist(_ file: URL, generation: UUID) async throws -> URL
}

/// Uses the shared authorized folder and the release page's progress presenter.
@MainActor struct LiveReleaseAssetDownloader: ReleaseAssetDownloading {
    var label: String { DownloadStore.shared.label }
    func authorize() async throws { try await DownloadStore.shared.requireAuthorization() }
    func begin() { DownloadStore.shared.begin() }
    func end() { DownloadStore.shared.end() }
    func download(api: GitHub, repo: String, asset: Asset, update: @escaping (ReleaseDownloadProgress) -> Void) async throws -> URL {
        try await api.downloadManagedAssetWithProgress(repo, asset: asset, transfer: update)
    }
    func persist(_ file: URL, generation: UUID) async throws -> URL {
        try await DownloadStore.shared.persist(file, session: generation)
    }
}

struct ReleaseDownloadProgress: Equatable {
    let received: Int64
    let total: Int64?
    init(received: Int64, total: Int64) {
        self.received = max(0, received)
        self.total = total > 0 && received <= total ? total : nil
    }
    var fraction: Double? { total.map { min(1, Double(received) / Double($0)) } }
    var label: String {
        let size = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard let total else { return "已下载 " + size }
        return size + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

struct ReleaseAssetDownload: Equatable {
    enum Stage: Equatable { case authorizing, connecting, downloading, saving, completed, failed, cancelled }
    let request = UUID()
    let assetID: Int
    var stage = Stage.authorizing
    var progress: ReleaseDownloadProgress?
    var message = ""
    var active: Bool { [.authorizing, .connecting, .downloading, .saving].contains(stage) }
    var cancellable: Bool { stage == .connecting || stage == .downloading }
    var title: String {
        switch stage {
        case .authorizing: return "正在确认保存位置…"
        case .connecting: return "正在连接…"
        case .downloading: return progress?.label ?? "正在下载…"
        case .saving: return "正在保存…"
        case .completed: return "下载完成"
        case .failed: return "下载失败：" + message
        case .cancelled: return "下载已取消"
        }
    }
}

/// At most five UI updates per second; the first update, size changes and end
/// always pass. No timer/polling continues when the download is idle.
final class ReleaseAssetDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let update: (ReleaseDownloadProgress) -> Void
    private let clock: () -> TimeInterval
    private let lock = NSLock()
    private var lastTime: TimeInterval?
    private var lastTotal: Int64?
    private var lastBytes: Int64 = -1
    private let policy: URLSessionTaskDelegate
    private let deliverOnMainActor: Bool
    private var stopped = false
    private var started = false
    private var paused = false
    private var cancelled = false
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var downloadTask: URLSessionDownloadTask?
    private var fileResult: Result<(URL, URLResponse), Error>?
    init(update: @escaping (ReleaseDownloadProgress) -> Void, policy: URLSessionTaskDelegate = ReleaseAssetRedirectPolicy(),
         deliverOnMainActor: Bool = false, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.update = update; self.policy = policy; self.deliverOnMainActor = deliverOnMainActor; self.clock = clock
    }
    // Keep the account-owned session: completion-handler download tasks can
    // bypass download progress callbacks even with a task-specific delegate.
    func download(using session: URLSession, request: URLRequest) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !started, !cancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                started = true
                let task = session.downloadTask(with: request)
                task.delegate = self
                self.continuation = continuation
                downloadTask = task
                if !paused { task.resume() }
                lock.unlock()
            }
        } onCancel: { self.cancel() }
    }
    @discardableResult func setPaused(_ value: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, !cancelled, !started || downloadTask != nil else { return false }
        if paused != value {
            paused = value
            if value { downloadTask?.suspend() } else { downloadTask?.resume() }
        }
        return true
    }
    func cancel() {
        lock.lock()
        cancelled = true; stopped = true
        let task = downloadTask
        lock.unlock()
        task?.cancel()
        finish(error: CancellationError())
    }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    private var active: Bool { lock.lock(); defer { lock.unlock() }; return !stopped && !paused }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let pending = continuation != nil; lock.unlock()
        guard pending else { return }
        // URLSession deletes location after this callback: take ownership now,
        // but do not resume until didComplete confirms the transfer succeeded.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("RepoPocket-transfer-" + UUID().uuidString)
        let result: Result<(URL, URLResponse), Error>
        do {
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: location, to: file)
            result = .success((file, response))
        } catch {
            try? FileManager.default.removeItem(at: file)
            result = .failure(error)
        }
        lock.lock()
        let abandoned = continuation == nil || cancelled
        if !abandoned { fileResult = result }
        lock.unlock()
        if abandoned, case .success(let pair) = result { try? FileManager.default.removeItem(at: pair.0) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error: error)
    }
    private func finish(error: Error?) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil; downloadTask = nil
        let saved = fileResult
        fileResult = nil
        let failure: Error? = cancelled ? CancellationError() : error
        let result = failure.map { Result<(URL, URLResponse), Error>.failure($0) }
            ?? saved ?? .failure(URLError(.badServerResponse))
        lock.unlock()
        if failure != nil, case .success(let pair)? = saved { try? FileManager.default.removeItem(at: pair.0) }
        continuation.resume(with: result)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        receive(ReleaseDownloadProgress(received: totalBytesWritten, total: totalBytesExpectedToWrite))
    }
    func receive(_ value: ReleaseDownloadProgress) {
        lock.lock()
        let now = clock()
        let changed = value.received != lastBytes || value.total != lastTotal
        let emit = changed && (lastTime == nil || value.total != lastTotal || value.fraction == 1 || now - (lastTime ?? now) >= 0.2)
        if emit { lastTime = now; lastTotal = value.total; lastBytes = value.received }
        lock.unlock()
        if emit, active {
            if deliverOnMainActor {
                Task { @MainActor [weak self] in
                    guard let self, self.active else { return }
                    self.update(value)
                }
            } else { update(value) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) {
        policy.urlSession?(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler) ?? completionHandler(request)
    }
}
