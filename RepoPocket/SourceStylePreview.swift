#if DEBUG
import SwiftUI
import UIKit
import ZIPFoundation

struct WorkflowLogStylePreview: View {
    @State private var expanded = false
    @State private var output: WorkflowStepOutput?
    @State private var failure = ""
    private let step = WorkflowJob.Step(number: 63, name: "Test build output", status: "completed", conclusion: "failure", started_at: "2026-10-17T00:00:00Z", completed_at: "2026-10-17T00:00:10Z")
    var body: some View {
        NavigationStack {
            List {
                Section("步骤") {
                    SoftGroupRows(animateBackground: false) {
                        SoftGroupRow("log") {
                            WorkflowStepRow(step: step, expanded: expanded, toggle: {
                                var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                                withTransaction(transaction) { expanded.toggle() }
                            }, output: AnyView(WorkflowInlineLog(output: output, loading: output == nil && failure.isEmpty,
                                error: failure, skipped: false, retry: {})))
                        }
                    }
                }.transaction { $0.animation = nil; $0.disablesAnimations = true }
            }.navigationTitle("步骤日志预览")
        }.task {
            guard output == nil, failure.isEmpty else { return }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                let bytes = Data("2026-10-17T00:00:01Z error: 中文构建失败详情\n2026-10-17T00:00:02Z 完整步骤输出已在 App 内显示\n".utf8)
                let archive = try Archive(url: file, accessMode: .create)
                try archive.addEntry(with: "build/63_Test build output.txt", type: .file, uncompressedSize: Int64(bytes.count)) { position, size in
                    bytes.subdata(in: Int(position)..<min(bytes.count, Int(position) + size))
                }
                output = try WorkflowLogArchiveRules.read(file, job: "build", steps: [63]).steps[63]
            } catch { failure = error.localizedDescription }
        }
    }
}

/// Exercises the shipping preview/editor. The probe only observes UIKit geometry.
struct SourceStylePreview: View {
    @State private var source = "message = \"" + String(repeating: "abcdefgh", count: 12) + "TAIL_MARKER\"\nprint(\"第二行\")\n# 第三行"
    @State private var editing = false
    @State private var revision = 0
    @State private var report = "待检查"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SourceCodeEditor(text: $source, filename: "长行示例.py", readOnly: !editing).id(editing)
                Divider()
                Button("检查代码布局") { revision += 1 }.padding(.vertical, 8)
                Text(report).font(.system(size: 8, design: .monospaced)).lineLimit(3)
                    .accessibilityIdentifier("source-layout-report")
                SourcePreviewProbe(revision: revision, report: $report).frame(height: 0)
            }
            .navigationTitle(editing ? "编辑横滑预览" : "代码横滑预览")
            .toolbar { Button(editing ? "切换到预览" : "切换到编辑") { editing.toggle() } }
        }
    }
}

private struct SourcePreviewProbe: UIViewRepresentable {
    let revision: Int
    @Binding var report: String
    final class Coordinator { var revision: Int? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        guard context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        DispatchQueue.main.async { report = Self.measure(in: view.window, revision: revision) }
    }
    private static func codeView(in view: UIView) -> UITextView? {
        if let text = view as? UITextView, text.accessibilityLabel == "代码正文" { return text }
        for child in view.subviews { if let found = codeView(in: child) { return found } }
        return nil
    }
    private static func measure(in window: UIWindow?, revision: Int) -> String {
        guard let window, let text = codeView(in: window), let horizontal = text.superview as? UIScrollView,
              let parent = horizontal.superview,
              let gutter = parent.subviews.first(where: { $0 !== horizontal }) else {
            return "revision=\(revision)|error=missing-code-surface"
        }
        text.layoutIfNeeded()
        let manager = text.layoutManager
        manager.ensureLayout(for: text.textContainer)
        let content = text.text as NSString
        let tail = content.range(of: "TAIL_MARKER")
        guard tail.location != NSNotFound else { return "revision=\(revision)|error=missing-tail" }
        let glyphs = manager.glyphRange(forCharacterRange: tail, actualCharacterRange: nil)
        let tailRect = manager.boundingRect(forGlyphRange: glyphs, in: text.textContainer)
            .offsetBy(dx: text.textContainerInset.left, dy: text.textContainerInset.top)
        let onScreenTail = text.convert(tailRect, to: window)
        let viewport = horizontal.convert(horizontal.bounds, to: window)
        let visible = viewport.contains(onScreenTail)
        var fragments = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, _, _ in fragments += 1 }
        let hardLines = content.components(separatedBy: "\n").count
        let gutterRect = gutter.convert(gutter.bounds, to: window)
        return "revision=\(revision)|editable=\(text.isEditable ? 1 : 0)|offset=\(Int(horizontal.contentOffset.x))|width=\(Int(horizontal.contentSize.width))|viewport=\(Int(horizontal.bounds.width))|tail=\(visible ? 1 : 0)|tailX=\(Int(onScreenTail.minX))|tailY=\(Int(onScreenTail.minY))|tailWidth=\(Int(onScreenTail.width.rounded(.up)))|tailHeight=\(Int(onScreenTail.height.rounded(.up)))|fragments=\(fragments)|hardLines=\(hardLines)|gutterX=\(Int(gutterRect.minX))|gutterWidth=\(Int(gutterRect.width))"
    }
}

struct PatchStylePreview: View {
    @State private var revision = 0
    @State private var report = "待检查"
    private var file: DesktopCommit.File {
        let prefix = String(repeating: "abcdefgh", count: 12)
        let patch = "@@ -1,2 +1,2 @@\n-message = \"" + prefix + "BEFORE_TAIL\"\n+message = \"" + prefix + "AFTER_TAIL\"\n print(\"第二行\")\n"
        return DesktopCommit.File(filename: "长行差异.py", previous_filename: nil, status: "modified", additions: 1, deletions: 1, patch: patch)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CommitPatchView(file: file)
                Divider()
                Button("检查代码布局") { revision += 1 }.padding(.vertical, 8)
                Text(report).font(.system(size: 8, design: .monospaced)).lineLimit(3)
                    .accessibilityIdentifier("source-layout-report")
                PatchPreviewProbe(revision: revision, report: $report).frame(height: 0)
            }
        }
    }
}

private struct PatchPreviewProbe: UIViewRepresentable {
    let revision: Int
    @Binding var report: String
    final class Coordinator { var revision: Int? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        guard context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let scrolls = Self.scrollViews(in: window).filter { $0.contentSize.width > $0.bounds.width + 20 }
            guard let scroll = scrolls.max(by: { $0.contentSize.width - $0.bounds.width < $1.contentSize.width - $1.bounds.width }) else {
                report = "revision=\(revision)|error=missing-horizontal-scroll"
                return
            }
            report = "revision=\(revision)|offset=\(Int(scroll.contentOffset.x))|width=\(Int(scroll.contentSize.width))|viewport=\(Int(scroll.bounds.width))"
        }
    }
    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        let own = (view as? UIScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap { scrollViews(in: $0) }
    }
}
#endif
