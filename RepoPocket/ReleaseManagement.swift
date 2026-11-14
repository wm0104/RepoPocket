import Foundation

// List decoding deliberately ignores embedded assets and body. Assets are fetched
// exclusively through the independent, budgeted assets endpoint on detail entry.
struct ManagedRelease: Decodable, Identifiable, Equatable {
    let id: Int
    let tag_name: String
    let name: String?
    let draft: Bool
    let prerelease: Bool
    let created_at: String
    let published_at: String?
    let updated_at: String
    let body: String?
    var title: String { name?.isEmpty == false ? name! : tag_name }
    var date: String { published_at ?? created_at }
}
struct ReleaseSummary: Decodable, Identifiable {
    let id: Int
    let tag_name: String
    let name: String?
    let draft: Bool
    let prerelease: Bool
    let created_at: String
    let published_at: String?
    var title: String { name?.isEmpty == false ? name! : tag_name }
    var date: String { published_at ?? created_at }
}
enum ReleaseMarker: String, CaseIterable, Identifiable {
    case none, prerelease, latest
    var id: String { rawValue }
    var title: String {
        switch self { case .none: return "无"; case .prerelease: return "预发行版"; case .latest: return "最新发行版" }
    }
}
struct ManagedReleaseHTTPError: LocalizedError {
    let status: Int
    let tagAlreadyExists: Bool
    var errorDescription: String? { "发行版不存在或当前账号无权访问（HTTP \(status)）。" }
}
struct ReleaseForm {
    var title = ""
    var tag = ""
    var body = ""
    var branch = ""
    var draft = false
    var marker: ReleaseMarker = .none
    var initialLatestID: Int?
    var prerelease: Bool { marker == .prerelease }
    var makeLatest: String { marker == .latest ? "true" : "false" }
    var validMarker: Bool { !(draft && marker == .latest) }
    init() {}
    init(_ release: ManagedRelease, latestID: Int? = nil) {
        title = release.name ?? ""; tag = release.tag_name; body = release.body ?? ""
        draft = release.draft; initialLatestID = latestID
        marker = release.prerelease ? .prerelease : (!release.draft && latestID == release.id ? .latest : .none)
    }
}
enum ReleaseManagementRules {
    static let pageSize = 20
    static let pageLimit = 50 // Explicit user-driven budget: at most 1,000 rows.
    static let jsonLimit = 8 * 1024 * 1024
    static let displayBodyLimit = 16_384
    static let editBodyLimit = 131_072
    static let assetLimit: Int64 = 2 * 1024 * 1024 * 1024
    static func validTag(_ tag: String) -> Bool {
        guard !tag.isEmpty, tag != "@", !tag.contains(".."), !tag.contains("@{"),
              !tag.hasSuffix("."), !tag.unicodeScalars.contains(where: {
                  $0.value <= 32 || $0.value == 127 || CharacterSet.whitespacesAndNewlines.contains($0) || "~^:?*[\\".unicodeScalars.contains($0)
              }) else { return false }
        return tag.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
        }
    }
    static func tagAlreadyExists(_ data: Data) -> Bool {
        struct Failure: Decodable {
            struct Detail: Decodable { let field: String?; let code: String? }
            let errors: [Detail]?
        }
        return (try? JSONDecoder().decode(Failure.self, from: data).errors?.contains {
            $0.field == "tag_name" && $0.code == "already_exists"
        }) == true
    }
    static func canWrite(_ push: Bool?, session: Bool) -> Bool { push == true && session }
    static func validPage(_ page: Int) -> Bool { (1...pageLimit).contains(page) }
    static func more(count: Int, page: Int) -> Bool { count == pageSize && page < pageLimit }
    static func merged<T: Identifiable>(_ current: [T], _ incoming: [T]) -> [T] where T.ID: Hashable {
        var seen = Set(current.map(\.id))
        return current + incoming.filter { seen.insert($0.id).inserted }
    }
    static func editable(_ body: String) -> Bool { body.utf8.count <= editBodyLimit }
    static func validAsset(size: Int64, name: String) -> Bool {
        size > 0 && size < assetLimit && !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.contains("\n") && name != "." && name != ".."
    }
    static func browserDownloadURL(_ raw: String, repo: String) -> URL? {
        guard let c = URLComponents(string: raw), c.scheme == "https", c.host == "github.com",
              c.user == nil, c.password == nil, c.port == nil, c.query == nil, c.fragment == nil,
              let url = c.url else { return nil }
        let parts = c.percentEncodedPath.split(separator: "/").compactMap { String($0).removingPercentEncoding }
        let target = repo.split(separator: "/").map(String.init)
        guard target.count == 2, parts.count >= 6,
              parts[0].caseInsensitiveCompare(target[0]) == .orderedSame,
              parts[1].caseInsensitiveCompare(target[1]) == .orderedSame,
              parts[2] == "releases", parts[3] == "download", !parts.last!.isEmpty,
              !parts.contains(".."), !parts.contains(".") else { return nil }
        return url
    }
    static func duplicate(name: String, names: [String]) -> Bool { names.contains(name) }
    static func displayBody(_ body: String) -> String { String(body.prefix(displayBodyLimit)) }
}
final class ReleaseAPIRedirectPolicy: NSObject, URLSessionDownloadDelegate {
    private let lock = NSLock()
    private var exceeded = false
    var exceededBudget: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Int64(ReleaseManagementRules.jsonLimit) || totalBytesExpectedToWrite > Int64(ReleaseManagementRules.jsonLimit) {
            lock.lock(); exceeded = true; lock.unlock()
            downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
// Non-actor helpers: JSON parsing and file size inspection never run on MainActor.
enum ReleaseJSON {
    static func decode<T: Decodable>(_ type: T.Type, file: URL) throws -> T {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? Int.max
        guard size <= ReleaseManagementRules.jsonLimit else { throw AppError(text: "发行版响应超过 8 MiB 预算，请在 GitHub 查看。") }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }
}
