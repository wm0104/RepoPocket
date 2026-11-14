import Foundation

extension Notification.Name {
    static let socialAccountsChanged = Notification.Name("RepoPocket.socialAccountsChanged")
}

enum UserConnectionKind: String, CaseIterable, Identifiable {
    case followers, following
    var id: String { rawValue }
    var title: String { self == .followers ? "关注者" : "正在关注" }
    var symbol: String { self == .followers ? "person.2" : "person.crop.circle.badge.checkmark" }
}

enum DiscussionStream: String, CaseIterable, Identifiable {
    case conversation, reviews, inline
    var id: String { rawValue }
    var title: String {
        switch self {
        case .conversation: return "讨论"
        case .reviews: return "审查"
        case .inline: return "行内评论"
        }
    }
}

enum CollaborationKind: String, CaseIterable, Identifiable {
    case issues, pulls
    var id: String { rawValue }
    var title: String { self == .issues ? "Issue" : "PR" }
}

struct CollaborationItem: Decodable, Identifiable {
    let id: Int
    let number: Int
    let title: String
    let state: String
    let body: String?
    let user: User?
    let html_url: String
    let comments: Int?
    let updated_at: String?
    let draft: Bool?
    let merged: Bool?
    let additions: Int?
    let deletions: Int?
    let changed_files: Int?
    let labels: [IssueLabel]?
    let pull_request: PullReference?
    let head: BranchReference?
    let base: BranchReference?
    struct PullReference: Decodable { let url: String? }
    struct BranchReference: Decodable { let ref: String; let sha: String? }
    struct IssueLabel: Decodable, Identifiable {
        let name: String
        var id: String { name }
    }
}

struct CollaborationComment: Decodable, Identifiable {
    let id: Int
    let body: String?
    let user: User?
    let created_at: String?
    let html_url: String?
    let path: String?
    let line: Int?
    let state: String?
}

struct CommunityProfile: Decodable {
    let login: String
    let type: String?
    let name: String?
    let avatar_url: String?
    let bio: String?
    let company: String?
    let location: String?
    let blog: String?
    let followers: Int?
    let following: Int?
    let public_repos: Int?
}

struct CommunitySocialAccount: Decodable, Identifiable {
    let provider: String
    let url: String
    var id: String { url }
    var title: String {
        if let platform = SocialPlatform.identify(url: url, provider: provider) { return platform.title }
        switch provider.lowercased() {
        case "mastodon": return "Mastodon"
        case "bluesky": return "Bluesky"
        case "twitter": return "X / Twitter"
        case "generic": return "社交链接"
        default: return provider.capitalized
        }
    }
}

enum SocialPlatform: String, CaseIterable {
    case telegram, x, mastodon, bluesky, threads, instagram, youtube, discord, tiktok, whatsapp, bilibili, github

    var title: String {
        switch self {
        case .telegram: return "Telegram"
        case .x: return "X / Twitter"
        case .mastodon: return "Mastodon"
        case .bluesky: return "Bluesky"
        case .threads: return "Threads"
        case .instagram: return "Instagram"
        case .youtube: return "YouTube"
        case .discord: return "Discord"
        case .tiktok: return "TikTok"
        case .whatsapp: return "WhatsApp"
        case .bilibili: return "哔哩哔哩"
        case .github: return "GitHub"
        }
    }

    static func identify(url: String, provider: String = "generic") -> SocialPlatform? {
        guard let host = CommunityRules.profileWebsiteURL(url)?.host?.lowercased() else { return nil }
        let domains: [(SocialPlatform, [String])] = [
            (.telegram, ["t.me", "telegram.me", "telegram.org"]),
            (.x, ["x.com", "twitter.com"]),
            (.mastodon, ["mastodon.social", "mastodon.online"]),
            (.bluesky, ["bsky.app", "bsky.social"]),
            (.threads, ["threads.net", "threads.com"]),
            (.instagram, ["instagram.com"]),
            (.youtube, ["youtube.com", "youtu.be"]),
            (.discord, ["discord.com", "discord.gg"]),
            (.tiktok, ["tiktok.com"]),
            (.whatsapp, ["whatsapp.com", "wa.me"]),
            (.bilibili, ["bilibili.com", "b23.tv"]),
            (.github, ["github.com"])
        ]
        for (platform, names) in domains {
            if names.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return platform }
        }
        // Federated Mastodon servers have no fixed hostname; GitHub supplies the provider.
        return provider.lowercased() == "mastodon" ? .mastodon : nil
    }
}

struct CommunityEvent: Decodable, Identifiable {
    let id: String
    let type: String
    let actor: Actor
    let repo: Repo
    let created_at: String?
    struct Actor: Decodable { let login: String; let avatar_url: String? }
    struct Repo: Decodable { let name: String }
    var summary: String {
        switch type {
        case "PushEvent": return "推送了提交"
        case "WatchEvent": return "加星了仓库"
        case "ForkEvent": return "复刻了仓库"
        case "IssuesEvent": return "更新了 Issue"
        case "IssueCommentEvent": return "参与了讨论"
        case "PullRequestEvent": return "更新了 PR"
        case "PullRequestReviewEvent": return "审查了 PR"
        case "CreateEvent": return "创建了分支、标签或仓库"
        case "ReleaseEvent": return "更新了发行版"
        default: return type
        }
    }
}

struct RepositoryContributor: Decodable, Identifiable {
    let login: String
    let avatar_url: String?
    let contributions: Int
    var id: String { login }
}

enum CommunityRules {
    static let pageSize = 30
    static let pageLimit = 10
    static let markdownByteLimit = 256 * 1024
    static func page(_ page: Int) throws -> [URLQueryItem] {
        guard (1...pageLimit).contains(page) else { throw AppError(text: "已达分页上限，请在 GitHub 查看更多。") }
        return [.init(name: "per_page", value: String(pageSize)), .init(name: "page", value: String(page))]
    }
    static func webURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func profileWebsiteURL(_ raw: String?) -> URL? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { return nil }
        // A bare domain can have a port; app schemes must not become web hosts.
        if !value.contains("://"), let scheme = URLComponents(string: value)?.scheme, !scheme.contains(".") { return nil }
        let candidate = value.hasPrefix("//") ? "https:" + value : (value.contains("://") ? value : "https://" + value)
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func repositoryURL(_ repo: String, suffix: String = "") -> URL? {
        guard let canonical = try? RepositoryInput.parse(repo) else { return nil }
        return URL(string: "https://github.com/" + canonical + suffix)
    }
    static func readingBase(_ repo: String, branch: String, file: String, raw: Bool) -> URL? {
        guard let canonical = try? RepositoryInput.parse(repo), !branch.isEmpty else { return nil }
        func component(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
        }
        let directory = (file as NSString).deletingLastPathComponent
        let path = directory.split(separator: "/").map { component(String($0)) }.joined(separator: "/")
        let root = raw ? "https://raw.githubusercontent.com/" + canonical + "/" : "https://github.com/" + canonical + "/blob/"
        let relative = raw ? (path.isEmpty ? "" : path + "/") : file.split(separator: "/").map { component(String($0)) }.joined(separator: "/")
        return URL(string: root + component(branch) + "/" + relative)
    }
    static func readmeText(_ entry: Entry) throws -> String {
        guard (entry.size ?? Int.max) <= markdownByteLimit, entry.encoding == "base64",
              let content = entry.content, let bytes = Data(base64Encoded: content, options: .ignoreUnknownCharacters),
              bytes.count <= markdownByteLimit, !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else {
            throw AppError(text: "README 超过 256 KiB 或不是 UTF-8 文本，请在 GitHub 查看。")
        }
        return text
    }
}

struct RepositorySocialUser: Decodable, Identifiable {
    let id: Int
    let login: String
    let avatar_url: String?
    var user: User { User(id: id, login: login, avatar_url: avatar_url, name: nil, followers: nil, following: nil) }
}
