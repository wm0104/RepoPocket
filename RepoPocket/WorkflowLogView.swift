import SwiftUI
import UIKit

/// Full loaded context, not an error-only summary. Copy always uses the untouched original.
struct WorkflowLogReader: View {
    let rawText: String
    @State private var showingRaw = false
    @State private var copied = false
    @State private var presentation: WorkflowLogPresentation?
    var body: some View {
        Group {
            if let presentation, presentation.rawText == rawText {
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
                            UIPasteboard.general.string = rawText; copied = true
                        } label: {
                            Text(copied ? "已复制" : "复制原文").frame(minHeight: 44).contentShape(Rectangle())
                        }.accessibilityIdentifier("workflow-log-copy-raw")
                    }.font(.caption).buttonStyle(.borderless).frame(minHeight: 44).padding(.horizontal)
                    SourceCodeView(text: showingRaw ? rawText : presentation.displayText, filename: "output.log",
                                   logLines: showingRaw ? [] : presentation.lines)
                }
            } else { ProgressView("准备日志显示…") }
        }.task(id: rawText) {
            copied = false
            let raw = rawText
            let worker = Task.detached(priority: .utility) { try WorkflowLogPresentation(rawText: raw) }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); presentation = value
            } catch {} // The projection only throws cancellation.
        }
    }
}
