import SwiftUI

struct WorkflowJobSummaryView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let run: Int
    var initialHTML: String? = nil
    @StateObject private var state = RepositoryPageLoadState<String>()
    @State private var revision = 0
    @State private var scale = 1.0
    @State private var renderError = ""
    @State private var readingLink: ReadingLink?
    @State private var showingLogin = false
    @State private var authenticatedSummary: (context: String, html: String)?
    private var summaryContext: String { repo + "\n" + String(run) + "\n" + api.accountID + "\n" + AccountStore.generation.uuidString }
    private var summaryHTML: String? {
        initialHTML ?? (authenticatedSummary?.context == summaryContext ? authenticatedSummary?.html : nil) ?? state.value
    }
    private var sourceURL: URL? { try? WorkflowJobSummaryRules.url(repo, run: run) }
    init(api: GitHub, repo: String, run: Int, initialHTML: String? = nil) {
        self.api = api; self.repo = repo; self.run = run; self.initialHTML = initialHTML
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if initialHTML == nil, args.contains("-style-preview"), args.contains("-workflow-selection-style-preview") {
            // Fixed native UI fixture; never fetch GitHub or pretend this is a live summary.
            self.initialHTML = """
            <h2>插件管理：查看清单</h2><p>本次处理完成。</p>
            <table><tr><th>上游仓库</th><th>插件名称</th><th>结果</th></tr>
            <tr><td>owngoal-dev/Apelin</td><td>Apelin Assembler</td><td>已登记</td></tr></table>
            <p><a href="https://github.com/wm0104/Apelin">查看来源</a></p>
            """
        }
        #endif
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let sourceURL {
                InAppLinkButton(url: sourceURL, api: nil) { Label("在 GitHub 查看原始摘要", systemImage: "safari") }
                    .disabled(!api.isCurrentSession).accessibilityIdentifier("workflow-summary-web")
            }
            if let html = summaryHTML, api.isCurrentSession, renderError.isEmpty {
                ContentZoomControls(scale: $scale).frame(maxWidth: .infinity, alignment: .trailing)
                ReadmeHTMLView(html: html, baseURL: sourceURL, scrolling: true, scale: scale, height: .constant(0),
                    onScaleChange: { scale = $0 }, onFailure: { renderError = $0 }) { readingLink = ReadingLink(url: $0) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("workflow-summary-content")
            } else {
                if state.loading { ProgressView("读取摘要…").accessibilityIdentifier("workflow-summary-loading") }
                if !state.error.isEmpty { Text(state.error).font(.callout).foregroundStyle(.secondary) }
                if !renderError.isEmpty { Text(renderError).font(.callout).foregroundStyle(.secondary) }
                if !state.error.isEmpty || !renderError.isEmpty {
                    if summaryHTML == nil {
                        Button("登录并读取摘要") { showingLogin = true }
                            .disabled(!api.isCurrentSession || api.login.isEmpty)
                            .accessibilityIdentifier("workflow-summary-login")
                        Text("网页登录只用于取得摘要，正文仍在本页排版阅读。临时登录不会与 Safari 共用，关闭登录页后不保留。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("重试") { refresh() }.disabled(!api.isCurrentSession)
                }
            }
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("摘要").navigationBarTitleDisplayMode(.inline).adaptiveWorkspaceLayout()
            .toolbar { Button("刷新") { refresh() }.disabled(!api.isCurrentSession) }
            .sheet(isPresented: $showingLogin) {
                let context = summaryContext
                WorkflowSummaryLoginView(api: api, repo: repo, run: run) { html in
                    guard context == summaryContext && api.isCurrentSession else { return }
                    authenticatedSummary = (context, html); renderError = ""; showingLogin = false
                }
                .id(context)
            }
            .onReceive(NotificationCenter.default.publisher(for: .githubAccountChanged)) { _ in
                authenticatedSummary = nil; showingLogin = false; readingLink = nil
            }
            .sheet(item: $readingLink) { ReadingLinkDestination(url: $0.url, api: api) { readingLink = nil } }
            .task(id: [repo, String(run), api.accountID, AccountStore.generation.uuidString, String(revision)]) {
                guard initialHTML == nil else { return }
                await state.load(key: repo + "\n" + String(run) + "\n" + AccountStore.generation.uuidString,
                    refresh: revision > 0, operation: { try await api.workflowJobSummary(repo, run: run) },
                    isValid: { api.isCurrentSession })
            }
    }

    private func refresh() {
        authenticatedSummary = nil; renderError = ""; revision += 1
    }
}
