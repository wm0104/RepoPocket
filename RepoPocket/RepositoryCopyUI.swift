import SwiftUI
import UIKit

@MainActor
final class RepositoryCopyFeedback: ObservableObject {
    private let session = AccountStore.generation

    // Called only by an explicit menu button action; never during view rendering.
    func copy(_ input: String) {
        guard let url = RepositoryLinkRules.canonicalURL(input) else { return }
        copy(url: url, title: "仓库链接已复制")
    }

    /// Copy a URL already produced by RepositoryLinkRules; any other scheme or host is refused.
    func copy(url: URL?, title: String = "链接已复制") {
        guard session == AccountStore.generation,
              let url, url.scheme == "https", let host = url.host?.lowercased(),
              host == "github.com" || host == "raw.githubusercontent.com" else { return }
        UIPasteboard.general.string = url.absoluteString
        AppFeedback.show(title, session: session)
    }
}

struct CopyRepositoryLinkButton: View {
    let repository: String
    @ObservedObject var feedback: RepositoryCopyFeedback
    var body: some View {
        Button { feedback.copy(repository) } label: {
            Label("复制仓库链接", systemImage: "doc.on.doc")
        }
        .disabled(RepositoryLinkRules.canonicalURL(repository) == nil)
    }
}
