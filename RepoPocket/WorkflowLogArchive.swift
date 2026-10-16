import Foundation
import ZIPFoundation

struct WorkflowStepOutput {
    let text: String
    let limited: Bool
}
struct WorkflowStepLogs {
    let steps: [Int: WorkflowStepOutput]
}

/// Read each real step file, rather than guessing boundaries from coarse timestamps.
enum WorkflowLogArchiveRules {
    static let archiveLimit = 32 * 1024 * 1024
    static let stepLimit = 2 * 1024 * 1024
    static func read(_ file: URL, job: String, steps: Set<Int>) throws -> WorkflowStepLogs {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= archiveLimit else { throw AppError(text: "日志归档超过 32 MiB，已停止读取。") }
        let archive = try Archive(url: file, accessMode: .read)
        let names = Set([job, job.replacingOccurrences(of: "/", with: "_"),
            job.replacingOccurrences(of: #"[\\/:*?\"<>|]"#, with: "_", options: .regularExpression)])
        var output: [Int: WorkflowStepOutput] = [:]
        var folder: String?, total = 0, count = 0
        for entry in archive {
            try Task.checkCancellation()
            count += 1
            guard count <= 5000 else { throw AppError(text: "日志归档文件过多。") }
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard entry.type == .file, parts.count == 2, names.contains(String(parts[0])),
                  parts[1].hasSuffix(".txt"), let number = Int(parts[1].prefix(while: { $0.isNumber })),
                  parts[1].dropFirst(String(number).count).hasPrefix("_"), steps.contains(number) else { continue }
            guard folder == nil || folder == String(parts[0]), output[number] == nil else {
                throw AppError(text: "日志归档含有重名任务或步骤，已停止以免显示错误输出。")
            }
            folder = String(parts[0])
            guard entry.uncompressedSize <= UInt64(stepLimit), total + Int(entry.uncompressedSize) <= archiveLimit else {
                output[number] = WorkflowStepOutput(text: "此步骤日志超过 2 MiB 或本次归档读取预算。", limited: true)
                continue
            }
            var bytes = Data()
            _ = try archive.extract(entry, bufferSize: 64 * 1024) { chunk in
                try Task.checkCancellation()
                guard bytes.count + chunk.count <= stepLimit else { throw AppError(text: "步骤日志超过读取预算。") }
                bytes.append(chunk)
            }
            total += bytes.count
            guard let text = String(data: bytes, encoding: .utf8) else { throw AppError(text: "步骤日志不是有效 UTF-8 文本。") }
            let clean = text.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            output[number] = WorkflowStepOutput(text: clean, limited: false)
        }
        guard folder != nil else { throw AppError(text: "归档中暂未找到该任务的步骤日志，请在运行结束后刷新。") }
        return WorkflowStepLogs(steps: output)
    }
}

/// Reuse the existing credential-stripping redirect policy, with a log-only budget.
final class WorkflowLogArchiveDownloadPolicy: NSObject, URLSessionDownloadDelegate {
    private let redirects = WorkflowLogRedirectPolicy()
    private let lock = NSLock()
    private var exceeded = false
    var exceededBudget: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Int64(WorkflowLogArchiveRules.archiveLimit) || totalBytesExpectedToWrite > Int64(WorkflowLogArchiveRules.archiveLimit) {
            lock.lock(); exceeded = true; lock.unlock(); downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
