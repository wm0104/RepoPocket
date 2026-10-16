import SwiftUI

struct CommitPatchDestination: View {
    private let build: () -> AnyView
    init(file: DesktopCommit.File, pullRequest: Bool = false) { build = { AnyView(CommitPatchView(file: file, pullRequest: pullRequest)) } }
    var body: AnyView { build() }
}
struct CommitPatchView: View {
    let file: DesktopCommit.File
    var pullRequest = false
    @State private var result: CommitPatchResult?
    @State private var whitespace = true
    @State private var raw = false
    @State private var failure = ""
    @State private var colored: [Int: AttributedString] = [:]
    @Environment(\.colorScheme) private var colorScheme
    private var renderKey: String { file.id + ":" + String(whitespace) + ":" + (colorScheme == .dark ? "dark" : "light") }
    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(file.filename).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                Text(pullRequest ? "显示此 PR 的文件变化" : "仅显示本次提交的变化").font(.caption).padding(8)
                Toggle("显示空白（· 空格 / ⇥ Tab）", isOn: $whitespace).padding(8)
                Toggle("原始 patch", isOn: $raw).padding(8)
                if file.patch == nil {
                    Text("二进制或大文件未提供 patch，无法预览；不代表没有改动。").padding(8)
                } else if let result {
                    if result.limited { Text("已达预览预算（1 MiB / 10,000行 / 单行8,192字）；仅显示部分内容。").foregroundColor(.orange).padding(8) }
                    if result.malformed { Text("部分 patch 位置不完整或格式异常；仅按可解析区块显示行号。").foregroundColor(.orange).padding(8) }
                    if raw {
                        Text(String(decoding: (file.patch ?? "").utf8.prefix(CommitPatchParser.byteLimit), as: UTF8.self))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(8)
                    } else {
                        ForEach(result.rows.filter { row in
                            raw || !(row.kind == .note && ["diff --git ", "index ", "--- ", "+++ "].contains(where: row.text.hasPrefix))
                        }) { row in
                            HStack(alignment: .top, spacing: 6) {
                                Text(row.old.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundColor(.secondary)
                                Text(row.new.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundColor(.secondary)
                                Text(row.marker).frame(width: 10)
                                Text(colored[row.id] ?? AttributedString(row.text))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
                            }.font(.system(.caption, design: .monospaced))
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(row.kind == .addition ? Color.green.opacity(0.12) : (row.kind == .deletion ? Color.red.opacity(0.12) : Color.clear))
                        }
                    }
                } else if failure.isEmpty { ProgressView("解析差异…").padding(8) }
                if !failure.isEmpty { Text(failure).padding(8) }
            }.frame(maxWidth: .infinity, alignment: .topLeading)
        }.navigationTitle((file.filename as NSString).lastPathComponent)
        .task(id: renderKey) {
            guard let patch = file.patch else { return }
            let name = file.filename, dark = colorScheme == .dark, spaces = whitespace
            let worker = Task.detached(priority: .utility) {
                let parsed = try CommitPatchParser.parse(patch)
                var colors: [Int: NSAttributedString] = [:]
                for row in parsed.rows {
                    try Task.checkCancellation()
                    let value = CommitPatchParser.visible(row.text, whitespace: spaces && [.context, .addition, .deletion].contains(row.kind))
                    colors[row.id] = [.context,.addition,.deletion].contains(row.kind)
                        ? SourceHighlighter.highlight(value, filename: name, dark: dark)
                        : NSAttributedString(string: value)
                }
                return (parsed, colors)
            }
            do {
                let (parsed, colors) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation(); result = parsed; colored = colors.mapValues { AttributedString($0) }
            } catch { if !RefreshFailure.isCancellation(error) { failure = error.localizedDescription } }
        }
    }
}
