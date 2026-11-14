import SwiftUI
import SafariServices

struct ReadingLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Every github.com link opens a native screen; only other hosts keep the in-app web page.
struct ReadingLinkDestination: View {
    let url: URL
    let api: GitHub?
    let onClose: () -> Void
    var body: some View {
        if let api, GitHubLinkRules.isGitHub(url) {
            NavigationStack {
                NativeLinkView(url: url, api: api, onClose: onClose)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("完成", action: onClose) }
                    }
            }
        } else {
            ContainedWebPage(url: url, onClose: onClose).ignoresSafeArea()
        }
    }
}

/// Resolves one GitHub link to a native screen; branch names are fetched once per sheet.
private struct NativeLinkView: View {
    let url: URL
    @ObservedObject var api: GitHub
    let onClose: () -> Void
    @State private var branches: [String]?
    private var needsBranches: Bool {
        guard let parts = GitHubLinkRules.segments(url), parts.count > 3 else { return false }
        return parts[2] == "blob" || parts[2] == "tree"
    }
    var body: some View {
        Group {
            if needsBranches && branches == nil {
                ProgressView("正在打开…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let target = GitHubLinkRules.target(url, branches: branches ?? []) {
                destination(target)
            } else {
                // Nothing native to resolve (github.com root, unsafe link): last resort stays web.
                ContainedWebPage(url: url, onClose: onClose).ignoresSafeArea()
            }
        }
        .task { await loadBranches() }
    }

    @ViewBuilder private func destination(_ target: GitHubLinkTarget) -> some View {
        let repo = target.fullName
        switch target {
        case .repository(_, _):
            BrowserView(api: api, repo: repo, path: "", branch: "")
        case let .file(_, _, ref, path):
            NativeLinkFileView(url: url, api: api, repo: repo, ref: ref, path: path)
        case let .directory(_, _, ref, path):
            BrowserView(api: api, repo: repo, path: path, branch: ref)
        case let .issue(_, _, number):
            CollaborationDetailView(api: api, repo: repo, kind: .issues, number: number)
        case let .pull(_, _, number):
            CollaborationDetailView(api: api, repo: repo, kind: .pulls, number: number)
        case let .commit(_, _, sha):
            CommitDetailView(api: api, repo: repo, sha: sha)
        case .releases(_, _):
            ReleaseListView(api: api, repo: repo)
        case .runs(_, _):
            WorkflowRunsView(api: api, repo: repo, branch: "")
        }
    }

    private func loadBranches() async {
        guard branches == nil, api.isCurrentSession, let repo = GitHubLinkRules.repositoryName(url) else { return }
        var names: [String] = []
        for page in 1...3 {
            guard let list = try? await api.branches(repo, page: page) else { break }
            names += list.map(\.name)
            if list.count < 100 { break }
        }
        branches = names
    }
}

/// Loads a linked blob so the existing file screen can render it.
private struct NativeLinkFileView: View {
    let url: URL
    @ObservedObject var api: GitHub
    let repo: String
    let ref: String
    let path: String
    @State private var entry: Entry?
    @State private var error = ""
    @State private var web = false
    var body: some View {
        Group {
            if web {
                ContainedWebPage(url: url, onClose: { web = false }).ignoresSafeArea()
            } else if let entry {
                FileView(api: api, repo: repo, entry: entry, branch: ref)
            } else if error.isEmpty {
                ProgressView("正在加载文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "doc").font(.largeTitle).foregroundStyle(.secondary)
                    Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("重试") { Task { await load() } }
                    Button("在 GitHub 网页打开") { web = true }
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle((path as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
        .task { if entry == nil && error.isEmpty { await load() } }
    }

    private func load() async {
        guard api.isCurrentSession else { return }
        error = ""
        do {
            let loaded = try await api.file(repo, path: path, branch: ref)
            guard loaded.type == "file" else { throw AppError(text: "此链接指向目录，请从仓库目录打开。") }
            entry = loaded
        } catch {
            if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription }
        }
    }
}

struct ContainedWebPage: UIViewControllerRepresentable {
    let url: URL
    let onClose: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onClose) }
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.barCollapsingEnabled = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        context.coordinator.onClose = onClose
    }
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        var onClose: () -> Void
        init(_ onClose: @escaping () -> Void) { self.onClose = onClose }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onClose()
        }
    }
}
