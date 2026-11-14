import Foundation

struct AppVersion: Comparable {
    let parts: [Int]
    let prerelease: [String]
    let build: Int?
    init?(_ text: String) {
        let raw = text.hasPrefix("v") || text.hasPrefix("V") ? String(text.dropFirst()) : text
        let metadata = raw.split(separator: "+", omittingEmptySubsequences: false)
        guard metadata.count <= 2 else { return nil }
        let main = metadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = main[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (3...4).contains(numbers.count), numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && ($0.count == 1 || !$0.hasPrefix("0")) }), numbers.allSatisfy({ Int($0) != nil }) else { return nil }
        // A fourth numeric component is used for maintenance releases such as 1.0.5.1.
        parts = numbers.map { Int($0)! } + (numbers.count == 3 ? [0] : [])
        prerelease = main.count == 2 ? main[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        let identifiers = prerelease + (metadata.count == 2 ? metadata[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : [])
        guard identifiers.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 } }), prerelease.allSatisfy({ Int($0) == nil || $0.count == 1 || !$0.hasPrefix("0") }) else { return nil }
        build = metadata.count == 2 ? Int(metadata[1]) : nil
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for i in 0..<4 where lhs.parts[i] != rhs.parts[i] { return lhs.parts[i] < rhs.parts[i] }
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            if let x = Int(a), let y = Int(b) { return x < y }
            if Int(a) != nil { return true }; if Int(b) != nil { return false }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.parts == rhs.parts && lhs.prerelease == rhs.prerelease }
}
struct AppUpdateRelease: Decodable {
    struct Asset: Decodable { let name: String; let browser_download_url: URL }
    let tag_name: String
    let html_url: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    let body: String?
    var displayVersionWithBuild: String {
        guard let value = AppVersion(tag_name), let build = value.build else { return displayVersion }
        return AppUpdateSessionRules.version(displayVersion, build: String(build))
    }
    var displayVersion: String { String(tag_name.split(separator: "+", maxSplits: 1)[0]) }
    var ipaURL: URL? {
        let matches = assets.filter { $0.name == "RepoPocket.ipa" || $0.name == "RepoPocket-\(tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name).ipa" }
        guard matches.count == 1 else { return nil }
        let url = matches[0].browser_download_url
        guard url.scheme == "https", url.host == "github.com", url.path.hasPrefix("/wm0104/RepoPocket/releases/download/") else { return nil }
        return url
    }
}
enum AppUpdateRules {
    static func skippedKey(_ accountID: String) -> String { "RepoPocket.update.skipped." + accountID }
    /// A version the user already dismissed stays quiet until a newer release appears.
    static func shouldOfferStartupPrompt(version: String, skipped: String?) -> Bool {
        guard let skipped, !skipped.isEmpty else { return true }
        return skipped != version
    }
    static func conciseCheckError(_ error: Error) -> String {
        let reason = error.localizedDescription
        if reason.contains("速率") || reason.contains("过于频繁") { return "请求过于频繁，请稍后再试" }
        if reason.contains("凭据") || reason.contains("HTTP 401") { return "请重新登录" }
        if reason.contains("发布版本格式") { return "发行版版本号无法识别，请打开官方发行版页手动安装" }
        if let network = error as? URLError {
            switch network.code {
            case .notConnectedToInternet: return "网络未连接，请检查网络后重试"
            case .timedOut: return "连接 GitHub 超时，请检查网络后重试"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "无法连接 GitHub，请检查网络或代理后重试"
            case .secureConnectionFailed, .serverCertificateUntrusted: return "GitHub 安全连接失败，请检查网络和系统时间"
            default: break
            }
        }
        return "检查失败，请稍后重试"
    }
    static func statusError(_ status: Int, headers: [AnyHashable: Any] = [:], body: Data = Data(), authenticated: Bool = false) -> String {
        func header(_ name: String) -> String? {
            headers.first { String(describing: $0.key).lowercased() == name.lowercased() }.map { String(describing: $0.value) }
        }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let reason = (payload?["message"] as? String ?? "").lowercased()
        let fallback = " 可打开下方官方仓库下载页手动下载。"
        let identity = authenticated ? "当前账号" : "匿名出口 IP"
        if [403, 429].contains(status) {
            if header("x-ratelimit-remaining") == "0" || reason.contains("api rate limit exceeded") {
                var retry = "请稍后重试。"
                if let raw = header("x-ratelimit-reset"), let seconds = TimeInterval(raw), seconds.isFinite, seconds > 0, seconds < 253402300799 {
                    let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .medium
                    retry = "预计 \(formatter.string(from: Date(timeIntervalSince1970: seconds))) 重置后可重试。"
                }
                let advice = authenticated ? "" : " 已登录时将使用当前账号的现有 Token 检查；不会扩大权限。"
                return "GitHub \(identity)主速率额度已用尽。\(retry)\(advice)" + fallback
            }
            if reason.contains("secondary rate limit") || reason.contains("abuse") || header("retry-after") != nil {
                let retry = header("retry-after").flatMap(Int.init).flatMap { $0 > 0 ? "请至少等待 \($0) 秒再重试。" : nil } ?? "请稍后重试，避免连续检查。"
                return "GitHub 次级速率限制。" + retry + fallback
            }
            if status == 429 { return "GitHub 请求过于频繁，请稍后重试。" + fallback }
            return "GitHub 拒绝访问更新接口（HTTP 403），未确认是速率限制；请检查当前账号访问权限或稍后重试。" + fallback
        }
        if status == 401 { return "GitHub 当前账号凭据无效或已过期，请在账号管理中重新验证。" + fallback }
        if status == 404 { return "尚无可用的正式 Release，或发布源暂不可用。" + fallback }
        return "检查更新失败：GitHub HTTP \(status)，请稍后重试。" + fallback
    }
    static func isNewer(_ release: AppUpdateRelease, local: String, localBuild: String) throws -> Bool {
        guard !release.draft, !release.prerelease, let remote = AppVersion(release.tag_name), remote.prerelease.isEmpty, let current = AppVersion(local) else { throw AppError(text: "发布版本格式无效或不是正式版本，无法安全比较。") }
        if remote != current { return current < remote }
        // Numeric +metadata is a user revision when present locally, otherwise a legacy build marker.
        // Old clients cannot learn this change until manually installing the new IPA.
        if let remoteBuild = remote.build, let installedBuild = current.build ?? Int(localBuild) { return remoteBuild > installedBuild }
        return false
    }
}
