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
    var reader = false
    @State private var readingLink: ReadingLink?
    @State private var content: MarkdownContent?
    @State private var showReader = false
    @State private var scale = 1.0
    private var bounded: String { String(decoding: text.utf8.prefix(CommunityRules.markdownByteLimit), as: UTF8.self) }
    private var offersReading: Bool {
        bounded.count > 240 || bounded.contains("\n") || bounded.contains("|")
            || bounded.contains("```") || bounded.contains("~~~") || bounded.hasPrefix("    ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if reader { ContentZoomControls(scale: $scale).frame(maxWidth: .infinity, alignment: .trailing) }
            if !reader, offersReading {
                Button("放大阅读") { showReader = true }.font(.caption).buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
            }
            if text.utf8.count > CommunityRules.markdownByteLimit {
                Text("正文仅预览前 256 KiB，完整内容请在 GitHub 查看。").font(.caption).foregroundStyle(.secondary)
            }
            if let content {
                Markdown(content, baseURL: baseURL, imageBaseURL: imageBaseURL)
                    .markdownTheme(.gitHub)
                    .markdownTextStyle(\.text) { FontSize(16 * scale) }
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard let safe = CommunityRules.webURL(url.absoluteString) else { return .discarded }
                        readingLink = ReadingLink(url: safe)
                        return .handled
                    })
            } else { ProgressView("排版中…") }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $readingLink) { ReadingLinkDestination(url: $0.url, api: api) { readingLink = nil } }
        .sheet(isPresented: $showReader) {
            NavigationStack {
                ScrollView {
                    CommunityMarkdown(text: text, baseURL: baseURL, imageBaseURL: imageBaseURL, api: api, reader: true).padding()
                }.accessibilityIdentifier("community-markdown-reader")
                    .navigationTitle("正文").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showReader = false } } }
            }
        }
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
    @State private var scale = 1.0
    private var webBase: URL? {
        CommunityRules.readingBase(repo, branch: resolved, file: entryPath, raw: false)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let document {
                if document.source != nil { Toggle("查看原文", isOn: $raw) }
                if !renderError.isEmpty { Text(renderError).font(.caption).foregroundStyle(.secondary) }
                if !raw, renderError.isEmpty, let html = document.html {
                    ContentZoomControls(scale: $scale).frame(maxWidth: .infinity, alignment: .trailing)
                    ReadmeHTMLView(html: html, baseURL: webBase,
                        mediaBaseURL: CommunityRules.readingBase(repo, branch: resolved, file: entryPath, raw: true),
                        scrolling: true, scale: scale, height: .constant(0), onFailure: { renderError = $0 }) {
                        readingLink = ReadingLink(url: $0)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let source = document.source {
                    SourceCodeView(text: source, filename: entryPath)
                }
            } else if error.isEmpty { ProgressView("加载自述文件…") }
            if !error.isEmpty { Text(error); Button("重试") { revision += 1 } }
            if !renderError.isEmpty { Button("重新加载排版") { revision += 1 } }
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle((entryPath as NSString).lastPathComponent).adaptiveWorkspaceLayout()
        .sheet(item: $readingLink) { ReadingLinkDestination(url: $0.url, api: api) { readingLink = nil } }
        .toolbar { Button("刷新") { revision += 1 } }
        .task(id: [repo, branch, api.accountID, AccountStore.generation.uuidString, String(revision)]) {
            error = ""; document = nil; raw = false; renderError = ""
            do {
                let selected = try await api.resolvedBranch(repo, branch: branch)
                let loaded = try await api.repositoryReadmeDocument(repo, branch: selected)
                try Task.checkCancellation(); guard api.isCurrentSession else { return }
                resolved = selected; entryPath = loaded.entry.path; document = loaded
            } catch {
                if !Task.isCancelled, api.isCurrentSession, !RefreshFailure.isCancellation(error) {
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
    @State private var renderedKey: [String] = []
    @State private var renderedHTML: String?
    @State private var htmlAttempted = false
    @State private var readingLink: ReadingLink?
    @State private var scale = 1.0
    private var isMarkdown: Bool { ["md", "markdown", "mdown"].contains((path as NSString).pathExtension.lowercased()) }
    private var baseURL: URL? { CommunityRules.readingBase(repo, branch: branch, file: path, raw: false) }
    private var mediaBaseURL: URL? { CommunityRules.readingBase(repo, branch: branch, file: path, raw: true) }
    private var requestKey: [String] { [text, repo, branch, path, api?.accountID ?? "", api == nil ? "" : AccountStore.generation.uuidString] }
    var body: some View {
        VStack(spacing: 0) {
          if !isMarkdown { SourceCodeView(text: text, filename: path) }
          else if let renderedHTML, renderedKey == requestKey {
            // GitHub's renderer keeps native HTML such as centered headers and remote images.
            ContentZoomControls(scale: $scale).frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal)
            ReadmeHTMLView(html: renderedHTML, baseURL: baseURL, mediaBaseURL: mediaBaseURL, scrolling: true, scale: scale,
                           height: .constant(0), onFailure: { _ in
                               guard renderedKey == requestKey else { return }
                               self.renderedHTML = nil
                           }) { readingLink = ReadingLink(url: $0) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          else if renderedKey != requestKey || !htmlAttempted { ProgressView("排版中…").frame(maxWidth: .infinity, minHeight: 160) }
          else { ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                    CommunityMarkdown(text: text, baseURL: baseURL, imageBaseURL: mediaBaseURL, api: api, reader: true)
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
          } }
        }.id(requestKey).navigationTitle((path as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $readingLink) { ReadingLinkDestination(url: $0.url, api: api) { readingLink = nil } }
        .task(id: requestKey) {
            // Server-rendered HTML first; offline, signed out or on failure the local
            // MarkdownUI rendering below stays readable.
            renderedKey = requestKey; renderedHTML = nil; htmlAttempted = false
            defer { if !Task.isCancelled { htmlAttempted = true } }
            guard isMarkdown, let api, api.isCurrentSession,
                  let html = try? await api.renderedMarkdownHTML(text, repo: repo) else { return }
            guard !Task.isCancelled, api.isCurrentSession, !html.isEmpty else { return }
            renderedHTML = html
        }
    }
}
