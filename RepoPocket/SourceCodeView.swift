import SwiftUI
import UIKit

enum SourceHighlighter {
    static let byteLimit = 128 * 1024
    static func highlight(_ text: String, filename: String, dark: Bool) -> NSAttributedString {
        let source = String(decoding: text.utf8.prefix(byteLimit), as: UTF8.self)
        // Highlight a bounded prefix without dropping the rest of the document.
        let output = NSMutableAttributedString(string: text, attributes: [.foregroundColor: dark ? UIColor.white : UIColor.black])
        for token in SourceLexer.tokens(source, filename: filename) {
            let color: UIColor
            switch token.kind {
            case .string: color = dark ? .systemOrange : .systemRed
            case .comment: color = .systemGray
            case .keyword: color = .systemPurple
            case .number: color = .systemBlue
            case .builtin: color = .systemIndigo
            }
            output.addAttribute(.foregroundColor, value: color, range: token.range)
        }
        return output
    }
}

struct SourceCodeView: View {
    let text: String
    let filename: String
    var body: some View { SourceCodeEditor(text: .constant(text), filename: filename, readOnly: true) }
}

/// The preview and editor use the same native text surface and language rules.
struct SourceCodeEditor: View {
    @Binding var text: String
    let filename: String
    var readOnly = false
    @State private var findRequest = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(SourceLanguage.detect(filename).rawValue).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { findRequest += 1 } label: { Image(systemName: "magnifyingglass").frame(minWidth: 44, minHeight: 24) }
                    .accessibilityLabel(readOnly ? "搜索当前文件" : "查找与替换")
            }.padding(.horizontal).padding(.vertical, 10)
            if text.utf8.count > SourceHighlighter.byteLimit {
                Text("前 128 KiB 使用语法高亮，其余内容显示原文。").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            Divider()
            SourceTextSurface(text: $text, filename: filename, editable: !readOnly && isEnabled, dark: colorScheme == .dark, findRequest: findRequest)
        }.background(Color(uiColor: .systemBackground))
    }
}
