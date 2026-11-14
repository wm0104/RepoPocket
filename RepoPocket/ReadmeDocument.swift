import Foundation

struct ReadmeDocument {
    let entry: Entry
    let source: String?
    let html: String?
}

enum ReadmeDocumentRules {
    static let sourceByteLimit = 1024 * 1024
    static let htmlByteLimit = 2 * 1024 * 1024
    static let collapsedHeight: CGFloat = 360
    static let inlineHeightLimit: CGFloat = 12_000
    // Fixed app-owned code runs in an isolated content world; README scripts stay disabled.
    static let heightObserver = """
    (() => {
      const article = document.getElementById('repopocket-readme');
      if (!article) return;
      let previousHeight;
      const publish = () => {
        const height = Math.ceil(article.getBoundingClientRect().height);
        if (!Number.isFinite(height) || height === previousHeight) return;
        previousHeight = height;
        window.webkit.messageHandlers.readmeSize.postMessage(height);
      };
      new ResizeObserver(publish).observe(article);
      publish();
    })();
    """

    static func source(_ entry: Entry) throws -> String {
        guard (entry.size ?? 0) <= sourceByteLimit, entry.encoding == "base64",
              let content = entry.content, let bytes = Data(base64Encoded: content, options: .ignoreUnknownCharacters),
              bytes.count <= sourceByteLimit else { throw AppError(text: "自述文件原文不可用或超过 1 MiB。") }
        let signature = Array(bytes.prefix(4))
        let encoding: String.Encoding
        if signature.starts(with: [0xff, 0xfe, 0, 0]) { encoding = .utf32LittleEndian }
        else if signature.starts(with: [0, 0, 0xfe, 0xff]) { encoding = .utf32BigEndian }
        else if signature.starts(with: [0xff, 0xfe]) { encoding = .utf16LittleEndian }
        else if signature.starts(with: [0xfe, 0xff]) { encoding = .utf16BigEndian }
        else { encoding = .utf8 }
        guard let decoded = String(data: bytes, encoding: encoding), !decoded.contains("\0") else {
            throw AppError(text: "此自述文件不是可解码文本；仍会尝试 GitHub 排版。")
        }
        return decoded.hasPrefix("\u{feff}") ? String(decoded.dropFirst()) : decoded
    }

    static func renderedHTML(_ bytes: Data) throws -> String {
        guard bytes.count <= htmlByteLimit, let html = String(data: bytes, encoding: .utf8), !html.contains("\0") else {
            throw AppError(text: "自述文件排版结果过大或无效。")
        }
        return html
    }

    static func isLocalAnchor(_ url: URL, base: URL?) -> Bool {
        guard url.fragment != nil, let base,
              var target = URLComponents(url: url, resolvingAgainstBaseURL: true),
              var origin = URLComponents(url: base, resolvingAgainstBaseURL: true) else { return false }
        target.fragment = nil; origin.fragment = nil
        return target.url == origin.url
    }

    // GitHub HTML can retain relative media paths or github.com/blob URLs. Resolve
    // media separately so document links still navigate through the GitHub reader.
    static func mediaURLs(_ fragment: String, base: URL?) -> String {
        guard let tags = try? NSRegularExpression(pattern: "<(?:img|source|video|audio)\\b(?:[^>\\\"']|\\\"[^\\\"]*\\\"|'[^']*')*>", options: .caseInsensitive),
              let attributes = try? NSRegularExpression(pattern: "(\\s([^\\s=/>]+)\\s*=\\s*)(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", options: .caseInsensitive) else { return fragment }
        func mediaURL(_ value: String) -> String {
            guard !value.isEmpty, let url = URL(string: value, relativeTo: base)?.absoluteURL else { return value }
            guard url.scheme == "https" else { return value }
            if url.host?.lowercased() == "github.com", var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) {
                var path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
                if path.count > 5, path[3] == "blob" || path[3] == "raw" {
                    path.remove(at: 3); parts.host = "raw.githubusercontent.com"
                    parts.percentEncodedPath = path.joined(separator: "/")
                    parts.queryItems = parts.queryItems?.filter { $0.name != "raw" }
                    if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
                    return parts.url?.absoluteString ?? value
                }
            }
            return url.absoluteString
        }
        var result = fragment
        for tagMatch in tags.matches(in: fragment, range: NSRange(fragment.startIndex..., in: fragment)).reversed() {
            guard let tagRange = Range(tagMatch.range, in: fragment) else { continue }
            let tag = String(fragment[tagRange]); var updated = tag
            for match in attributes.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)).reversed() {
                guard let nameRange = Range(match.range(at: 2), in: tag) else { continue }
                let name = tag[nameRange].lowercased()
                guard ["src", "srcset", "poster"].contains(name),
                      let valueIndex = (3...5).first(where: { match.range(at: $0).location != NSNotFound }),
                      let range = Range(match.range(at: valueIndex), in: tag) else { continue }
                let value = String(tag[range])
                let replacement: String
                if name == "srcset" {
                    // A data URL contains commas; leave such sets intact rather than corrupting it.
                    if value.lowercased().contains("data:") { continue }
                    replacement = value.components(separatedBy: ",").map { candidate in
                        let fields = candidate.split(whereSeparator: { $0.isWhitespace })
                        guard let first = fields.first else { return candidate }
                        return ([mediaURL(String(first))] + fields.dropFirst().map(String.init)).joined(separator: " ")
                    }.joined(separator: ", ")
                } else { replacement = mediaURL(value) }
                updated.replaceSubrange(range, with: replacement)
            }
            result.replaceSubrange(tagRange, with: updated)
        }
        return result
    }

    static func document(_ fragment: String, mediaBaseURL: URL? = nil) -> String {
        let fragment = mediaURLs(fragment, base: mediaBaseURL)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; media-src https: data:; style-src 'unsafe-inline'; script-src 'none'; frame-src 'none'; connect-src 'none'; base-uri 'none'; form-action 'none'">
        <style>
        :root { color-scheme: light dark; } * { box-sizing: border-box; }
        html, body { margin: 0; padding: 0; background: transparent; }
        #repopocket-readme { display: flow-root; }
        body { font: -apple-system-body; font-size: 16px; line-height: 1.5; overflow-wrap: anywhere; color: #1f2328; }
        h1 { font-size: 1.85em; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; }
        h1, h2 { border-bottom: 1px solid #d1d9e0; padding-bottom: .25em; }
        p, ul, ol, pre, blockquote, table { margin: 0 0 1em; } ul, ol { padding-left: 1.6em; }
        a { color: #0969da; text-decoration: none; } .anchor { display: none; }
        img, svg, video { max-width: 100%; height: auto; } img { vertical-align: middle; }
        pre { overflow: auto; white-space: pre; overflow-wrap: normal; word-break: normal; padding: 12px; background: #f6f8fa; border-radius: 8px; }
        code, pre { font-family: ui-monospace, Menlo, monospace; font-size: .88em; }
        table { display: block; overflow: auto; border-collapse: collapse; max-width: 100%; }
        td, th { padding: 6px 12px; border: 1px solid #d1d9e0; }
        blockquote { border-left: 3px solid #d1d9e0; padding-left: 1em; color: #59636e; }
        summary { cursor: pointer; } hr { border: 0; border-top: 1px solid #d1d9e0; }
        @media (prefers-color-scheme: dark) {
          body { color: #f0f3f6; } a { color: #58a6ff; } pre { background: #161b22; }
          td, th, h1, h2, blockquote, hr { border-color: #3d444d; } blockquote { color: #9198a1; }
        }
        </style></head><body><main id="repopocket-readme">\(fragment)</main></body></html>
        """
    }
}

extension GitHub {
    func repositoryReadmeDocument(_ repo: String, branch: String) async throws -> ReadmeDocument {
        let entry = try await repositoryReadme(repo, branch: branch)
        let source = (entry.size ?? 0) <= ReadmeDocumentRules.sourceByteLimit ? try? ReadmeDocumentRules.source(entry) : nil
        do {
            let html = try await communityReadmeHTML(repo, branch: branch)
            return ReadmeDocument(entry: entry, source: source, html: html)
        } catch {
            try Task.checkCancellation()
            guard isCurrentSession, !RefreshFailure.isCancellation(error) else { throw CancellationError() }
            guard source != nil else { throw error }
            return ReadmeDocument(entry: entry, source: source, html: nil)
        }
    }
}
