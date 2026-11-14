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
