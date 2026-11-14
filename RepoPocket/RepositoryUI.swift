import SwiftUI
import UIKit
import ImageIO

// Avatar requests are deliberately unauthenticated and restricted to GitHub's image host.
// Never follow redirects: even an allowed avatar host must not redirect to another host.
private final class AvatarRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Actor-isolated shared work survives row recycling; at most four downloads/decode jobs.
actor AvatarPipeline {
    static let shared = AvatarPipeline()
    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 192
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()
    private var pending: [URL: Task<UIImage?, Never>] = [:]
    private var pendingIDs: [URL: UUID] = [:]
    private var refreshGeneration: UUID?
    private var refreshTasks: [URL: Task<UIImage?, Never>] = [:]
    private let completedRefreshLimit = 192
    private var completedRefreshURLs: Set<URL> = []
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 20
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 24 * 1024 * 1024, diskPath: "RepoPocketAvatars")
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: AvatarRedirectPolicy(), delegateQueue: nil)
    }()
    func image(for url: URL, refreshID: UUID? = nil) async -> UIImage? {
        if let refreshID {
            if refreshGeneration != refreshID {
                refreshGeneration = refreshID
                refreshTasks.removeAll()
                completedRefreshURLs.removeAll()
            }
            if let task = refreshTasks[url] { return await task.value }
            if completedRefreshURLs.contains(url) { return cache.object(forKey: url as NSURL) }
        } else {
            if let image = cache.object(forKey: url as NSURL) { return image }
            if let task = pending[url] { return await task.value }
        }
        let previous = pending[url]
        let requestID = UUID()
        pendingIDs[url] = requestID
        let task = Task {
            // Serialize generations without cancelling shared work for recycled rows.
            if let previous { _ = await previous.value }
            let image = await self.fetch(url, revalidate: refreshID != nil)
            if let image { cache.setObject(image, forKey: url as NSURL, cost: 120 * 120 * 4) }
            if pendingIDs[url] == requestID {
                pending[url] = nil
                pendingIDs[url] = nil
            }
            if let refreshID, refreshGeneration == refreshID {
                // Keep only URL markers, never completed tasks/images outside NSCache.
                refreshTasks[url] = nil
                // Dedup is bounded to 192 completed URLs; evicted URLs may revalidate again.
                if completedRefreshURLs.count == completedRefreshLimit,
                   let evicted = completedRefreshURLs.first {
                    completedRefreshURLs.remove(evicted)
                }
                completedRefreshURLs.insert(url)
            }
            return image ?? cache.object(forKey: url as NSURL)
        }
        pending[url] = task
        if refreshID != nil { refreshTasks[url] = task }
        return await task.value
    }
    private func acquire() async {
        if active < 4 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().resume() }
    }
    private func fetch(_ url: URL, revalidate: Bool) async -> UIImage? {
        await acquire()
        defer { release() }
        do {
            let request = URLRequest(url: url, cachePolicy: revalidate ? .reloadRevalidatingCacheData : .useProtocolCachePolicy)
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  data.count <= 4 * 1024 * 1024 else { return nil }
            // Force thumbnail decoding off the main actor instead of lazy UIImage(data:).
            return await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 120,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: image)
            }.value
        } catch { return nil }
    }
}

@MainActor
final class AvatarLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    private var currentURL: URL?
    private var currentRefreshID: UUID?
    private var requestID = UUID()
    func load(_ raw: String?, refreshID: UUID? = nil) async {
        guard !Task.isCancelled else { return }
        let url = RepositoryPresentationRules.avatarURL(raw)
        if url == currentURL, image != nil, refreshID == currentRefreshID { return }
        if url != currentURL { image = nil }
        currentURL = url
        currentRefreshID = refreshID
        let requestID = UUID()
        self.requestID = requestID
        guard let url else { return }
        let decoded = await AvatarPipeline.shared.image(for: url, refreshID: refreshID)
        guard !Task.isCancelled, currentURL == url, self.requestID == requestID else { return }
        if let decoded { image = decoded }
    }
}

struct GitHubAvatar: View {
    let url: String?
    var size: CGFloat = 40
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var loader = AvatarLoader()
    @State private var refreshID: UUID?
    var body: some View {
        Group {
            if let image = loader.image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "person.crop.circle.fill").resizable().foregroundColor(.secondary) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: loader.image != nil)
        .task(id: [url, refreshID?.uuidString]) { await loader.load(url, refreshID: refreshID) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RepoPocket.avatarRefreshRequested"))) { notification in
            guard let token = notification.object as? UUID else { return }
            refreshID = token
        }
    }
}

struct RepositoryStatistics: View {
    let repository: Repository
    @Environment(\.repositorySocialAPI) private var socialAPI
    @State private var socialDestination: RepositorySocialDestination?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) { counts }.fixedSize(horizontal: true, vertical: false)
        }
        .lineLimit(1)
        .font(.caption)
        .monospacedDigit()
        .foregroundColor(.secondary)
        .sheet(item: $socialDestination) { destination in
            if let socialAPI { RepositorySocialView(api: socialAPI, repository: repository, destination: destination) }
        }
    }
    @ViewBuilder private var counts: some View {
        if let stars = repository.stargazers_count {
            if socialAPI != nil {
                Button { socialDestination = .stars } label: { Label("\(max(0, stars).formatted())", systemImage: "star") }.buttonStyle(.borderless).accessibilityLabel("查看 \(stars) 位星标用户")
            } else {
                Label("\(max(0, stars).formatted())", systemImage: "star").accessibilityLabel("\(stars) 个星标")
            }
        }
        if let forks = repository.forks_count {
            if socialAPI != nil {
                Button { socialDestination = .forks } label: { Label("\(forks.formatted())", systemImage: "tuningfork") }.buttonStyle(.borderless).accessibilityLabel("查看 \(forks) 个复刻仓库")
            } else {
                Label("\(forks.formatted())", systemImage: "tuningfork").accessibilityLabel("\(forks) 个派生仓库")
            }
        }
        if let language = RepositoryPresentationRules.language(repository.language) {
            Text(language).accessibilityLabel("语言：" + language)
        }
    }
}

/// The same compact summary is used by home, collections, search, user and browser.
struct RepositoryCard: View {
    let repository: Repository
    let account: String
    let api: GitHub
    var descriptionLineLimit: Int? = 2
    var copyLinkContextMenu = true
    var openOwner: (() -> Void)? = nil
    @StateObject private var copyFeedback = RepositoryCopyFeedback()
    @StateObject private var forkMenu = RepositoryForkMenuState()
    @State private var parent: RepositoryReference?
    @State private var showParent = false
    @State private var showOwnerProfile = false
    private var ownerProfile: User {
        let login = RepositoryPresentationRules.owner(login: repository.owner?.login, fullName: repository.full_name)
        return User(id: repository.owner?.id, login: login, avatar_url: repository.owner?.avatar_url, name: nil, followers: nil, following: nil)
    }
    var body: some View {
        CompactRepositorySummary(fullName: repository.full_name, name: repository.name,
            owner: repository.owner?.login, avatarURL: repository.owner?.avatar_url,
            description: repository.description, repository: repository, starStore: api.stars,
            descriptionLineLimit: descriptionLineLimit, parent: repository.fork == true ? (repository.parent ?? parent) : nil,
            openParent: { showParent = true }, openOwner: openOwner ?? { showOwnerProfile = true })
        .contextMenu {
            if copyLinkContextMenu {
                CopyRepositoryLinkButton(repository: repository.full_name, feedback: copyFeedback)
                ForkRepositoryMenuButton(repository: repository.full_name, api: api, state: forkMenu)
                RepositoryStarMenuButton(name: repository.full_name, repository: repository, api: api)
            }
        }
        .repositoryCopyNotice(copyFeedback)
        .repositoryForkConfirmation(forkMenu, api: api)
        .sheet(isPresented: $showOwnerProfile) {
            AppNavigationStack {
                UserRepositoriesView(api: api, user: ownerProfile)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showOwnerProfile = false } } }
            }.appSheetCornerRadius()
        }
        .task(id: repository.id) {
            let resolved = await api.forkParent(for: repository)
            guard !Task.isCancelled else { return }
            parent = resolved
        }
        .sheet(isPresented: $showParent) {
            if let source = repository.parent ?? parent {
                AppNavigationStack {
                    BrowserView(api: api, repo: source.full_name, path: "", branch: source.default_branch ?? "")
                        .toolbar { Button("关闭") { showParent = false } }
                }
            }
        }
    }
}

struct CompactRepositorySummary: View {
    let fullName: String
    let name: String
    var owner: String? = nil
    var avatarURL: String? = nil
    var description: String? = nil
    var repository: Repository? = nil
    var starStore: RepositoryStarStore? = nil
    var descriptionLineLimit: Int? = 2
    var parent: RepositoryReference? = nil
    var openParent: (() -> Void)? = nil
    var openOwner: (() -> Void)? = nil
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var body: some View {
        VStack(alignment: .leading, spacing: verticalSizeClass == .compact ? 4 : 6) {
            if let openOwner {
                Button(action: openOwner) { ownerIdentity.frame(minHeight: 44, alignment: .leading) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("查看作者 " + RepositoryPresentationRules.owner(login: owner, fullName: fullName) + " 的主页")
                    .accessibilityIdentifier("repository-owner-link")
            } else { ownerIdentity }
            Text(RepositoryPresentationRules.name(name, fullName: fullName))
                .font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let description, !description.isEmpty {
                Text(description).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(descriptionLineLimit).fixedSize(horizontal: false, vertical: true)
            }
            if let parent {
                Button { openParent?() } label: {
                    Text("复刻自 " + parent.full_name).font(.caption).lineLimit(1)
                }.buttonStyle(.borderless)
                .accessibilityLabel("浏览复刻来源 " + parent.full_name)
            }
            if let repository {
                if let starStore { StarAwareRepositoryStatistics(repository: repository, store: starStore) }
                else { RepositoryStatistics(repository: repository) }
            }
        }
        .padding(.vertical, verticalSizeClass == .compact ? 3 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: openOwner == nil ? .combine : .contain)
    }
    private var ownerIdentity: some View {
        HStack(spacing: 8) {
            GitHubAvatar(url: avatarURL, size: 24)
            Text(RepositoryPresentationRules.owner(login: owner, fullName: fullName))
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LoadingRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView("加载中…")
            ForEach(0..<3) { _ in
                HStack {
                    Circle().fill(Color.secondary.opacity(0.15)).frame(width: 36, height: 36)
                    VStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.10)).frame(width: 140, height: 10)
                    }
                }.accessibilityHidden(true)
            }
        }.padding(.vertical, 8)
    }
}
