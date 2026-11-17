import SwiftUI
import UIKit
import RepoPocketLanguageSupport
import RepoPocketThemeSupport

enum SourceHighlighter {
    // Parse the complete document, or stay plain; never parse a truncated prefix.
    static let byteLimit = 512 * 1024
    static func highlight(_ text: String, filename: String, dark: Bool) -> NSAttributedString {
        guard !text.isEmpty, !Task.isCancelled, text.utf8.count <= byteLimit,
              let language = SourceTextSyntax.language(for: filename, text: text) else {
            return NSAttributedString(string: text, attributes: [.foregroundColor: UIColor.label])
        }
        // The pinned source exposes StringSyntaxHighlighter; empty text must bypass its index-0 attributes access.
        // Keep the existing UITextView: its IME, undo, gutter and scrolling stay intact.
        let theme: Theme = dark ? OneDarkTheme() : TomorrowTheme()
        return StringSyntaxHighlighter(theme: theme, language: language).syntaxHighlight(text)
    }
}

struct SourceCodeView: View {
    let text: String
    let filename: String
    var logLines: [WorkflowLogPresentation.Line] = []
    var revealRequest: SourceTextReveal? = nil
    var body: some View { SourceCodeEditor(text: .constant(text), filename: filename, readOnly: true, logLines: logLines, revealRequest: revealRequest) }
}

/// The preview and editor use the same native text surface and language rules.
struct SourceCodeEditor: View {
    @Binding var text: String
    let filename: String
    var readOnly = false
    var logLines: [WorkflowLogPresentation.Line] = []
    var revealRequest: SourceTextReveal? = nil
    @State private var findRequest = 0
    @State private var scale = 1.0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(SourceLanguage.detect(filename).rawValue).font(.caption).foregroundStyle(.secondary)
                Spacer()
                ContentZoomControls(scale: $scale)
                Button { findRequest += 1 } label: { Image(systemName: "magnifyingglass").frame(minWidth: 44, minHeight: 24) }
                    .accessibilityLabel(readOnly ? "搜索当前文件" : "查找与替换")
            }.padding(.horizontal).padding(.vertical, 2)
            if text.utf8.count > SourceHighlighter.byteLimit {
                Text(readOnly ? "超过 512 KiB，已关闭语法解析，全文仍可查找。" : "超过 512 KiB，已关闭语法解析，全文仍可查找和编辑。").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            Divider()
            SourceTextSurface(text: $text, filename: filename, editable: !readOnly && isEnabled, dark: colorScheme == .dark, findRequest: findRequest, scale: scale, onScaleChange: { scale = $0 }, logLines: logLines, revealRequest: revealRequest)
        }.background(Color(uiColor: .systemBackground))
    }
}
