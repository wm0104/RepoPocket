import SwiftUI

struct CollaborationComposer: View {
    @ObservedObject var api: GitHub
    let repo: String
    let number: Int?
    var replyContext: CommentReplyContext? = nil
    let completed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var preview = false
    @State private var confirming = false
    @State private var busy = false
    @State private var error = ""
    private var action: CommunityMutation { number.map { .comment($0) } ?? .createIssue }
    private var submittedText: String {
        guard let replyContext, let number else { return text }
        return (try? replyContext.submission(text, repo: repo, number: number)) ?? ""
    }
    private var valid: Bool {
        CollaborationDraftRules.hasContent(number: number, title: title, text: text) &&
        (try? CommunityMutationRules.request(action, title: title, text: submittedText)) != nil
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SoftGroupRows {
                        SoftGroupRow("target") { Text(repo + (number.map { " #\($0)" } ?? "")).font(.caption) }
                        if let replyContext {
                            SoftGroupRow("reply-target") { ReplyQuoteView(context: replyContext) }
                        }
                        if number == nil { SoftGroupRow("title") { TextField("议题标题", text: $title).disabled(busy) } }
                        SoftGroupRow("body") { TextEditor(text: $text).frame(minHeight: 220).disabled(busy).accessibilityLabel("Markdown 正文") }
                        SoftGroupRow("preview-toggle") { Toggle("预览 Markdown", isOn: $preview) }
                        if preview { SoftGroupRow("preview") { CommunityMarkdown(text: submittedText, api: api) } }
                        if !error.isEmpty { SoftGroupRow("error") { Text(error).foregroundStyle(.red) } }
                        if busy { SoftGroupRow("busy") { ProgressView("提交中…") } }
                    }
                }
            }.navigationTitle(number == nil ? "新建议题" : (replyContext.map { "回复 " + $0.author } ?? "发表评论"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("发送") { confirming = true }.disabled(!valid || busy || !api.isCurrentSession) }
            }
            .confirmationDialog("确认发送到 \(repo)？", isPresented: $confirming, titleVisibility: .visible) {
                Button("确认发送") { Task { await submit() } }; Button("取消", role: .cancel) {}
            }
        }.interactiveDismissDisabled(busy)
    }
    private func submit() async {
        guard !busy, valid, api.isCurrentSession else { return }
        busy = true; error = ""; defer { busy = false }
        do {
            _ = try await api.communityMutate(repo, action: action, title: title, text: submittedText)
            try Task.checkCancellation(); guard api.isCurrentSession else { return }
            completed(); dismiss()
        } catch {
            if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription + "\n未收到成功确认时，请先刷新讨论核实，再决定是否重试。" }
        }
    }
}

private struct ReplyQuoteView: View {
    let context: CommentReplyContext
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("回复 " + context.author).font(.headline).accessibilityIdentifier("reply-recipient")
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.3)).frame(width: 3)
                Text(context.quote).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 4).frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true)
            Button(expanded ? "收起原评论" : "展开原评论") { expanded.toggle() }.font(.caption)
        }.padding(.vertical, 4)
    }
}
