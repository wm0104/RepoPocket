import SwiftUI
import MarkdownUI

struct OpenSourceNoticesView: View {
    @State private var text = "加载中…"
    var body: some View {
        ScrollView { Text(text).font(.caption).textSelection(.enabled).padding() }
            .navigationTitle("开源组件许可")
            .task {
                guard let url = Bundle.main.url(forResource: "OpenSourceLicenses", withExtension: "txt"),
                      let value = try? String(contentsOf: url, encoding: .utf8) else { text = "许可文件未找到，请查看项目 THIRD_PARTY_NOTICES.md。"; return }
                text = value
            }
    }
}

struct CommunityMarkdown: View {
    let text: String
    var baseURL: URL? = nil
    var imageBaseURL: URL? = nil
    var api: GitHub? = nil
    @State private var readingLink: ReadingLink?
    @State private var content: MarkdownContent?
    private var bounded: String { String(decoding: text.utf8.prefix(CommunityRules.markdownByteLimit), as: UTF8.self) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if text.utf8.count > CommunityRules.markdownByteLimit {
                Text("正文仅预览前 256 KiB，完整内容请在 GitHub 查看。").font(.caption).foregroundStyle(.secondary)
            }
            if let content {
                Markdown(content, baseURL: baseURL, imageBaseURL: imageBaseURL)
                    .markdownTheme(.gitHub)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard let safe = CommunityRules.webURL(url.absoluteString) else { return .discarded }
                        readingLink = ReadingLink(url: safe)
                        return .handled
                    })
            } else { ProgressView("排版中…") }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $readingLink) { ReadingLinkDestination(url: $0.url, api: api) }
        .task(id: text) {
            let source = bounded
            let parsed = await Task.detached(priority: .utility) { MarkdownContent(source) }.value
            guard !Task.isCancelled else { return }
            content = parsed
        }
    }
}

struct RepositoryReadmeView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let branch: String
    @State private var document: ReadmeDocument?
    @State private var entryPath = "README.md"
    @State private var resolved = ""
    @State private var error = ""
    @State private var revision = 0
    @State private var raw = false
    @State private var renderError = ""
    @State private var readingLink: ReadingLink?
    private var webBase: URL? {
        CommunityRules.readingBase(repo, branch: resolved, file: entryPath, raw: false)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let document {
                if document.source != nil { Toggle("查看原文", isOn: $raw) }
                if !renderError.isEmpty { Text(renderError).font(.caption).foregroundStyle(.secondary) }
                if !raw, renderError.isEmpty, let html = document.html {
                    ReadmeHTMLView(html: html, baseURL: webBase,
                        mediaBaseURL: CommunityRules.readingBase(repo, branch: resolved, file: entryPath, raw: true),
                        scrolling: true, height: .constant(0), onFailure: { renderError = $0 }) {
                        readingLink = ReadingLink(url: $0)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let source = document.source {
                    ScrollView { Text(source).font(.system(size: 16, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
            } else if error.isEmpty { ProgressView("加载自述文件…") }
            if !error.isEmpty { Text(error); Button("重试") { revision += 1 } }
            if !renderError.isEmpty { Button("重新加载排版") { revision += 1 } }
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle((entryPath as NSString).lastPathComponent).adaptiveWorkspaceLayout()
        .sheet(item: $readingLink) { ReadingLinkDestination(url: $0.url, api: api) }
        .toolbar { Button("刷新") { revision += 1 } }
        .task(id: revision) {
            error = ""; document = nil; raw = false; renderError = ""
            do {
                let selected = try await api.resolvedBranch(repo, branch: branch)
                let loaded = try await api.repositoryReadmeDocument(repo, branch: selected)
                try Task.checkCancellation(); guard api.isCurrentSession else { return }
                resolved = selected; entryPath = loaded.entry.path; document = loaded
            } catch {
                if api.isCurrentSession, !RefreshFailure.isCancellation(error) {
                    self.error = (error as? GitHubAPIError)?.status == 404 ? "此分支没有 README，或账号没有读取权限。" : error.localizedDescription
                }
            }
        }
    }
}

struct FileReadingView: View {
    let text: String
    let path: String
    let repo: String
    let branch: String
    var api: GitHub? = nil
    @State private var markdown = true
    private var isMarkdown: Bool { ["md", "markdown", "mdown"].contains((path as NSString).pathExtension.lowercased()) }
    var body: some View {
        Group {
          if !isMarkdown || !markdown { SourceCodeView(text: text, filename: path) }
          else { ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isMarkdown { Toggle("Markdown 排版", isOn: $markdown) }
                if isMarkdown && markdown {
                    CommunityMarkdown(text: text, baseURL: CommunityRules.readingBase(repo, branch: branch, file: path, raw: false),
                        imageBaseURL: CommunityRules.readingBase(repo, branch: branch, file: path, raw: true), api: api)
                }
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
          } }
        }.navigationTitle((path as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
    }
}
