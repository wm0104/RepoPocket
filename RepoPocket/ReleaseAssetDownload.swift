import Foundation

@MainActor protocol ReleaseAssetDownloading {
    var label: String { get }
    func authorize() async throws
    func begin()
    func end()
    func download(api: GitHub, repo: String, asset: Asset, update: @escaping (ReleaseDownloadProgress) -> Void) async throws -> URL
    func persist(_ file: URL, generation: UUID) async throws -> URL
}

/// Uses the existing authorization, authenticated streaming and scoped save path.
@MainActor struct LiveReleaseAssetDownloader: ReleaseAssetDownloading {
    var label: String { DownloadStore.shared.label }
    func authorize() async throws { try await DownloadStore.shared.requireAuthorization() }
    func begin() { DownloadStore.shared.begin() }
    func end() { DownloadStore.shared.end() }
    func download(api: GitHub, repo: String, asset: Asset, update: @escaping (ReleaseDownloadProgress) -> Void) async throws -> URL {
        try await api.downloadManagedAssetWithProgress(repo, asset: asset, transfer: update)
    }
    func persist(_ file: URL, generation: UUID) async throws -> URL { try await DownloadStore.shared.persist(file, session: generation) }
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
        guard let total, let fraction else { return "已下载 " + size }
        return "\(Int((fraction * 100).rounded(.down)))% · " + size + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
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
    private let policy = ReleaseAssetRedirectPolicy()
    init(update: @escaping (ReleaseDownloadProgress) -> Void, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.update = update; self.clock = clock
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
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
        if emit { update(value) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) {
        policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }
}
