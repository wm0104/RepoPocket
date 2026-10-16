import Foundation

/// One utility queue bounds CPU/IO across projects. Scrolling never calls this service.
actor LocalGitEngine {
    static let shared = LocalGitEngine()
    private let queue = DispatchQueue(label: "RepoPocket.NativeGit", qos: .utility)

    func run<T: Decodable>(_ operation: String, project: LocalGitProject, metadata: URL,
                           internalRoot: URL, arguments: [String: Any] = [:],
                           as: T.Type = T.self) async throws -> T {
        try Task.checkCancellation()
        let value: T = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result: T = try LocalGitFileAccess.withRoot(project, internalRoot: internalRoot) { root in
                        try LocalGitFileAccess.coordinate(root, writing: ["commit", "pull", "associate"].contains(operation)) { coordinated in
                            guard try LocalGitFileAccess.identity(coordinated) == project.identity else { throw LocalGitError(text: "文件提供器切换了目录，请重新授权原目录。") }
                            var request = arguments
                            request["repository"] = project.usesPrivateGit ? metadata.path : root.appendingPathComponent(".git").path
                            request["workdir"] = root.path
                            request["privateGit"] = project.usesPrivateGit
                            return try Self.invoke(operation, request: request)
                        }
                    }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return value
    }
    func file<T>(project: LocalGitProject, internalRoot: URL, operation: @escaping (URL) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let result: T = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try LocalGitFileAccess.withRoot(project, internalRoot: internalRoot, operation: operation) })
            }
        }
        try Task.checkCancellation(); return result
    }
    func clone(parent: LocalGitProject, internalRoot: URL, name: String, remote: String, branch: String, token: String) async throws -> URL {
        let child = try LocalGitRules.child(name)
        return try await file(project: parent, internalRoot: internalRoot) { root in
            let target = root.appendingPathComponent(child, isDirectory: true)
            try LocalGitFileAccess.coordinate(root, writing: true) { _ in
                let _: LocalGitStatus = try Self.invoke("clone", request: ["destination": target.path, "remote": remote, "branch": branch, "token": token])
            }
            return target
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
