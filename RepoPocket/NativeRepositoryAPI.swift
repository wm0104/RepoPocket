import Foundation

final class WorkflowLogRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", let host = url.host,
              host.hasSuffix(".blob.core.windows.net") || host.hasSuffix(".githubusercontent.com") else { completionHandler(nil); return }
        var clean = request
        clean.setValue(nil, forHTTPHeaderField: "Authorization"); clean.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(clean)
    }
}
extension GitHub {
    func workflowRuns(_ repo: String, branch: String, page: Int, failedOnly: Bool = false) async throws -> [WorkflowRun] {
        let query = try CommunityRules.page(page) + (branch.isEmpty ? [] : [.init(name: "branch", value: branch)])
            + (failedOnly ? [.init(name: "status", value: "failure")] : [])
        let bytes = try await communityRead(Self.repoPath(repo) + "/actions/runs", query: query)
        return try JSONDecoder().decode(WorkflowRuns.self, from: bytes).workflow_runs
    }
    func workflowJobs(_ repo: String, run: Int, page: Int) async throws -> [WorkflowJob] {
        guard run > 0 else { throw AppError(text: "无效运行编号") }
        let bytes = try await communityRead(Self.repoPath(repo) + "/actions/runs/\(run)/jobs", query: CommunityRules.page(page))
        return try JSONDecoder().decode(WorkflowJobs.self, from: bytes).jobs
    }
    func codeLineSummary(_ repo: String, branch: String, progress: @escaping (Int) -> Void) async throws -> CodeLineSummary {
        let selected = try await resolvedBranch(repo, branch: branch)
        let head = try await workspaceHead(repo, branch: selected)
        let bytes = try await communityRead(Self.repoPath(repo) + "/git/trees/" + Self.component(head), query: [.init(name: "recursive", value: "1")])
        let tree = try JSONDecoder().decode(CodeTree.self, from: bytes)
        let files = tree.tree.filter { $0.type == "blob" && NativeStatisticsRules.extensions.contains(($0.path as NSString).pathExtension.lowercased()) }
        var count = 0, lines = 0, budget = 0, attempted = 0
        for file in files {
            try Task.checkCancellation()
            guard attempted < 40 else { break }
            guard let size = file.size, size <= 128 * 1024, budget + size <= 2 * 1024 * 1024 else { continue }
            attempted += 1; budget += size
            let entry = try await self.file(repo, path: file.path, branch: head)
            guard entry.encoding == "base64", let raw = entry.content,
                  let data = Data(base64Encoded: raw, options: .ignoreUnknownCharacters), data.count <= 128 * 1024, !data.contains(0),
                  let text = String(data: data, encoding: .utf8) else { continue }
            lines += NativeStatisticsRules.lineCount(text); count += 1; progress(count)
        }
        return CodeLineSummary(files: count, lines: lines, skipped: files.count - count, treeTruncated: tree.truncated == true)
    }
}
