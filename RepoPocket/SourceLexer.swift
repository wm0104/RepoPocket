import Foundation

enum SourceTokenKind: Equatable { case string, comment, keyword, number, builtin }
struct SourceToken { let range: NSRange; let kind: SourceTokenKind }
enum SourceLanguage: String, CaseIterable {
    case plain = "文本", python = "Python", swift = "Swift", javascript = "JavaScript", typescript = "TypeScript"
    case json = "JSON", shell = "Shell", ruby = "Ruby", go = "Go", rust = "Rust", java = "Java", kotlin = "Kotlin"
    case c = "C", cpp = "C++", objectiveC = "Objective-C", css = "CSS", sql = "SQL", yaml = "YAML", html = "HTML", toml = "TOML"
    static func detect(_ filename: String) -> SourceLanguage {
        let name = (filename as NSString).lastPathComponent.lowercased()
        if ["makefile", "dockerfile", ".bashrc", ".zshrc"].contains(name) { return .shell }
        switch (name as NSString).pathExtension {
        case "py", "pyw", "pyi": return .python
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx": return .typescript
        case "json", "jsonc": return .json
        case "sh", "bash", "zsh": return .shell
        case "rb", "rake": return .ruby
        case "go": return .go
        case "rs": return .rust
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "c", "h": return .c
        case "cpp", "cc", "cxx", "hpp": return .cpp
        case "m", "mm": return .objectiveC
        case "css", "scss", "less": return .css
        case "sql": return .sql
        case "yaml", "yml": return .yaml
        case "html", "htm", "xml", "plist", "svg": return .html
        case "toml": return .toml
        default: return .plain
        }
    }
    var keywords: String {
        switch self {
        case .python: return "False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case"
        case .swift: return "actor any as associatedtype async await break case catch class continue convenience default defer deinit didSet do else enum extension fallthrough false fileprivate final for func get guard if import in init inout internal is let mutating nil nonisolated open operator override private protocol public repeat required rethrows return self set some static struct subscript super switch throw throws true try typealias var weak where while willSet"
        case .javascript, .typescript: return "abstract any as async await boolean break case catch class const constructor continue debugger declare default delete do else enum export extends false finally for from function get if implements import in instanceof interface keyof let module namespace never new null number of package private protected public readonly return set static string super switch symbol this throw true try type typeof undefined unknown var void while with yield"
        case .json: return "true false null"
        case .shell: return "if then else elif fi for in do done while until case esac function select time export local readonly return break continue"
        case .ruby: return "BEGIN END alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield"
        case .go: return "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil"
        case .rust: return "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"
        case .java, .kotlin: return "abstract as assert boolean break byte case catch char class companion const continue data default do double else enum extends false final finally float for fun if implements import in instanceof int interface internal is lateinit long native new null object open override package private protected public return sealed short static super switch synchronized this throw throws transient true try val var void volatile when while"
        case .c, .cpp, .objectiveC: return "auto bool break case catch char class const constexpr continue default delete do double else enum explicit extern false float for friend goto if inline int long namespace new nil nullptr operator private protected public register return short signed sizeof static struct super switch template this throw true try typedef typename union unsigned using virtual void volatile while id self @interface @implementation @end @property @synthesize @protocol"
        case .css: return "important inherit initial unset none auto var calc rgb rgba flex grid block inline"
        case .sql: return "select from where and or not null true false as join left right inner outer on group by order asc desc limit offset having insert into values update set delete create table drop alter distinct union all exists case when then else end primary key references"
        case .yaml: return "true false null yes no on off"
        case .toml: return "true false"
        case .html, .plain: return ""
        }
    }
}

enum SourceTextRules {
    static let byteLimit = 1024 * 1024
    private static let binaryExtensions: Set<String> = ["png","jpg","jpeg","gif","heic","webp","ico","pdf","zip","gz","xz","7z","rar","tar","ipa","deb","dylib","so","a","o","exe","dll","mp4","mov","mp3","wav","woff","woff2","ttf","sqlite","db","pyc"]
    static func automaticallyLoads(filename: String, size: Int?) -> Bool {
        !binaryExtensions.contains((filename as NSString).pathExtension.lowercased()) && (size == nil || (size! >= 0 && size! <= byteLimit))
    }
    struct ReadError: LocalizedError {
        let errorDescription: String?
    }
    static func decode(_ bytes: Data) throws -> String {
        guard bytes.count <= byteLimit else { throw ReadError(errorDescription: "超过 1 MiB，请下载后使用其他工具打开。") }
        guard !bytes.contains(0), let value = String(data: bytes, encoding: .utf8) else {
            throw ReadError(errorDescription: "不是支持的 UTF-8 文本，可下载后使用对应应用打开。")
        }
        return value
    }
}

enum SourceLexer {
    private static let languageExpressions: [SourceLanguage: NSRegularExpression] = {
        var result: [SourceLanguage: NSRegularExpression] = [:]
        for language in SourceLanguage.allCases where language != .plain {
            var strings = #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#
            var comments = #"//[^\n]*|/\*[\s\S]*?(?:\*/|\z)"#
            if language == .python {
                strings = #"[rRuUbBfF]{0,2}(?:\x22{3}[\s\S]*?(?:\x22{3}|\z)|'{3}[\s\S]*?(?:'{3}|\z)|\"(?:\\.|[^\"\\\n])*\"|'(?:\\.|[^'\\\n])*')"#
            }
            if [.python,.shell,.ruby,.yaml,.toml].contains(language) { comments = #"#[^\n]*"# }
            if language == .sql { comments = #"--[^\n]*|/\*[\s\S]*?(?:\*/|\z)"# }
            if language == .html { comments = #"<!--[\s\S]*?(?:-->|\z)"# }
            if language == .json { comments = #"//[^\n]*|/\*[\s\S]*?(?:\*/|\z)"# }
            var keywords = language.keywords.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "|")
            keywords = keywords.isEmpty ? #"(?!)"# : #"\b(?:"# + keywords + #")\b"#
            if language == .sql { keywords = "(?i:" + keywords + ")" }
            if language == .html { keywords = #"</?[A-Za-z][A-Za-z0-9:-]*|/?>"# }
            let builtins = language == .python ? #"\b(?:print|len|range|enumerate|zip|list|dict|tuple|set|str|int|float|bool|bytes|open|input|super|isinstance|type|sum|min|max|sorted|abs)\b"# : #"(?!)"#
            let numbers = #"\b(?:0[xX][0-9a-fA-F]+|0[bB][01]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#
            result[language] = try? NSRegularExpression(pattern: "(" + strings + ")|(" + comments + ")|(" + keywords + ")|(" + numbers + ")|(" + builtins + ")")
        }
        return result
    }()
    static func tokens(_ source: String, filename: String) -> [SourceToken] {
        guard let regex = languageExpressions[SourceLanguage.detect(filename)] else { return [] }
        return regex.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length)).map { match in
            let kinds: [SourceTokenKind] = [.string,.comment,.keyword,.number,.builtin]
            let index = (1...5).first { match.range(at: $0).location != NSNotFound } ?? 1
            return SourceToken(range: match.range, kind: kinds[index - 1])
        }
    }
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
