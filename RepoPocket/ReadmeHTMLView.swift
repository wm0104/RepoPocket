import SwiftUI
import WebKit

/// The authenticated API response is rendered locally. Web content never gets the Token.
struct ReadmeHTMLView: UIViewRepresentable {
    let html: String
    let baseURL: URL?
    var mediaBaseURL: URL? = nil
    var scrolling = false
    @Binding var height: CGFloat
    var onFailure: (String) -> Void = { _ in }
    var onReady: () -> Void = {}
    let openLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        if !scrolling {
            configuration.userContentController.add(HeightHandler(context.coordinator), contentWorld: .defaultClient, name: "readmeSize")
            configuration.userContentController.addUserScript(WKUserScript(source: ReadmeDocumentRules.heightObserver,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = scrolling; web.allowsLinkPreview = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = context.coordinator
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        let identity = (baseURL?.absoluteString ?? "") + "\n" + (mediaBaseURL?.absoluteString ?? "") + "\n" + html
        guard context.coordinator.identity != identity else { return }
        context.coordinator.identity = identity
        web.loadHTMLString(ReadmeDocumentRules.document(html, mediaBaseURL: mediaBaseURL), baseURL: baseURL)
    }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "readmeSize", contentWorld: .defaultClient)
        web.configuration.userContentController.removeAllUserScripts()
        web.stopLoading(); web.navigationDelegate = nil
    }
    final class HeightHandler: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?
        init(_ coordinator: Coordinator) { self.coordinator = coordinator }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let number = message.body as? NSNumber,
                  number.doubleValue.isFinite, number.doubleValue >= 0 else { return }
            let measured = min(max(44, CGFloat(number.doubleValue.rounded(.up))), ReadmeDocumentRules.inlineHeightLimit)
            DispatchQueue.main.async { [weak coordinator = coordinator] in
                guard let coordinator, abs(coordinator.parent.height - measured) > 0.5 else { return }
                coordinator.parent.height = measured
            }
        }
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: ReadmeHTMLView
        var identity: String?
        init(_ parent: ReadmeHTMLView) { self.parent = parent }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.onReady() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.onFailure("自述文件排版进程已中断，请重新加载。")
        }
        private func failed(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            parent.onFailure("自述文件排版失败：" + error.localizedDescription)
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated || action.targetFrame == nil {
                if ReadmeDocumentRules.isLocalAnchor(url, base: parent.baseURL) { decisionHandler(.allow); return }
                decisionHandler(.cancel)
                if let safe = CommunityRules.webURL(url.absoluteString) { parent.openLink(safe) }
                return
            }
            decisionHandler(url.scheme == "about" || url == parent.baseURL ? .allow : .cancel)
        }
    }
}

struct ReadmeDocumentBody: View {
    let document: ReadmeDocument
    let baseURL: URL?
    var mediaBaseURL: URL? = nil
    var api: GitHub? = nil
    let expanded: Bool
    @Binding var height: CGFloat
    @State private var renderError = ""
    @State private var readingLink: ReadingLink?
    var body: some View {
        Group {
            if let html = document.html, renderError.isEmpty {
                ReadmeHTMLView(html: html, baseURL: baseURL, mediaBaseURL: mediaBaseURL, height: $height, onFailure: { renderError = $0 }) { readingLink = ReadingLink(url: $0) }
                    .frame(height: expanded ? height : min(height, ReadmeDocumentRules.collapsedHeight))
                    .clipped()
            } else if let source = document.source {
                VStack(alignment: .leading, spacing: 8) {
                    Text("排版暂不可用，已显示原文。").font(.caption).foregroundStyle(.secondary)
                    Text(expanded ? source : ReadmePreviewRules.preview(source)).font(.body).textSelection(.enabled)
                }
            } else if !renderError.isEmpty {
                Text(renderError).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: document.html) { _ in renderError = "" }
        .sheet(item: $readingLink) { ReadingLinkDestination(url: $0.url, api: api) { readingLink = nil } }
    }
}
