import Foundation

/// The only user-input repository parser. Never guess a target from a subpage URL.
enum RepositoryInput {
    struct Invalid: LocalizedError {
        var errorDescription: String? {
            "仓库链接应为 https://github.com/用户名/仓库名 或 用户名/仓库名；不支持子页面、其他站点及查询参数。"
        }
    }

    static func parse(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("%"), !text.contains("\\"),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Invalid()
        }
        var path = text
        if text.contains("://") {
            guard let url = URLComponents(string: text),
                  url.scheme?.lowercased() == "https", url.host?.lowercased() == "github.com",
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil,
                  url.percentEncodedPath.hasPrefix("/") else { throw Invalid() }
            path = String(url.percentEncodedPath.dropFirst())
        }
        if path.hasSuffix("/") { path.removeLast() }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { throw Invalid() }
        let owner = parts[0]
        var repository = parts[1]
        if repository.hasSuffix(".git") { repository.removeLast(4) }
        guard owner.count <= 39,
              owner.range(of: "^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$", options: .regularExpression) != nil,
              repository.count <= 100,
              repository.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              repository != ".", repository != "..", repository != ".git" else { throw Invalid() }
        return owner + "/" + repository
    }
}
