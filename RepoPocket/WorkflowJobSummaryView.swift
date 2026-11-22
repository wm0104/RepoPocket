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
            if let html = initialHTML ?? state.value, api.isCurrentSession, renderError.isEmpty {
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
                    Button("重试") { renderError = ""; revision += 1 }.disabled(!api.isCurrentSession)
                }
            }
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("摘要").navigationBarTitleDisplayMode(.inline).adaptiveWorkspaceLayout()
            .toolbar { Button("刷新") { renderError = ""; revision += 1 }.disabled(!api.isCurrentSession) }
            .sheet(item: $readingLink) { ReadingLinkDestination(url: $0.url, api: api) { readingLink = nil } }
            .task(id: [repo, String(run), api.accountID, AccountStore.generation.uuidString, String(revision)]) {
                guard initialHTML == nil else { return }
                await state.load(key: repo + "\n" + String(run) + "\n" + AccountStore.generation.uuidString,
                    refresh: revision > 0, operation: { try await api.workflowJobSummary(repo, run: run) },
                    isValid: { api.isCurrentSession })
            }
    }
}
