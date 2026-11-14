import SwiftUI
import UIKit

enum SourceHighlighter {
    static let byteLimit = 128 * 1024
    static let supported = Set(["swift", "m", "mm", "h", "c", "cpp", "cc", "hpp", "js", "jsx", "ts", "tsx", "json", "py", "sh", "bash", "zsh", "yml", "yaml", "rb", "go", "rs", "java", "kt", "css", "sql"])
    static func highlight(_ text: String, filename: String, dark: Bool) -> NSAttributedString {
        let source = String(decoding: text.utf8.prefix(byteLimit), as: UTF8.self)
        let output = NSMutableAttributedString(string: source, attributes: [.foregroundColor: dark ? UIColor.white : UIColor.black])
        let ext = (filename as NSString).pathExtension.lowercased()
        guard supported.contains(ext) else { return output }
        let hashComments = ["py", "sh", "bash", "zsh", "yml", "yaml", "rb"].contains(ext)
        // One lexer pass: strings/comments consume their contents so keywords in
        // them are never recolored. All ranges refer to the same UTF-16 source.
        for token in SourceLexer.tokens(source, hashComments: hashComments) {
            let color: UIColor
            switch token.kind {
            case .string: color = dark ? .systemOrange : .systemRed
            case .comment: color = .systemGray
            case .keyword: color = .systemPurple
            case .number: color = .systemTeal
            }
            output.addAttribute(.foregroundColor, value: color, range: token.range)
        }
        return output
    }
}

struct SourceCodeView: View {
    let text: String
    let filename: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var highlighted: AttributedString?
    @State private var plain = false
    private var key: String { filename + ":" + (colorScheme == .dark ? "dark:" : "light:") + text }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("原始文本", isOn: $plain)
            if text.utf8.count > SourceHighlighter.byteLimit && !plain {
                Text("高亮预览前 128 KiB；切换原始文本可查看全部已加载内容。").font(.caption).foregroundStyle(.secondary)
            }
            if plain { Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            else if let highlighted {
                ScrollView(.horizontal) {
                    Text(highlighted).font(.system(.body, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                }
            } else { ProgressView("生成代码预览…") }
        }.task(id: key) {
            let source = text, name = filename, dark = colorScheme == .dark
            let value = await Task.detached(priority: .utility) { SourceHighlighter.highlight(source, filename: name, dark: dark) }.value
            guard !Task.isCancelled else { return }
            highlighted = AttributedString(value)
        }
    }
}
