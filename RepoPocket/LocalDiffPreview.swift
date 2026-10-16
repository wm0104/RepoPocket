import SwiftUI

struct LocalDiffPreview: View {
    let change: LocalChange
    @State private var fullText = false
    @State private var whitespace = true
    @State private var result: LocalDiffModel.Result?
    @State private var expanded: Set<Int> = []
    @State private var cursor = -1
    @State private var failure: String?
    private var before: String? { change.before ?? (change.kind == "新增" ? "" : nil) }
    private var after: String? { change.after ?? (change.kind == "删除" ? "" : nil) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(change.kind + " · " + change.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Picker("预览模式", selection: $fullText) {
                    Text("差异").tag(false)
                    Text("全文").tag(true)
                }.pickerStyle(.segmented)
                Toggle("显示空白 · ⇥ ↵", isOn: $whitespace).font(.subheadline)
                if !fullText, let result {
                    HStack {
                        Text("+\(result.additions)  −\(result.deletions)").foregroundStyle(.secondary)
                        if result.whitespaceOnly { Text("仅空白变化").foregroundStyle(.orange) }
                    }.font(.caption)
                    if result.degraded {
                        Text("已使用预算保护：大段变化按删除/新增展示，行内高亮可能简化。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding()
            Divider()
            if fullText { originalText }
            else if let result { diff(result) }
            else if let failure {
                VStack(spacing: 12) { Text(failure); Button("查看全文") { fullText = true } }.padding()
                Spacer()
            } else { ProgressView("正在计算差异…").padding(); Spacer() }
        }
        .navigationTitle("变更对照")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: change.id) {
            guard let before, let after else {
                failure = "一侧文本不可用（二进制、超过 64 KiB 或旧基线缺少文本），无法准确计算差异。"
                return
            }
            let worker = Task.detached(priority: .userInitiated) {
                try LocalDiffModel.compute(before: before, after: after)
            }
            do {
                let computed = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                result = computed
            } catch is CancellationError { } catch { failure = "差异计算失败，请查看全文。" }
        }
    }
    private var originalText: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 16) {
                Text("基线文本").font(.headline)
                Text(change.before ?? "（无文本基线：新增、二进制或超过 64 KiB）").fixedSize(horizontal: true, vertical: false)
                Divider()
                Text("当前文本").font(.headline)
                Text(change.after ?? "（无当前文本：已删除、二进制或超过 64 KiB）").fixedSize(horizontal: true, vertical: false)
            }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
    }
    private func diff(_ result: LocalDiffModel.Result) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if !result.changes.isEmpty {
                    HStack {
                        Button { jump(-1, result, proxy) } label: { Label("上一处", systemImage: "chevron.up") }
                        Spacer()
                        Text(cursor < 0 ? "\(result.changes.count) 处变更" : "\(cursor + 1) / \(result.changes.count)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { jump(1, result, proxy) } label: { Label("下一处", systemImage: "chevron.down") }
                    }.font(.caption).padding(.horizontal).padding(.vertical, 10)
                }
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if result.changes.isEmpty { Text("文本内容相同（或两侧均为空文件）").foregroundStyle(.secondary).padding() }
                        ForEach(result.entries) { entry in
                            switch entry {
                            case .row(let i): row(result.rows[i]).id(i)
                            case .gap(let range):
                                if expanded.contains(range.lowerBound) {
                                    Button("收起 \(range.count) 行未变化内容") { expanded.remove(range.lowerBound) }.font(.caption).padding()
                                    ForEach(range, id: \.self) { i in row(result.rows[i]).id(i) }
                                } else {
                                    Button { expanded.insert(range.lowerBound) } label: {
                                        Label("展开 \(range.count) 行未变化内容", systemImage: "ellipsis")
                                            .font(.caption).frame(maxWidth: .infinity).padding(.vertical, 14)
                                    }.background(Color.secondary.opacity(0.08))
                                }
                            }
                        }
                    }.fixedSize(horizontal: true, vertical: false).textSelection(.enabled)
                }
            }
        }
    }
    private func jump(_ direction: Int, _ result: LocalDiffModel.Result, _ proxy: ScrollViewProxy) {
        cursor = cursor < 0 ? (direction > 0 ? 0 : result.changes.count - 1)
            : (cursor + direction + result.changes.count) % result.changes.count
        withAnimation { proxy.scrollTo(result.changes[cursor], anchor: .topLeading) }
    }
    private func row(_ row: LocalDiffModel.Row) -> some View {
        let color: Color = row.kind == .addition ? .green : (row.kind == .deletion ? .red : .secondary)
        let marker = row.kind == .addition ? "+" : (row.kind == .deletion ? "−" : " ")
        return HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 1) {
                Text(row.oldNumber.map(String.init) ?? "–")
                Text(row.newNumber.map(String.init) ?? "–")
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(width: 32)
                .accessibilityLabel("旧行 \(row.oldNumber.map(String.init) ?? "无")，新行 \(row.newNumber.map(String.init) ?? "无")")
            Text(marker).foregroundColor(color).frame(width: 10)
            VStack(alignment: .leading, spacing: 2) {
                row.runs.reduce(Text("")) { text, run in
                    let displayed = LocalDiffModel.visible(run.text, whitespace: whitespace)
                    // Attributed background supplies stronger emphasis without altering the source.
                    var value = AttributedString(displayed)
                    if run.emphasized { value.backgroundColor = color.opacity(0.32); value.foregroundColor = .primary }
                    return text + Text(value)
                }.fixedSize(horizontal: true, vertical: false)
                if !row.raw.hasSuffix("\n") {
                    Text("无末尾换行").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }.font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(row.kind == .context ? Color.clear : color.opacity(0.12))
    }
}
