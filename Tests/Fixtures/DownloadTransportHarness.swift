import Foundation
import CryptoKit

// Inserted into the production delegate only in the generated test executable.
final class Trace: @unchecked Sendable {
    // Keep weak-self actor deliveries observable until the explicit drain.
    var keepAlive: AnyObject?
    // Installed before transfer; invoked only by the real didFinish callback.
    var onPreserved: (() -> Void)?
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    func add(_ kind: String, _ received: Int64 = -1, _ total: Int64? = nil) {
        lock.lock(); defer { lock.unlock() }
        events.append(["kind": kind, "time": ProcessInfo.processInfo.systemUptime,
                       "received": received, "total": total.map { $0 as Any } ?? NSNull(),
                       "mainThread": Thread.isMainThread])
    }
    func snapshot() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }; return events
    }
}

// HTTP is allowed only for this ephemeral loopback fixture, never production.
final class ReleaseAssetRedirectPolicy: NSObject, URLSessionTaskDelegate {
    let port: Int
    let trace: Trace
    init(port: Int, trace: Trace) { self.port = port; self.trace = trace }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        trace.add("redirect")
        guard let url = request.url, url.scheme == "http", url.host == "127.0.0.1",
              url.port == port else { completionHandler(nil); return }
        var next = request
        next.setValue(nil, forHTTPHeaderField: "Authorization")
        next.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(next)
    }
}

// PRODUCTION_PROGRESS

// Accessed only on URLSession's serial delegate queue. The download temporary
// URL must be copied before didFinishDownloadingTo returns.
final class SessionResult {
    let continuation: CheckedContinuation<(URL, URLResponse), Error>
    var result: Result<(URL, URLResponse), Error>?
    init(_ continuation: CheckedContinuation<(URL, URLResponse), Error>) {
        self.continuation = continuation
    }
    func finish(_ url: URL, _ response: URLResponse?) {
        result = Result {
            guard let response else { throw URLError(.badServerResponse) }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: copy)
            return (copy, response)
        }
    }
    func complete(_ error: Error?) {
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(with: result ?? .failure(URLError(.unknown))) }
    }
}

@main struct TransportHarness {
    static func download(_ mode: String, _ url: URL, _ trace: Trace, probe: String) async {
        let transfer = ReleaseAssetDownloadDelegate(trace: trace, update: { value in
            // Production invokes this closure from its @MainActor task; Trace
            // itself is locked because didWrite and completion use other queues.
            trace.add("delivered", value.received, value.total)
        }, policy: ReleaseAssetRedirectPolicy(port: url.port!, trace: trace), deliverOnMainActor: true)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        trace.keepAlive = transfer
        if probe == "cancel-after-preserve" {
            trace.onPreserved = { [weak transfer] in transfer?.cancel() }
        }
        let session = mode == "session-download-task"
            ? URLSession(configuration: config, delegate: transfer, delegateQueue: nil)
            : URLSession(configuration: config)
        defer {
            trace.add("stop")
            transfer.stop()
            session.finishTasksAndInvalidate()
        }
        do {
            let pair: (URL, URLResponse)
            if mode == "production" {
                if probe == "pre-cancel" {
                    let gate = DispatchSemaphore(value: 0)
                    let work = Task.detached {
                        gate.wait()
                        return try await transfer.download(using: session, request: URLRequest(url: url))
                    }
                    work.cancel()
                    gate.signal()
                    pair = try await work.value
                } else if probe == "pause-resume" || probe == "pause-cancel" {
                    let work = Task { try await transfer.download(using: session, request: URLRequest(url: url)) }
                    for _ in 0..<100 {
                        if trace.snapshot().contains(where: { $0["kind"] as? String == "delivered" }) { break }
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                    let task = transfer.fixtureTask
                    await MainActor.run {
                        transfer.setPaused(true); transfer.setPaused(true)
                        trace.add("paused")
                    }
                    try await Task.sleep(nanoseconds: 200_000_000) // Drain a callback already in flight.
                    trace.add("suspended", task?.state == .suspended ? 1 : 0)
                    trace.add("paused-bytes", task?.countOfBytesReceived ?? -1)
                    try await Task.sleep(nanoseconds: 600_000_000)
                    trace.add("paused-bytes", task?.countOfBytesReceived ?? -1)
                    if probe == "pause-resume" {
                        await MainActor.run {
                            trace.add("resume")
                            transfer.setPaused(false); transfer.setPaused(false)
                            trace.add("same-task", task != nil && task === transfer.fixtureTask ? 1 : 0)
                        }
                    } else { work.cancel() }
                    pair = try await work.value
                } else if probe == "cancel" || probe == "session-invalidated" {
                    let work = Task { try await transfer.download(using: session, request: URLRequest(url: url)) }
                    try await Task.sleep(nanoseconds: 650_000_000)
                    trace.add("cancel-requested")
                    if probe == "cancel" { work.cancel(); work.cancel() }
                    else { session.invalidateAndCancel() }
                    pair = try await work.value
                } else {
                    pair = try await transfer.download(using: session, request: URLRequest(url: url))
                }
            } else if mode == "async-per-task" {
                pair = try await session.download(for: URLRequest(url: url), delegate: transfer)
            } else {
                pair = try await withCheckedThrowingContinuation { continuation in
                    let result = SessionResult(continuation)
                    transfer.fixtureFinish = result.finish
                    transfer.fixtureComplete = result.complete
                    let task = session.downloadTask(with: URLRequest(url: url))
                    if mode == "explicit-task-delegate" { task.delegate = transfer }
                    task.resume()
                }
            }
            trace.add("completed")
            defer { try? FileManager.default.removeItem(at: pair.0) }
            let data = try Data(contentsOf: pair.0)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            trace.add("size", Int64(data.count))
            trace.add("sha256:" + hash)
            trace.add("status", Int64((pair.1 as? HTTPURLResponse)?.statusCode ?? 0))
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { trace.add("cancelled") }
            trace.add("error:" + String(describing: error))
        }
    }
    static func ownedFiles() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix("RepoPocket-transfer-") })
    }
    static func main() async {
        let base = CommandLine.arguments[1]
        for mode in ["async-per-task", "session-download-task", "explicit-task-delegate", "production"] {
            let paths = ["known", "unknown", "redirect", "short", "short-blocked"]
                + (mode == "production" ? ["cancel", "pre-cancel", "session-invalidated", "abort", "cancel-after-preserve", "pause-resume", "pause-cancel"] : [])
            for path in paths {
                let before = ownedFiles()
                let trace = Trace()
                let endpoint = ["cancel", "pre-cancel", "session-invalidated", "pause-resume", "pause-cancel"].contains(path) ? "known"
                    : (["short-blocked", "cancel-after-preserve"].contains(path) ? "short" : path)
                let url = URL(string: base + "/" + endpoint)!
                if path == "short-blocked" {
                    // Deliberately hold MainActor, not the delegate queue: observe
                    // real callbacks queued before stop, then dropped after stop.
                    let start = DispatchSemaphore(value: 0)
                    let done = DispatchSemaphore(value: 0)
                    let work = Task.detached {
                        start.wait()
                        await download(mode, url, trace, probe: path)
                        done.signal()
                    }
                    await MainActor.run {
                        trace.add("actor-blocked")
                        start.signal()
                        if done.wait(timeout: .now() + 20) == .timedOut { trace.add("actor-timeout") }
                        trace.add("actor-released")
                    }
                    await work.value
                } else { await download(mode, url, trace, probe: path) }
                // Drain real queued MainActor tasks, without synthesizing progress.
                try? await Task.sleep(nanoseconds: 250_000_000)
                await MainActor.run {}
                trace.add("owned-files-left", Int64(ownedFiles().subtracting(before).count))
                let report: [String: Any] = ["mode": mode, "path": path,
                    "runtime": ProcessInfo.processInfo.operatingSystemVersionString,
                    "events": trace.snapshot()]
                do {
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                    fflush(stdout)
                } catch { print("JSON_ERROR: \(error)") }
                trace.keepAlive = nil
            }
        }
    }
}
