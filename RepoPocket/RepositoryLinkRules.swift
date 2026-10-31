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

    static func fileURL(_ repo: String, branch: String, path: String) -> URL? {
        link(host: "github.com", view: "blob", repo, branch: branch, path: path)
    }

    static func rawURL(_ repo: String, branch: String, path: String) -> URL? {
        link(host: "raw.githubusercontent.com", view: nil, repo, branch: branch, path: path)
    }

    static func directoryURL(_ repo: String, branch: String, path: String) -> URL? {
        link(host: "github.com", view: "tree", repo, branch: branch, path: path)
    }

    /// Mirrors the percent-encoding of the README reading bases so copied and in-app links agree.
    private static func link(host: String, view: String?, _ repo: String, branch: String, path: String) -> URL? {
        guard let canonical = try? RepositoryInput.parse(repo), !branch.isEmpty else { return nil }
        let encoded = path.split(separator: "/").map { component(String($0)) }.joined(separator: "/")
        guard !encoded.isEmpty else { return nil }
        let root = "https://" + host + "/" + canonical + "/" + (view.map { $0 + "/" } ?? "")
        return URL(string: root + component(branch) + "/" + encoded)
    }

    private static func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
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
