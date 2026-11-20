import SwiftUI

#if DEBUG
import UIKit

/// Exercises the production feedback and ring without network or user-file writes.
struct DownloadCompletionStylePreview: View {
    @StateObject private var copyFeedback = RepositoryCopyFeedback()
    @State private var fraction = 0.35
    @State private var taps = 0
    @ObservedObject private var lifecycleObservation = AppFeedback.lifecycleObservation
    var body: some View {
        AppNavigationStack {
            List {
                Section {
                    HStack {
                        Text("RepoPocket.zip")
                        Spacer()
                        DownloadProgressRing(fraction: fraction, active: fraction < 1)
                            .accessibilityIdentifier("feedback-preview-ring")
                    }.frame(minHeight: 44).softGroupedRow(top: true)
                    Button("推进模拟下载") { fraction = fraction < 0.75 ? 0.75 : 1 }
                        .accessibilityIdentifier("feedback-preview-advance").softGroupedRow(bottom: true)
                }
                Section {
                    Button("模拟 ZIP 保存完成") { resetLifecycleEvidence(); AppFeedback.show("下载完成") }
                        .accessibilityIdentifier("feedback-preview-download").softGroupedRow(top: true)
                    Button("模拟仓库链接复制") { resetLifecycleEvidence(); copyFeedback.copy("wm0104/RepoPocket") }
                        .accessibilityIdentifier("feedback-preview-copy").softGroupedRow()
                    Button("模拟附件上传完成") { resetLifecycleEvidence(); AppFeedback.show("附件上传成功") }
                        .accessibilityIdentifier("feedback-preview-upload").softGroupedRow(bottom: true)
                }
                Section {
                    Button("点击计数：\(taps)") { taps += 1 }
                        .accessibilityIdentifier("feedback-through-button").softGroupedRow(top: true)
                    Button("模拟旧账号结果") { AppFeedback.show("不应显示的旧账号提示", session: UUID()) }
                        .accessibilityIdentifier("feedback-stale-button").softGroupedRow(bottom: true)
                }
            }.navigationTitle("成功轻提示预览")
        }
        .overlay(alignment: .bottom) {
            if AppFeedback.lifecycleTestEnabled {
                Text(lifecycleObservation.value).font(.caption2)
                    .accessibilityIdentifier("feedback-lifecycle-deactivation")
            }
        }
    }

    private func resetLifecycleEvidence() {
        guard AppFeedback.lifecycleTestEnabled else { return }
        lifecycleObservation.reset()
    }
}
#endif
