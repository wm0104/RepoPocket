import Foundation

struct WorkflowInputDefinition {
    let schema: WorkflowInputSchema
    let sha: String
    let environments: [String]
}

extension GitHub {
    func workflowInputDefinition(_ repo: String, workflow: DispatchWorkflow, ref: String) async throws -> WorkflowInputDefinition {
        guard workflow.path.hasPrefix(".github/workflows/"), !ref.isEmpty else { throw AppError(text: "无效工作流文件或 ref") }
        struct Content: Decodable { let type: String; let encoding: String; let content: String; let sha: String; let size: Int }
        let bytes: Data
        do { bytes = try await workflowInputsSource(repo, path: workflow.path, ref: ref) }
        catch { throw AppError(text: "无法读取所选 ref 的工作流文件；请检查 Contents: read 权限。\n" + error.localizedDescription) }
        let content = try JSONDecoder().decode(Content.self, from: bytes)
        guard content.type == "file", content.encoding == "base64", content.size >= 0, content.size <= 512 * 1024, !content.sha.isEmpty,
              let decoded = Data(base64Encoded: content.content.filter { !$0.isWhitespace }), decoded.count <= 512 * 1024,
              let yaml = String(data: decoded, encoding: .utf8) else { throw AppError(text: "工作流不是可读取的 UTF-8 / base64 文件，或超过 512 KiB。") }
        let schema = try WorkflowInputSchema.read(yaml)
        var names: [String] = []
        if schema.inputs.contains(where: { $0.kind == .environment }) {
            struct Environments: Decodable { struct Item: Decodable { let name: String }; let total_count: Int; let environments: [Item] }
            for page in 1...100 {
                let bytes: Data
                do { bytes = try await workflowInputsEnvironments(repo, page: page) }
                catch { throw AppError(text: "无法完整读取 environment 选项；请检查 Environments: read 权限。\n" + error.localizedDescription) }
                let batch = try JSONDecoder().decode(Environments.self, from: bytes)
                guard batch.total_count >= 0 else { throw AppError(text: "无效的 environments 数量。") }
                names += batch.environments.map(\.name)
                if Set(names).count >= batch.total_count { break }
                guard !batch.environments.isEmpty, page < 100 else { throw AppError(text: "未能完整读取 environments，请重试。") }
            }
        }
        return .init(schema: schema, sha: content.sha, environments: Array(Set(names)).sorted())
    }

}
