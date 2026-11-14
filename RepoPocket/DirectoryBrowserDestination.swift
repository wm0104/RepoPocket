import SwiftUI

/// Erase only the recursive directory destination, not the browser or its rows.
/// The closure stores route inputs; BrowserView is built when SwiftUI evaluates
/// this destination's body. No loading task or additional navigation stack here.
///
/// iOS 16 eagerly instantiates a `NavigationLink { BrowserView(...) }` destination.
/// Since BrowserView itself embeds the same link for every subdirectory, that
/// eager instantiation recurses the whole BrowserView type graph up front and
/// blocks the main thread — the real-device freeze when browsing a repository
/// that contains directories. Isolating only the directory destination behind a
/// lazy closure stops the recursion while leaving file rows (which do not
/// recurse) on the plain closure form that always opens.
struct DirectoryBrowserDestination: View {
    private let build: () -> AnyView

    init(api: GitHub, repo: String, path: String, branch: String) {
        build = { AnyView(BrowserView(api: api, repo: repo, path: path, branch: branch)) }
    }

    var body: AnyView { build() }
}

struct RepositoryCodeDestination: View {
    private let build: () -> AnyView
    init(api: GitHub, repo: String, branch: String) {
        build = { AnyView(BrowserView(api: api, repo: repo, path: "", branch: branch, showFiles: true)) }
    }
    var body: AnyView { build() }
}
