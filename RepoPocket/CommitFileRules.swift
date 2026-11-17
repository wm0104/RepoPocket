import Foundation

enum CommitFileRules {
    struct Failure: LocalizedError { let errorDescription: String? }
    static func validate(commitSHA: String, status: String) throws {
        guard commitSHA.utf8.count == 40, commitSHA.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else {
            throw Failure(errorDescription: "提交标识不完整，请返回重新加载提交详情。")
        }
        guard status != "removed", status != "deleted" else {
            throw Failure(errorDescription: "该文件已在此提交中删除，此版本没有完整文件；仍可返回查看删除差异。")
        }
    }
    static func decode(size: Int?, encoding: String?, content: String?) throws -> String {
        guard size == nil || (size! >= 0 && size! <= SourceTextRules.byteLimit) else {
            throw Failure(errorDescription: "此历史文件超过 1 MiB 阅读限制，未截断或加载其他版本。")
        }
        guard encoding == "base64", let content, content.utf8.count <= SourceTextRules.byteLimit * 2,
              let bytes = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
            throw Failure(errorDescription: "GitHub 未提供此版本的完整文本内容，未加载其他版本。")
        }
        return try SourceTextRules.decode(bytes)
    }
}
