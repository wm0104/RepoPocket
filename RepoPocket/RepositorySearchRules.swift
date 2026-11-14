import Foundation

enum RepositorySearchKind: String, Codable { case repositories, users }
struct RepositoryRecentSearch: Codable, Equatable, Identifiable {
    let query: String
    let kind: RepositorySearchKind
    var id: String { kind.rawValue + ":" + query }
}
enum RepositorySearchRules {
    static func normalized(_ raw: String) -> String { raw.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func endpoint(kind: RepositorySearchKind, query: String, page: Int) -> URL {
        var components = URLComponents(string: "https://api.github.com/search/" + kind.rawValue)!
        components.queryItems = [URLQueryItem(name: "q", value: normalized(query)), .init(name: "per_page", value: "30"), .init(name: "page", value: String(max(1, page)))]
        return components.url!
    }
    static func record(_ item: RepositoryRecentSearch, in previous: [RepositoryRecentSearch]) -> [RepositoryRecentSearch] {
        let query = normalized(item.query)
        guard !query.isEmpty else { return previous }
        let clean = RepositoryRecentSearch(query: query, kind: item.kind)
        return Array(([clean] + previous.filter { !($0.kind == clean.kind && $0.query.caseInsensitiveCompare(query) == .orderedSame) }).prefix(15))
    }
    static func accepts(_ requested: UUID, current: UUID, account: UUID, currentAccount: UUID) -> Bool {
        requested == current && account == currentAccount
    }
}
struct RepositorySearchHistory {
    let accountID: String
    var defaults: UserDefaults = .standard
    private var key: String { "repositorySearchHistory." + Data(accountID.utf8).base64EncodedString() }
    func read() -> [RepositoryRecentSearch] {
        guard let bytes = defaults.data(forKey: key), let records = try? JSONDecoder().decode([RepositoryRecentSearch].self, from: bytes) else { return [] }
        return records
    }
    func record(_ query: String, kind: RepositorySearchKind) {
        let records = RepositorySearchRules.record(.init(query: query, kind: kind), in: read())
        if let bytes = try? JSONEncoder().encode(records) { defaults.set(bytes, forKey: key) }
    }
    func clear() { defaults.removeObject(forKey: key) }
    func remove(_ item: RepositoryRecentSearch) {
        if let bytes = try? JSONEncoder().encode(read().filter { $0 != item }) { defaults.set(bytes, forKey: key) }
    }
}
struct RepositorySearchResponse: Decodable { let items: [Repository]; let total_count: Int }
struct UserSearchResponse: Decodable { let items: [User]; let total_count: Int }
