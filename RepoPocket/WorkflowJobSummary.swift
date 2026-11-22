import Foundation

enum WorkflowJobSummaryRules {
    static let byteLimit = 4 * 1024 * 1024

    static func url(_ repo: String, run: Int) throws -> URL {
        guard run > 0 else { throw AppError(text: "无效运行编号。") }
        let repository = try RepositoryInput.parse(repo)
        return URL(string: "https://github.com/\(repository)/actions/runs/\(run)")!
    }

    // This is a best-effort public web format, not a documented Actions API.
    // Only real <job-summary> bodies qualify; logs/check output/page text do not.
    static func html(_ data: Data) throws -> String {
        guard data.count <= byteLimit, let page = String(data: data, encoding: .utf8), !page.contains("\0") else {
            throw AppError(text: "摘要页面过大或无法解析，请在 GitHub 查看。")
        }
        let summaries = try NSRegularExpression(pattern: "<job-summary\\b[^>]*\\bid=[\"'](summary-[0-9]+)[\"'][^>]*>([\\s\\S]*?)</job-summary\\s*>", options: .caseInsensitive)
        let heading = try NSRegularExpression(pattern: "<h2\\b[^>]*>[\\s\\S]*?</h2\\s*>", options: .caseInsensitive)
        var result: [String] = []
        for match in summaries.matches(in: page, range: NSRange(page.startIndex..., in: page)) {
            guard let id = Range(match.range(at: 1), in: page), let range = Range(match.range(at: 2), in: page) else { continue }
            let section = String(page[range])
            guard let body = try markdownBody(section) else { continue }
            let title = heading.firstMatch(in: section, range: NSRange(section.startIndex..., in: section))
                .flatMap { Range($0.range, in: section) }.map { String(section[$0]) } ?? ""
            result.append("<section id=\"\(page[id])\">" + title + body + "</section>")
        }
        guard !result.isEmpty else {
            throw AppError(text: "GitHub 未直接提供可读取的摘要，可能需要网页登录；请查看原始摘要。")
        }
        return result.joined(separator: "\n")
    }

    private static func markdownBody(_ section: String) throws -> String? {
        let tags = try NSRegularExpression(pattern: "<\\s*(/?)div\\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>", options: .caseInsensitive)
        let classes = try NSRegularExpression(pattern: "\\bclass\\s*=\\s*([\"'])(.*?)\\1", options: .caseInsensitive)
        var start: String.Index?, depth = 0
        for tag in tags.matches(in: section, range: NSRange(section.startIndex..., in: section)) {
            guard let range = Range(tag.range, in: section) else { continue }
            let closing = tag.range(at: 1).length > 0
            if let start {
                depth += closing ? -1 : 1
                if depth == 0 { return String(section[start..<range.lowerBound]) }
            } else if !closing {
                let value = String(section[range])
                if let attribute = classes.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                   let names = Range(attribute.range(at: 2), in: value),
                   value[names].split(whereSeparator: \.isWhitespace).contains("markdown-body") {
                    start = range.upperBound; depth = 1
                }
            }
        }
        return nil
    }
}

extension GitHub {
    func workflowJobSummary(_ repo: String, run: Int, publicSession: URLSession? = nil) async throws -> String {
        try Task.checkCancellation(); guard isCurrentSession else { throw CancellationError() }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false; config.timeoutIntervalForRequest = 30
        let session = publicSession ?? URLSession(configuration: config)
        defer { if publicSession == nil { session.invalidateAndCancel() } }
        // Never send API credentials or import browser cookies into a web request.
        var request = URLRequest(url: try WorkflowJobSummaryRules.url(repo, run: run))
        request.httpShouldHandleCookies = false
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("RepoPocket", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request, delegate: OfficialUpdateRedirectPolicy())
        try Task.checkCancellation(); guard isCurrentSession else { throw CancellationError() }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError(text: "无法直接读取摘要，请在 GitHub 查看或登录后重试。")
        }
        return try WorkflowJobSummaryRules.html(data)
    }
}
