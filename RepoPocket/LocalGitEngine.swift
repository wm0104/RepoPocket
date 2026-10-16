import Foundation

/// One utility queue bounds CPU/IO across projects. Scrolling never calls this service.
actor LocalGitEngine {
    static let shared = LocalGitEngine()
    private let queue = DispatchQueue(label: "RepoPocket.NativeGit", qos: .utility)

    func run<T: Decodable>(_ operation: String, project: LocalGitProject, metadata: URL,
                           internalRoot: URL, arguments: [String: Any] = [:],
                           generation: UUID? = nil, as: T.Type = T.self) async throws -> T {
        try Task.checkCancellation()
        let job = LocalGitJob()
        let value: T = try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try job.check()
                    if let generation, generation != AccountStore.generation { throw CancellationError() }
                    let result: T = try LocalGitFileAccess.withRoot(project, internalRoot: internalRoot) { root in
                        try LocalGitFileAccess.coordinate(root, writing: ["commit", "pull", "associate", "clone", "recover"].contains(operation)) { coordinated in
                            guard try LocalGitFileAccess.identity(coordinated) == project.identity else { throw LocalGitError(text: "文件提供器切换了目录，请重新授权原目录。") }
                            var request = arguments
                            request["requestID"] = job.id
                            request["repository"] = project.usesPrivateGit ? metadata.path : root.appendingPathComponent(".git").path
                            request["workdir"] = root.path
                            request["privateGit"] = project.usesPrivateGit
                            if operation == "clone" { request["destination"] = root.appendingPathComponent(try LocalGitRules.child(arguments["folderName"] as? String ?? "")).path }
                            return try Self.invoke(operation, request: request)
                        }
                    }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
          }
        }, onCancel: { job.cancel() })
        try Task.checkCancellation()
        return value
    }
    func file<T>(project: LocalGitProject, internalRoot: URL, generation: UUID? = nil, operation: @escaping (URL) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let job = LocalGitJob()
        let result: T = try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try job.check()
                    if let generation, generation != AccountStore.generation { throw CancellationError() }
                    return try LocalGitFileAccess.withRoot(project, internalRoot: internalRoot, operation: operation)
                })
            }
          }
        }, onCancel: { job.cancel() })
        try Task.checkCancellation(); return result
    }
    func clone(parent: LocalGitProject, metadata: URL, internalRoot: URL, name: String, remote: String, branch: String, token: String, generation: UUID) async throws -> LocalGitProject {
        let child = try LocalGitRules.child(name)
        let _: LocalGitStatus = try await run("clone", project: parent, metadata: metadata, internalRoot: internalRoot,
            arguments: ["folderName": child, "remote": remote, "branch": branch, "token": token], generation: generation)
        return try await file(project: parent, internalRoot: internalRoot, generation: generation) { root in
            let target = root.appendingPathComponent(child, isDirectory: true)
            return LocalGitProject(id: UUID(), name: child,
                bookmark: try target.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil),
                identity: try LocalGitFileAccess.identity(target), metadataID: UUID(), usesPrivateGit: false)
        }
    }
    nonisolated private static func invoke<T: Decodable>(_ operation: String, request: [String: Any]) throws -> T {
        let bytes = try JSONSerialization.data(withJSONObject: request)
        guard let input = String(data: bytes, encoding: .utf8) else { throw LocalGitError(text: "Git 请求编码失败。") }
        guard let pointer = rp_git_execute(operation, input) else { throw LocalGitError(text: "Git 内核没有返回结果。") }
        defer { rp_git_free(pointer) }
        let reply = Data(String(cString: pointer).utf8)
        let envelope = try JSONDecoder().decode(NativeEnvelope<T>.self, from: reply)
        guard envelope.ok, let value = envelope.result else { throw LocalGitError(text: envelope.error ?? "Git 操作失败。") }
        return value
    }
}
private struct NativeEnvelope<T: Decodable>: Decodable { let ok: Bool; let result: T?; let error: String? }
private final class LocalGitJob: @unchecked Sendable {
    let id = UUID().uuidString
    private let lock = NSLock()
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        rp_git_cancel(id)
    }
    func check() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
    }
}
