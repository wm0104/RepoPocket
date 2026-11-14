import SwiftUI

enum ReadmePreviewRules {
    static let characterLimit = 1800
    static let lineLimit = 24
    static func preview(_ source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).prefix(lineLimit).joined(separator: "\n")
        return String(lines.prefix(characterLimit))
    }
    static func needsExpansion(_ source: String) -> Bool { preview(source) != source }
}

struct RepositoryReadmeSection: View {
    @ObservedObject var api: GitHub
    let repo: String
    let branch: String
    let canWrite: Bool
    @ObservedObject var state: RepositoryReadmeState
    private var document: ReadmeDocument? { state.value?.document }
    private var resolved: String { state.value?.branch ?? branch }
    private var requestKey: String { api.accountID + "\n" + AccountStore.generation.uuidString + "\n" + repo.lowercased() + "\n" + branch }
    var body: some View {
        Section {
            SoftGroupRows {
                SoftGroupRow("heading") {
                    HStack {
                        Label(document?.entry.name ?? "README", systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        if let entry = document?.entry, canWrite {
                            NavigationLink("编辑") { FileView(api: api, repo: repo, entry: entry, branch: resolved, canWrite: canWrite) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                if let document {
                    SoftGroupRow("body") {
                        ReadmeDocumentBody(document: document,
                            baseURL: CommunityRules.readingBase(repo, branch: resolved, file: document.entry.path, raw: false),
                            mediaBaseURL: CommunityRules.readingBase(repo, branch: resolved, file: document.entry.path, raw: true),
                            api: api, expanded: state.expanded, height: $state.bodyHeight)
                    }
                    if state.bodyHeight > ReadmeDocumentRules.collapsedHeight || ReadmePreviewRules.needsExpansion(document.source ?? "") {
                        SoftGroupRow("expand") { Button(state.expanded ? "收起自述文件" : "展开完整自述文件") { state.expanded.toggle() } }
                    }
                    if state.expanded && state.bodyHeight >= ReadmeDocumentRules.inlineHeightLimit {
                        SoftGroupRow("limit") { Text("正文较长，可使用全屏阅读继续查看。").font(.caption).foregroundStyle(.secondary) }
                    }
                    SoftGroupRow("reader") { NavigationLink("全屏阅读") { RepositoryReadmeView(api: api, repo: repo, branch: resolved) } }
                } else if state.error.isEmpty {
                    SoftGroupRow("loading") { ProgressView("加载自述文件…") }
                }
                if !state.error.isEmpty {
                    SoftGroupRow("error") { Text(state.error).font(.caption).foregroundStyle(.secondary) }
                }
                SoftGroupRow("refresh") {
                    Button(state.error.isEmpty ? "刷新自述文件" : "重新加载") { Task { await load(refresh: true) } }
                        .disabled(state.loading || branch.isEmpty)
                }
            }
        }.task(id: requestKey) { await load() }
    }
    private func load(refresh: Bool = false) async {
        guard !branch.isEmpty else { return } // Wait for the page to resolve its initial branch once.
        let api = api, repo = repo, branch = branch, generation = AccountStore.generation
        await state.load(key: requestKey, refresh: refresh, operation: {
            let document = try await api.repositoryReadmeDocument(repo, branch: branch)
            return RepositoryReadmeContent(branch: branch, document: document)
        }, isValid: { api.isCurrentSession && AccountStore.generation == generation }, errorText: {
            ($0 as? GitHubAPIError)?.status == 404 ? "此分支没有自述文件，或账号没有读取权限。" : $0.localizedDescription
        })
    }
}
