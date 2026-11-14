import Foundation
import Security

struct GitHubAccount: Codable, Identifiable, Equatable {
    let id: String
    let login: String
    let avatarURL: String?
    var oauthScopes: [String]? = nil
    var profileWriteAccess: Bool? = nil
    var profileWriteAuthorization: Bool? { profileWriteAccess ?? oauthScopes.map { $0.contains("user") } }
    static func grantedScopes(_ value: String?) -> [String]? {
        value.map { Array(Set($0.split { $0 == "," || $0.isWhitespace }.map(String.init))).sorted() }
    }
}

enum AccountStore {
    static let accountsKey = "github.accounts.v1"
    static let activeKey = "github.activeAccount.v1"
    static var accounts: [GitHubAccount] {
        guard let data = UserDefaults.standard.data(forKey: accountsKey) else { return [] }
        return (try? JSONDecoder().decode([GitHubAccount].self, from: data)) ?? []
    }
    static var activeID: String { UserDefaults.standard.string(forKey: activeKey) ?? "legacy" }
    private(set) static var generation = UUID()
    static func activate(_ id: String) {
        generation = UUID()
        UserDefaults.standard.set(id, forKey: activeKey)
        NotificationCenter.default.post(name: .githubAccountChanged, object: nil)
    }
    static func record(_ account: GitHubAccount) throws {
        var list = accounts.filter { $0.id != account.id }
        list.append(account)
        UserDefaults.standard.set(try JSONEncoder().encode(list), forKey: accountsKey)
    }
    static func updateAuthorization(_ id: String, scopes: [String]?, profileWriteAccess: Bool? = nil) {
        guard var account = accounts.first(where: { $0.id == id }) else { return }
        account.oauthScopes = scopes; account.profileWriteAccess = profileWriteAccess
        try? record(account)
        NotificationCenter.default.post(name: .githubAuthorizationChanged, object: nil, userInfo: ["account": id])
    }
    static func remove(_ id: String) {
        CredentialStore.clear(account: id)
        let list = accounts.filter { $0.id != id }
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: accountsKey) }
        if activeID == id { activate(list.first?.id ?? "legacy") }
    }
}

extension Notification.Name {
    static let githubAccountChanged = Notification.Name("RepoPocket.githubAccountChanged")
    static let githubAuthorizationChanged = Notification.Name("RepoPocket.githubAuthorizationChanged")
    static let githubAuthorizationCompleted = Notification.Name("RepoPocket.githubAuthorizationCompleted")
}
