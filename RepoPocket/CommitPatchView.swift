import SwiftUI

struct CommitPatchDestination: View {
    private let build: () -> AnyView
    init(file: DesktopCommit.File) { build = { AnyView(CommitPatchView(file: file)) } }
    var body: AnyView { build() }
}
struct CommitPatchView: View {
    let file: DesktopCommit.File
    @State private var result: CommitPatchResult?
    @State private var whitespace = true
    @State private var raw = false
    @State private var failure = ""
    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(file.filename).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                Text("仅显示本次提交的变化").font(.caption).padding(8)
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
                        ForEach(result.rows) { row in
                            HStack(alignment: .top, spacing: 6) {
                                Text(row.old.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundColor(.secondary)
                                Text(row.new.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundColor(.secondary)
                                Text(row.marker).frame(width: 10)
                                Text(CommitPatchParser.visible(row.text, whitespace: whitespace && [.context, .addition, .deletion].contains(row.kind)))
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
        .task {
            guard result == nil, let patch = file.patch else { return }
            let worker = Task.detached { try CommitPatchParser.parse(patch) }
            do {
                let parsed = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation(); result = parsed
            } catch { if !RefreshFailure.isCancellation(error) { failure = error.localizedDescription } }
        }
    }
}
