import Foundation

/// Shared summary semantics; missing API statistics remain missing, never invented zeros.
enum RepositoryPresentationRules {
    static func owner(login: String?, fullName: String) -> String {
        if let login, !login.isEmpty { return login }
        return fullName.split(separator: "/").first.map(String.init) ?? fullName
    }
    static func name(_ name: String, fullName: String) -> String {
        name.isEmpty ? (fullName.split(separator: "/").last.map(String.init) ?? fullName) : name
    }
    static func language(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    static func avatarURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https",
              url.host == "avatars.githubusercontent.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }
}
