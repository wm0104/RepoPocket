import SwiftUI
import UIKit

/// Full loaded context, not an error-only summary. Copy always uses the untouched original.
struct WorkflowLogReader: View {
    let rawText: String
    var failed = false
    @State private var showingRaw = false
    @State private var copied = false
    @State private var presentation: WorkflowLogPresentation?
    @State private var didAutoLocate = false
    @State private var selectedError: Int?
    @State private var revealRequest: SourceTextReveal?
    var body: some View {
        Group {
            if let presentation {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("错误 \(presentation.errorCount) · 警告 \(presentation.warningCount)")
                            .foregroundStyle(.secondary).accessibilityIdentifier("workflow-log-summary")
                        Spacer(minLength: 0)
                        Button { showingRaw.toggle() } label: {
                            Text(showingRaw ? "标注" : "原始").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        }
                            .accessibilityLabel(showingRaw ? "显示标注日志" : "显示原始日志")
                            .accessibilityValue(showingRaw ? "原始" : "标注")
                            .accessibilityIdentifier("workflow-log-toggle-raw")
                        Button {
                            UIPasteboard.general.string = presentation.rawText; copied = true
                        } label: {
                            Text(copied ? "已复制" : "复制原文").frame(minHeight: 44).contentShape(Rectangle())
                        }.accessibilityIdentifier("workflow-log-copy-raw")
                    }.font(.caption).buttonStyle(.borderless).frame(minHeight: 44).padding(.horizontal)
                    if !presentation.errorLocations.isEmpty {
                        HStack(spacing: 8) {
                            Button { moveError(-1, in: presentation) } label: {
                                Image(systemName: "chevron.up").frame(width: 44, height: 44).contentShape(Rectangle())
                            }.accessibilityLabel("上一处错误").accessibilityIdentifier("workflow-error-previous")
                            if let selectedError, presentation.errorLocations.indices.contains(selectedError) {
                                Text("第 \(presentation.errorLocations[selectedError].number) 行 · \(selectedError + 1)/\(presentation.errorLocations.count)")
                                    .monospacedDigit().accessibilityIdentifier("workflow-error-position")
                            } else {
                                Text("\(presentation.errorLocations.count) 处错误").accessibilityIdentifier("workflow-error-position")
                            }
                            Spacer(minLength: 0)
                            Button { moveError(1, in: presentation) } label: {
                                Image(systemName: "chevron.down").frame(width: 44, height: 44).contentShape(Rectangle())
                            }.accessibilityLabel("下一处错误").accessibilityIdentifier("workflow-error-next")
                        }.font(.caption).buttonStyle(.borderless).padding(.horizontal)
                    }
                    if presentation.onlyExitSummary {
                        Text("仅识别到退出状态，未定位到更具体的报错。").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    } else if failed && presentation.errorCount == 0 {
                        Text("未识别到明确错误行，可查找完整日志或切换原始查看。").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    }
                    SourceCodeView(text: showingRaw ? presentation.rawText : presentation.displayText, filename: "output.log",
                                   logLines: showingRaw ? [] : presentation.lines, revealRequest: revealRequest)
                }
            } else { ProgressView("准备日志显示…") }
        }.task(id: rawText) {
            copied = false
            let raw = rawText
            let worker = Task.detached(priority: .utility) { try WorkflowLogPresentation(rawText: raw) }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); presentation = value
                if let selectedError, !value.errorLocations.indices.contains(selectedError) { self.selectedError = nil }
                // Resolve initial positioning once; refreshed text must not take the reader away.
                if !didAutoLocate {
                    didAutoLocate = true
                    if failed, !value.errorLocations.isEmpty { navigate(to: 0, in: value) }
                }
            } catch {} // The projection only throws cancellation.
        }
    }
    private func moveError(_ direction: Int, in value: WorkflowLogPresentation) {
        let count = value.errorLocations.count
        guard count > 0 else { return }
        let start = selectedError ?? (direction > 0 ? -1 : 0)
        navigate(to: (start + direction + count) % count, in: value)
    }
    private func navigate(to index: Int, in value: WorkflowLogPresentation) {
        guard value.errorLocations.indices.contains(index) else { return }
        selectedError = index
        let line = value.errorLocations[index]
        let range = showingRaw ? line.rawRange : line.range
        revealRequest = SourceTextReveal(range: NSRange(location: range.location, length: 0))
    }
}
