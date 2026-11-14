import Foundation

enum HomeListSearch {
    static func matches(_ query: String, fields: [String]) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(term) }
    }
}

enum CollaborationDraftRules {
    static func hasContent(number: Int?, title: String, text: String) -> Bool {
        if number == nil { return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum PersonalIssueFilter: String, CaseIterable, Identifiable {
    case involved, created, assigned, mentioned
    var id: String { rawValue }
    var title: String {
        switch self { case .involved: return "与我相关"; case .created: return "我创建的"; case .assigned: return "指派给我"; case .mentioned: return "提及我的" }
    }
    var qualifier: String {
        switch self { case .involved: return "involves"; case .created: return "author"; case .assigned: return "assignee"; case .mentioned: return "mentions" }
    }
}
enum PersonalIssueRules {
    static func query(login: String, filter: PersonalIssueFilter) throws -> String {
        guard !login.isEmpty, login.utf8.count <= 39,
              login.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
            throw AppError(text: "请先连接有效的 GitHub 账号。")
        }
        return "is:issue " + filter.qualifier + ":" + login
    }
    static func repository(_ item: CollaborationItem) -> String? {
        guard item.pull_request == nil, let url = URL(string: item.html_url), url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[2] == "issues", Int(parts[3]) == item.number, item.number > 0 else { return nil }
        return try? RepositoryInput.parse(parts[0] + "/" + parts[1])
    }
}
struct PersonalIssueSearchResponse: Decodable {
    let items: [CollaborationItem]
    let incomplete_results: Bool?
}

enum DiscussionComposerTarget: Identifiable {
    case comment, reply(CommentReplyContext)
    var id: String {
        switch self { case .comment: return "comment"; case .reply(let value): return "reply-\(value.id)" }
    }
    var replyContext: CommentReplyContext? {
        if case .reply(let value) = self { return value }; return nil
    }
}

struct CommentReplyContext: Identifiable {
    let id: Int
    let login: String?
    let body: String?
    let url: String?
    init(_ comment: CollaborationComment) {
        id = comment.id; login = comment.user?.login; body = comment.body; url = comment.html_url
    }
    init(id: Int, login: String?, body: String?, url: String?) {
        self.id = id; self.login = login; self.body = body; self.url = url
    }
    var author: String { login.map { "@" + $0 } ?? "已删除用户" }
    var quote: String {
        let own = (body ?? "").components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if own.isEmpty { return "（原评论没有独立文字内容）" }
        return String(own.prefix(8000)) + (own.count > 8000 ? "\n…（引用已截取）" : "")
    }
    func submission(_ text: String, repo: String, number: Int) throws -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, number > 0, id > 0 else { throw AppError(text: "请填写回复内容。") }
        let canonical = try RepositoryInput.parse(repo)
        let link = "https://github.com/" + canonical + "/issues/\(number)#issuecomment-\(id)"
        let quoted = quote.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        let result = "回复 " + author + " · [原评论](" + link + ")\n\n" + quoted + "\n\n" + clean
        guard result.utf8.count <= 60_000 else { throw AppError(text: "引用与回复合计不能超过60 KB，请缩短回复。") }
        return result
    }
}
