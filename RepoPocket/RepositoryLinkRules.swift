import Foundation

/// Root-only, trusted GitHub URL; never derive a link from a branch or directory.
enum RepositoryLinkRules {
    static func canonicalURL(_ input: String) -> URL? {
        guard let fullName = try? RepositoryInput.parse(input) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/" + fullName
        return components.url
    }

    /// File page, raw content, or folder page — always on the branch, never a commit. Folders have no raw form.
    static func contentURL(_ repo: String, branch: String, path: String, folder: Bool = false, raw: Bool = false) -> URL? {
        guard !(folder && raw), let fullName = try? RepositoryInput.parse(repo),
              let branch = encoded(branch), let path = encoded(path) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        if raw {
            components.host = "raw.githubusercontent.com"
            components.percentEncodedPath = "/" + fullName + "/" + branch + "/" + path
        } else {
            components.host = "github.com"
            components.percentEncodedPath = "/" + fullName + "/" + (folder ? "tree" : "blob") + "/" + branch + "/" + path
        }
        return components.url
    }

    /// Every component is percent-encoded on its own; separators come only from the input slashes.
    private static func encoded(_ value: String) -> String? {
        var pieces: [String] = []
        for piece in value.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            guard !piece.isEmpty, piece != ".", piece != "..",
                  !piece.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "%?#\\".unicodeScalars.contains($0) }),
                  let safe = piece.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else { return nil }
            pieces.append(safe)
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "/")
    }
}

/// Generation checks prevent an old timeout from clearing a newer copy notice.
struct RepositoryCopyNoticeState {
    private(set) var generation = UUID()
    private(set) var visible = false
    mutating func show() -> UUID {
        generation = UUID()
        visible = true
        return generation
    }
    mutating func expire(_ token: UUID) {
        guard token == generation else { return }
        visible = false
    }
    mutating func cancel() {
        generation = UUID()
        visible = false
    }
}
