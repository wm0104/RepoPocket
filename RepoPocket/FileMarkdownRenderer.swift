import Foundation

/// GitHub's own GFM renderer for a single markdown file.
///
/// Multi-language READMEs mix native HTML (`<div align="center">`, `<a><img></a>`) with
/// markdown. MarkdownUI shows those tags literally, so the file page asks GitHub to render
/// the text first and only falls back to the local renderer when this fails.
///
/// Lives in its own file so the byte-exact transport guards around `GitHub.swift` stay untouched.
enum FileMarkdownRenderer {
    static func html(_ source: String, repo: String) async throws -> String {
        guard let canonical = try? RepositoryInput.parse(repo) else {
            throw AppError(text: "仓库名无效")
        }
        let token = CredentialStore.read().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw AppError(text: "请先登录") }
        guard var components = URLComponents(string: "https://api.github.com/markdown") else {
            throw AppError(text: "渲染地址无效")
        }
        components.query = nil
        guard let url = components.url else { throw AppError(text: "渲染地址无效") }

        let text = String(decoding: source.utf8.prefix(CommunityRules.markdownByteLimit), as: UTF8.self)
        let body = try JSONSerialization.data(withJSONObject: ["text": text, "mode": "gfm", "context": canonical])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (bytes, response) = try await URLSession.shared.data(for: request, delegate: OfficialUpdateRedirectPolicy())
        guard let http = response as? HTTPURLResponse else { throw AppError(text: "无有效响应") }
        guard (200..<300).contains(http.statusCode) else {
            throw AppError(text: "HTTP \(http.statusCode)")
        }
        guard bytes.count <= 2 * 1024 * 1024 else { throw AppError(text: "渲染结果过大") }
        return String(decoding: bytes, as: UTF8.self)
    }
}
