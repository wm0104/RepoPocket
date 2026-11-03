import SwiftUI
import UIKit

@MainActor
final class RepositoryCopyFeedback: ObservableObject {
    @Published private(set) var notice = RepositoryCopyNoticeState()
    private var timeout: Task<Void, Never>?

    // Called only by an explicit menu button action; never during view rendering.
    func copy(_ input: String) {
        guard let url = RepositoryLinkRules.canonicalURL(input) else { return }
        show(url)
    }

    /// Copy a URL already produced by RepositoryLinkRules; any other scheme or host is refused.
    func copy(url: URL?) {
        guard let url, url.scheme == "https", let host = url.host?.lowercased(),
              host == "github.com" || host == "raw.githubusercontent.com" else { return }
        show(url)
    }

    private func show(_ url: URL) {
        UIPasteboard.general.string = url.absoluteString
        timeout?.cancel()
        let token = notice.show()
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_500_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.notice.expire(token)
        }
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        notice.cancel()
    }
    deinit { timeout?.cancel() }
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

private struct RepositoryCopyNotice: ViewModifier {
    @ObservedObject var feedback: RepositoryCopyFeedback
    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if feedback.notice.visible {
                Text("已复制").font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8).allowsHitTesting(false)
                    .accessibilityLabel("仓库链接已复制")
            }
        }
        .onDisappear { feedback.cancel() }
    }
}

extension View {
    func repositoryCopyNotice(_ feedback: RepositoryCopyFeedback) -> some View {
        modifier(RepositoryCopyNotice(feedback: feedback))
    }
}
