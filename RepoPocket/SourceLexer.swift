import Foundation

enum SourceTokenKind { case string, comment, keyword, number }
struct SourceToken { let range: NSRange; let kind: SourceTokenKind }
enum SourceLexer {
    static func tokens(_ source: String, hashComments: Bool) -> [SourceToken] {
        let strings = #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#
        // An unterminated block comment consumes to EOF instead of retrying
        // a failing suffix at every subsequent /* in an adversarial file.
        let comments = hashComments ? #"#[^\n]*"# : #"//[^\n]*|/\*[\s\S]*?(?:\*/|\z)"#
        let keywords = #"\b(?:actor|async|await|break|case|catch|class|const|continue|def|defer|delete|do|else|enum|export|extends|false|final|for|from|func|function|guard|if|import|in|init|interface|internal|let|nil|null|override|package|private|protocol|public|return|self|static|struct|super|switch|throw|throws|true|try|type|typeof|var|void|while|yield)\b"#
        let numbers = #"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#
        guard let regex = try? NSRegularExpression(pattern: "(" + strings + ")|(" + comments + ")|(" + keywords + ")|(" + numbers + ")") else { return [] }
        return regex.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length)).map { match in
            let kind: SourceTokenKind
            if match.range(at: 1).location != NSNotFound { kind = .string }
            else if match.range(at: 2).location != NSNotFound { kind = .comment }
            else if match.range(at: 3).location != NSNotFound { kind = .keyword }
            else { kind = .number }
            return SourceToken(range: match.range, kind: kind)
        }
    }
}
