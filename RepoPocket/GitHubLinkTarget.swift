import Foundation

/// Native screen for a github.com link tapped inside rendered markdown, instead of the web view.
enum GitHubLinkTarget: Equatable {
    case repository(owner: String, repo: String)
    case file(owner: String, repo: String, ref: String, path: String)
    case directory(owner: String, repo: String, ref: String, path: String)
    case issue(owner: String, repo: String, number: Int)
    case pull(owner: String, repo: String, number: Int)
    case commit(owner: String, repo: String, sha: String)
    case releases(owner: String, repo: String)
    case runs(owner: String, repo: String)

    var fullName: String {
        let names: (String, String)
        switch self {
        case let .repository(owner, repo), let .releases(owner, repo), let .runs(owner, repo):
            names = (owner, repo)
        case let .file(owner, repo, _, _), let .directory(owner, repo, _, _), let .commit(owner, repo, _),
             let .issue(owner, repo, _), let .pull(owner, repo, _):
            names = (owner, repo)
        }
        return names.0 + "/" + names.1
    }
}

/// Pure link rules: GitHub destinations stay native, other hosts and unusable URLs return nil.
enum GitHubLinkRules {
    static func isGitHub(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host == "www.github.com"
    }

    /// "owner/name" for links that start with a valid repository, nil otherwise.
    static func repositoryName(_ url: URL) -> String? {
        guard let parts = segments(url), parts.count >= 2,
              let full = try? RepositoryInput.parse(parts[0] + "/" + parts[1]) else { return nil }
        return full
    }

    /// Percent-decoded path segments; nil when the URL cannot be opened safely.
    /// The query and fragment never reach the path, so they are dropped; duplicate and
    /// trailing slashes are ignored, and decoded traversal segments are rejected.
    static func segments(_ url: URL) -> [String]? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, isGitHub(url) else {
            return nil
        }
        guard let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return nil }
        var parts: [String] = []
        for raw in encodedPath.split(separator: "/", omittingEmptySubsequences: false) {
            guard let decoded = String(raw).removingPercentEncoding else { return nil }
            if decoded.isEmpty { continue }
            guard decoded != ".", decoded != "..", !decoded.contains("/"), !decoded.contains("\\"),
                  decoded.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return nil }
            parts.append(decoded)
        }
        return parts
    }

    /// `branches` only matters for blob/tree links whose ref may contain slashes.
    static func target(_ url: URL, branches: [String] = []) -> GitHubLinkTarget? {
        guard let repo = repositoryName(url), let parts = segments(url) else { return nil }
        let names = repo.split(separator: "/").map(String.init)
        guard names.count == 2 else { return nil }
        let owner = names[0], name = names[1]
        let page = GitHubLinkTarget.repository(owner: owner, repo: name)
        let rest = Array(parts.dropFirst(2))
        guard let kind = rest.first else { return page }
        switch kind {
        case "blob", "tree":
            let remainder = Array(rest.dropFirst())
            guard !remainder.isEmpty else { return page }
            let resolved = resolveRef(remainder, branches: branches)
            if kind == "blob" {
                guard !resolved.path.isEmpty else { return page }
                return GitHubLinkTarget.file(owner: owner, repo: name, ref: resolved.ref, path: resolved.path)
            }
            return GitHubLinkTarget.directory(owner: owner, repo: name, ref: resolved.ref, path: resolved.path)
        case "issues", "pull":
            guard rest.count > 1, let number = Int(rest[1]), number > 0, String(number) == rest[1] else { return page }
            if kind == "issues" { return GitHubLinkTarget.issue(owner: owner, repo: name, number: number) }
            return GitHubLinkTarget.pull(owner: owner, repo: name, number: number)
        case "commit":
            guard rest.count > 1, isSHA(rest[1]) else { return page }
            return GitHubLinkTarget.commit(owner: owner, repo: name, sha: rest[1])
        case "releases":
            return GitHubLinkTarget.releases(owner: owner, repo: name)
        case "actions":
            // /actions and /actions/runs/<id> both open the native workflow runs screen.
            return GitHubLinkTarget.runs(owner: owner, repo: name)
        default:
            return page
        }
    }

    /// Longest leading run of segments that names a branch, else the first segment.
    static func resolveRef(_ segments: [String], branches: [String]) -> (ref: String, path: String) {
        guard !segments.isEmpty else { return ("", "") }
        var depth = 1
        for index in 1...segments.count where branches.contains(segments[0..<index].joined(separator: "/")) {
            depth = index
        }
        return (segments[0..<depth].joined(separator: "/"), segments.dropFirst(depth).joined(separator: "/"))
    }

    static func isSHA(_ text: String) -> Bool {
        (7...40).contains(text.count) && text.allSatisfy { $0.isHexDigit }
    }
}
