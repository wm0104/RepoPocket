import SwiftUI
import WebKit
import Combine

// BEGIN FOUNDATION RULES
enum WorkflowSummaryLoginRules {
    static func allowed(_ url: URL?) -> Bool {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "https" && parts.host?.lowercased() == "github.com"
            && parts.user == nil && parts.password == nil && (parts.port == nil || parts.port == 443)
    }

    static func current(_ captured: UUID, _ generation: UUID, session: Bool) -> Bool {
        captured == generation && session
    }

    static func summary(_ value: Any, expectedURL: URL, expectedLogin: String) throws -> String {
        guard let value = value as? [String: String], value["href"] == expectedURL.absoluteString else {
            throw AppError(text: "页面已变化，请返回本次运行后重新读取。")
        }
        let login = (value["login"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else { throw AppError(text: "请先在临时网页中登录 GitHub，再返回本次运行读取摘要。") }
        guard !expectedLogin.isEmpty else {
            throw AppError(text: "App 账号身份尚未就绪，请关闭并等待账号加载后重试。")
        }
        guard login.caseInsensitiveCompare(expectedLogin) == .orderedSame else {
            throw AppError(text: "网页账号与 App 账号不同。请在网页中退出，使用 App 的同一账号登录后重试。")
        }
        guard let html = value["html"], !html.isEmpty else {
            throw AppError(text: "尚未加载到摘要正文。请展开或等待摘要加载，再点“读取摘要”；也可返回本次运行重试。")
        }
        return try WorkflowJobSummaryRules.html(Data(html.utf8))
    }
}
// END FOUNDATION RULES

@MainActor
struct WorkflowSummaryLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: WorkflowSummaryLoginModel
    let onSummary: (String) -> Void

    init(api: GitHub, repo: String, run: Int, onSummary: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: WorkflowSummaryLoginModel(api: api, repo: repo, run: run))
        self.onSummary = onSummary
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 10) {
                Text("这是独立的临时网页登录，不会使用 App Token 或 Safari 登录状态。关闭后丢弃此会话；读取成功后返回原生摘要阅读页。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !model.expectedLogin.isEmpty {
                    Text("请登录 App 的同一账号：@\(model.expectedLogin)").font(.footnote)
                }
                HStack {
                    Button("读取摘要") { model.extract() }.disabled(!model.current || model.loading || model.extracting)
                    Spacer()
                    Button("返回本次运行") { model.returnToRun() }.disabled(!model.current)
                }
                if model.loading || model.extracting { ProgressView("加载 / 读取中…") }
                if !model.error.isEmpty { Text(model.error).font(.footnote).foregroundStyle(.secondary) }
                if model.active {
                    WorkflowSummaryLoginWeb(model: model)
                } else {
                    Text("临时会话已关闭，请取消后重新打开。")
                    Spacer()
                }
            }.padding()
                .navigationTitle("登录并读取摘要").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { model.close(); dismiss() }
                } }
        }
        .navigationViewStyle(.stack)
        .onChange(of: model.summary) { _ in
            guard let html = model.verifiedSummary() else { return }
            model.close()
            onSummary(html)
            dismiss()
        }
        .onDisappear { model.close() }
    }
}

@MainActor
private final class WorkflowSummaryLoginModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let api: GitHub
    let generation: UUID
    let expectedLogin: String
    let runURL: URL?
    @Published var active = true
    @Published var loading = false
    @Published var extracting = false
    @Published var error = ""
    @Published var summary: String?
    private weak var web: WKWebView?
    private var observer: AnyCancellable?
    private var navigationID = UUID()
    private var summaryNavigationID: UUID?

    func verifiedSummary() -> String? {
        guard current, summaryNavigationID == navigationID, let runURL, web?.url == runURL else { return nil }
        return summary
    }

    var current: Bool {
        active && WorkflowSummaryLoginRules.current(generation, AccountStore.generation, session: api.isCurrentSession)
    }

    init(api: GitHub, repo: String, run: Int) {
        self.api = api
        generation = AccountStore.generation
        expectedLogin = api.login.isEmpty ? (AccountStore.accounts.first { $0.id == api.accountID }?.login ?? "") : api.login
        runURL = try? WorkflowJobSummaryRules.url(repo, run: run)
        super.init()
        // Observe on the model, not view appearance: even an offscreen sheet must stop immediately.
        observer = NotificationCenter.default.publisher(for: .githubAccountChanged).sink { [weak self] _ in
            self?.close()
        }
        if runURL == nil { error = "无效仓库或运行编号。" }
    }

    func attach(_ web: WKWebView) {
        guard current else { close(); return }
        self.web = web
        web.navigationDelegate = self; web.uiDelegate = self
        returnToRun()
    }

    func close() {
        active = false; navigationID = UUID(); summary = nil
        loading = false; extracting = false
        web?.stopLoading(); web?.navigationDelegate = nil; web?.uiDelegate = nil
        web?.removeFromSuperview(); web = nil
        observer?.cancel(); observer = nil
    }

    func returnToRun() {
        guard current, let runURL, let web else { return }
        navigationID = UUID(); summary = nil; extracting = false; error = ""; loading = true
        // No API authentication or browser session is imported into this request.
        web.load(URLRequest(url: runURL))
    }

    func extract() {
        guard current, let web, let runURL, !loading, !extracting else { return }
        guard web.url == runURL else {
            error = "请完成登录，然后点“返回本次运行”读取摘要。"; return
        }
        let navigationID = self.navigationID
        extracting = true; error = ""
        web.evaluateJavaScript(Self.extractionScript, in: nil, in: .defaultClient) { [weak self, weak web] result in
            guard let self, let web, self.current, self.navigationID == navigationID else { return }
            self.extracting = false
            guard web.url == runURL else {
                self.error = "页面已变化，请返回本次运行后重新读取。"; return
            }
            do {
                let html = try WorkflowSummaryLoginRules.summary(result.get(), expectedURL: runURL, expectedLogin: self.expectedLogin)
                guard self.current, self.navigationID == navigationID, web.url == runURL else { return }
                self.summaryNavigationID = navigationID
                self.summary = html
            } catch {
                self.error = (error as? AppError)?.text ?? "无法读取摘要，请完成登录或等待正文加载后重试。"
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard current, WorkflowSummaryLoginRules.allowed(navigationAction.request.url) else {
            decisionHandler(.cancel)
            if current { error = "临时登录只允许 https://github.com 页面，不支持外部登录跳转。" }
            return
        }
        if navigationAction.targetFrame?.isMainFrame != false {
            navigationID = UUID(); summary = nil; extracting = false
        }
        // target=_blank is loaded in this same ephemeral view, never an external browser.
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel); webView.load(navigationAction.request); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard current, WorkflowSummaryLoginRules.allowed(navigationResponse.response.url) else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationID = UUID(); summary = nil; extracting = false
        guard current else { close(); return }
        loading = true; error = ""
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard current else { close(); return }
        loading = false
        if webView.url == runURL { extract() }
        else { error = "完成登录后，点“返回本次运行”；正文加载后可点“读取摘要”。" }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }
    private func failed(_ failure: Error) {
        guard current else { close(); return }
        navigationID = UUID(); loading = false; extracting = false
        if (failure as NSError).code != NSURLErrorCancelled { error = "网页加载失败，请点“返回本次运行”重试。" }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failed(NSError(domain: "WorkflowSummaryLogin", code: 1))
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard current, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    // App-owned code in an isolated world: never inspect login fields or return page HTML.
    static let extractionScript = #"""
    (() => {
        const login = document.querySelector('meta[name="user-login"]')?.content || '';
        const fragments = [];
        let length = 0;
        for (const node of document.querySelectorAll('job-summary[id]')) {
            if (!/^summary-[0-9]+$/.test(node.id)) continue;
            const body = node.querySelector('.markdown-body');
            if (!body || (!body.textContent.trim() && !body.querySelector('img,svg,video,audio,table,hr'))) continue;
            const html = node.outerHTML;
            length += html.length;
            if (length > 4 * 1024 * 1024) return { href: location.href, login, html: '' };
            fragments.push(html);
        }
        return { href: location.href, login, html: fragments.join('\n') };
    })()
    """#
}

@MainActor
private struct WorkflowSummaryLoginWeb: UIViewRepresentable {
    let model: WorkflowSummaryLoginModel
    func makeCoordinator() -> WorkflowSummaryLoginModel { model }
    func makeUIView(context: Context) -> UIView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.allowsLinkPreview = false
        // SwiftUI retains only the container, so close() can release WebKit even offscreen.
        let container = UIView()
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        model.attach(web)
        return container
    }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: WorkflowSummaryLoginModel) {
        coordinator.close()
    }
}
