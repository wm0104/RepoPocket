#if DEBUG
import SwiftUI

/// Simulator-only fixed data: no credentials, no network or remote writes.
struct StylePreviewGallery: View {
    @StateObject private var api = GitHub()
    @State private var expanded = false
    @State private var readmeHeight: CGFloat = 320
    @State private var readmeOpened = false
    @State private var readmeReady = false
    private var account: Bool { ProcessInfo.processInfo.arguments.contains("-account-preview") }
    private var swipe: Bool { ProcessInfo.processInfo.arguments.contains("-swipe-style-preview") }
    private var workflow: Bool { ProcessInfo.processInfo.arguments.contains("-workflow-style-preview") }
    private var readme: Bool { ProcessInfo.processInfo.arguments.contains("-readme-style-preview") }
    private let sample = "# RepoPocket\n\n适用于 iOS 16 的 GitHub 客户端。\n\n- 原生代码浏览\n- Issue 与 PR\n- Actions 与发行版\n\n" + String(repeating: "支持在 App 内浏览与管理仓库。\n\n", count: 30)
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("-download-completion-style-preview") {
            DownloadCompletionStylePreview()
        } else if ProcessInfo.processInfo.arguments.contains("-release-download-style-preview") {
            ReleaseDownloadStylePreview()
        } else if ProcessInfo.processInfo.arguments.contains("-workflow-selection-style-preview") {
            WorkflowSelectionStylePreview()
        } else if ProcessInfo.processInfo.arguments.contains("-account-session-style-preview") {
            AccountSessionStylePreview()
        } else if ProcessInfo.processInfo.arguments.contains("-user-connections-style-preview") {
            UserConnectionsStylePreview()
        } else if ProcessInfo.processInfo.arguments.contains("-local-git-style-preview") {
            LocalGitStylePreview()
        } else if ProcessInfo.processInfo.arguments.contains("-source-style-preview") {
            SourceStylePreview()
        } else if ProcessInfo.processInfo.arguments.contains("-patch-style-preview") {
            PatchStylePreview()
        } else if ProcessInfo.processInfo.arguments.contains("-workflow-log-style-preview") {
            WorkflowLogStylePreview()
        } else {
            gallery
        }
    }
    private var gallery: some View {
        NavigationStack {
            List {
                if swipe {
                    Section("左滑边界检查 · 固定数据") {
                        ForEach(["first", "middle", "last"], id: \.self) { id in
                            Button("文件 · " + id) {}.accessibilityIdentifier("row-" + id)
                                .swipeActions { Button("删除", role: .destructive) {} }
                                .softGroupedRow(top: id == "first", bottom: id == "last")
                        }
                    }
                } else if readme {
                    Section("README.rst · 固定样式数据") {
                        ReadmeHTMLView(html: Self.readmeFixture, baseURL: URL(string: "https://github.com/wm0104/RepoPocket/blob/main/README.rst"), height: $readmeHeight, onReady: { readmeReady = true }) { _ in readmeOpened = true }
                            .frame(height: max(320, readmeHeight)).softGroupedRow(top: true, bottom: true)
                    }
                } else if workflow {
                    Section { WorkflowRunHeading(repo: "wm0104/RepoPocket", run: workflowRun).listRowBackground(Color.clear).listRowSeparator(.hidden) }
                    Section {
                        SoftGroupRows {
                            SoftGroupRow("metadata") { WorkflowRunMetadata(run: workflowRun) }
                            SoftGroupRow("metrics") { WorkflowRunMetrics(api: api, repo: "wm0104/RepoPocket", run: workflowRun, artifactCount: 2) }
                        }
                    }
                    Section("任务") { WorkflowJobRow(job: workflowJob).softGroupedRow(top: true, bottom: true) }
                    Section("步骤") {
                        ForEach(workflowJob.steps ?? []) { step in
                            WorkflowStepRow(step: step, expanded: expanded) { expanded.toggle() }
                                .softGroupedRow(top: true, bottom: true)
                        }
                    }
                } else if account {
                    Section("账号") {
                        HStack { Image(systemName: "person.crop.circle.fill").font(.largeTitle); Text("wm0104"); Spacer(); Image(systemName: "checkmark"); Image(systemName: "trash").foregroundStyle(.red) }.softGroupedRow(top: true, bottom: true)
                    }
                    Section {
                        SoftGroupRows {
                            SoftGroupRow("oauth") { NavigationLink("使用 GitHub 浏览器授权") { Text("授权页面") } }
                            SoftGroupRow("token") { NavigationLink("添加 / 更新 GitHub 账号") { Text("Token 页面") } }
                            SoftGroupRow("notice") { Text("仅移除本机凭据，不会删除 GitHub 账号、远端仓库或本地工作区。").font(.caption) }
                        }
                    }
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("wm0104").font(.subheadline).foregroundStyle(.secondary)
                            Text("RepoPocket").font(.headline)
                            Text("GitHub 仓库管理客户端").font(.subheadline).foregroundStyle(.secondary)
                            HStack { Label("13", systemImage: "star"); Label("1", systemImage: "tuningfork") }.font(.caption)
                        }.softGroupedRow(top: true, bottom: true)
                    }
                    RepositoryCommunitySection(api: api, repo: "wm0104/RepoPocket", branch: "main", avatar: nil)
                    Section {
                        SoftGroupRows {
                            SoftGroupRow("branch") { HStack { Label("main", systemImage: "arrow.triangle.branch"); Spacer(); Text("更改分支").foregroundStyle(.blue) } }
                            SoftGroupRow("code") { NavigationLink { Text("代码") } label: { RepositoryFeatureLabel(title: "代码", symbol: "chevron.left.forwardslash.chevron.right", color: .gray) } }
                            SoftGroupRow("history") { NavigationLink { Text("提交") } label: { RepositoryFeatureLabel(title: "提交", symbol: "clock.arrow.circlepath", color: .gray) } }
                        }
                    }
                    Section {
                        SoftGroupRows {
                            SoftGroupRow("heading") { Label("README.md", systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary) }
                            SoftGroupRow("body") { CommunityMarkdown(text: expanded ? sample : ReadmePreviewRules.preview(sample)) }
                            SoftGroupRow("expand") { Button(expanded ? "收起自述文件" : "展开完整自述文件") { expanded.toggle() } }
                        }
                    }
                }
            }.onAppear { if ProcessInfo.processInfo.arguments.contains("-expanded-style-preview") { expanded = true } }.navigationTitle(account ? "账号管理" : "RepoPocket").adaptiveWorkspaceLayout()
            .toolbar {
                if readme && readmeReady {
                    ToolbarItem(placement: .navigationBarLeading) { Text("页面就绪").accessibilityIdentifier("readme-document-ready") }
                }
                if readme && readmeOpened {
                    ToolbarItem(placement: .navigationBarTrailing) { Text("链接已处理").accessibilityIdentifier("readme-link-opened") }
                }
            }
        }
    }
    private static var readmeFixture: String {
        func badge(_ label: String) -> String {
            let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"160\" height=\"24\"><rect width=\"160\" height=\"24\" rx=\"4\" fill=\"#007aff\"/><text x=\"8\" y=\"17\" font-family=\"sans-serif\" font-size=\"12\" fill=\"white\">" + label + "</text></svg>"
            return "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
        }
        return """
        <h1>自述文件格式预览</h1>
        <p>固定数据示例：使用与正式自述文件相同的渲染组件。</p>
        <p><img alt="累计下载次数" src="\(badge("Downloads: 12345"))"> <img alt="最新版本" src="\(badge("Release: v1.0.5.1"))"></p>
        <table><tr><th>格式</th><th>展示</th></tr><tr><td>README.rst</td><td>GitHub 排版结果</td></tr><tr><td>README.txt</td><td>文本回退</td></tr></table>
        <details><summary>可折叠内容</summary><p>自述文件中的折叠说明。</p></details>
        <p><a href="https://github.com/wm0104/RepoPocket">在 App 内打开仓库</a></p>
        """
    }
    private var workflowRun: WorkflowRun {
        // Fixed fixture; never reaches GitHub or performs mutations.
        try! JSONDecoder().decode(WorkflowRun.self, from: Data(#"{"id":221,"name":"Build IPA","display_title":"统一分组样式与仓库主页","run_number":221,"head_sha":"38715a198627cc9372c458055f08ed7ed4ef0325","head_branch":"codex/github-client-features","status":"completed","conclusion":"success","created_at":"2026-10-15T00:00:00Z","run_started_at":"2026-10-15T00:00:00Z","updated_at":"2026-10-15T00:11:38Z","actor":{"login":"wm0104"},"event":"workflow_dispatch"}"#.utf8))
    }
    private var workflowJob: WorkflowJob {
        try! JSONDecoder().decode(WorkflowJob.self, from: Data(#"{"id":1,"name":"build","status":"completed","conclusion":"success","started_at":"2026-10-15T00:00:11Z","completed_at":"2026-10-15T00:11:38Z","steps":[{"number":1,"name":"编译 iOS App","status":"completed","conclusion":"success","started_at":"2026-10-15T00:00:11Z","completed_at":"2026-10-15T00:11:38Z"}]}"#.utf8))
    }
}
#endif
