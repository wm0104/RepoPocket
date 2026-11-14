import Foundation

enum GitCoreError: LocalizedError {
    case invalidRepository
    case unavailable
    var errorDescription: String? {
        switch self {
        case .invalidRepository: return "选择的目录不是有效的 Git 仓库。"
        case .unavailable: return "Git 内核尚未完成初始化。"
        }
    }
}

struct LocalGitRepository: Identifiable, Hashable {
    let url: URL
    var id: URL { url.standardizedFileURL }
    var name: String { url.lastPathComponent }
    var gitDirectory: URL { url.appendingPathComponent(".git", isDirectory: true) }
    var isValid: Bool { FileManager.default.fileExists(atPath: gitDirectory.path) }
}

/// Stable boundary for the native Git engine. libgit2 is attached behind this
/// actor in the next milestone; UI code should depend on this API only.
@MainActor
final class GitCore: ObservableObject {
    @Published private(set) var repositories: [LocalGitRepository] = []
    @Published private(set) var isBusy = false
    private var scopedURLs = Set<URL>()
    private let bookmarkKey = "RepoPocket.git.repository.bookmarks"

    init() {
        restoreBookmarks()
    }

    deinit {
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
    }

    func importRepository(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else { throw GitCoreError.invalidRepository }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
            url.stopAccessingSecurityScopedResource()
            throw GitCoreError.invalidRepository
        }
        if !repositories.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            repositories.append(LocalGitRepository(url: url))
            scopedURLs.insert(url)
            persistBookmarks()
        } else {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func remove(_ repository: LocalGitRepository) {
        repositories.removeAll { $0.id == repository.id }
        if let scoped = scopedURLs.first(where: { $0.standardizedFileURL == repository.url.standardizedFileURL }) {
            scoped.stopAccessingSecurityScopedResource()
            scopedURLs.remove(scoped)
        }
        persistBookmarks()
    }

    private func persistBookmarks() {
        // UIDocumentPicker grants security-scoped access on iOS, but
        // URL.BookmarkCreationOptions.withSecurityScope is macOS-only. An
        // ordinary bookmark still preserves the picked document URL on iOS;
        // access is restored with startAccessingSecurityScopedResource().
        let data = scopedURLs.compactMap { try? $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    private func restoreBookmarks() {
        let values = UserDefaults.standard.array(forKey: bookmarkKey) as? [Data] ?? []
        var restoredURLs = Set<URL>()
        for bookmark in values {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            guard url.startAccessingSecurityScopedResource() else { continue }
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
                url.stopAccessingSecurityScopedResource()
                continue
            }
            let normalizedURL = url.standardizedFileURL
            guard restoredURLs.insert(normalizedURL).inserted else {
                url.stopAccessingSecurityScopedResource()
                continue
            }
            repositories.append(LocalGitRepository(url: url))
            scopedURLs.insert(url)
        }
        // Rewrite once after the complete pass so an early stale/invalid
        // bookmark cannot erase valid bookmarks encountered later.
        if values.count != restoredURLs.count || values.contains(where: { bookmark in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return true }
            return stale
        }) {
            persistBookmarks()
        }
    }
}
