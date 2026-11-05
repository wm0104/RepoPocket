#if DEBUG
import SwiftUI
import WebKit

struct ReadingZoomStylePreview: View {
    @State private var scale = 1.0
    @State private var loads = 0
    @State private var revision = 0
    @State private var report = "待检查"
    private let markdown = "# Markdown 正文\n\n这是一段用于正文缩放回归的文字。\n\n```swift\nlet value = \"" + String(repeating: "abcdefgh", count: 24) + "TAIL\"\n```\n\n| 左列 | 右列 |\n| --- | --- |\n| 表格正文 | 长内容验证 |\n"
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("HTML 正文") {
                    VStack(spacing: 0) {
                        ContentZoomControls(scale: $scale).frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal)
                        ReadmeHTMLView(html: "<p>ZOOM_SENTINEL</p><pre>" + String(repeating: "abcdefgh", count: 24) + "TAIL</pre>" + String(repeating: "<p>滚动正文，验证缩放不重新加载。</p>", count: 50), baseURL: nil,
                            scrolling: true, scale: scale, height: .constant(0), onReady: { loads += 1 }) { _ in }
                        Button("检查阅读布局") { revision += 1 }.frame(minHeight: 44)
                        Text("loads=\(loads)|" + report).font(.caption2).accessibilityIdentifier("reading-zoom-report")
                        ReadingZoomProbe(revision: revision, report: $report).frame(height: 0)
                    }.navigationTitle("HTML 正文").navigationBarTitleDisplayMode(.inline)
                }.softGroupedRow(top: true)
                NavigationLink("Markdown 正文") {
                    ScrollView { CommunityMarkdown(text: markdown).padding() }
                        .navigationTitle("Markdown 正文").navigationBarTitleDisplayMode(.inline)
                }.softGroupedRow(bottom: true)
            }.navigationTitle("阅读缩放")
        }
    }
}

private struct ReadingZoomProbe: UIViewRepresentable {
    let revision: Int
    @Binding var report: String
    final class Coordinator { var revision: Int? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        guard context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        DispatchQueue.main.async {
            guard let window = view.window, let web = Self.webView(in: window) else { return }
            report = "revision=\(revision)|zoom=\(web.pageZoom)|offset=\(web.scrollView.contentOffset.y)|height=\(web.scrollView.contentSize.height)"
        }
    }
    private static func webView(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { webView(in: $0) }.first
    }
}
#endif
