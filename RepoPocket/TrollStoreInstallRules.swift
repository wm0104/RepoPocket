import Foundation

/// Builds only the documented TrollStore install command for official RepoPocket IPAs.
/// Encode the entire nested URL, including query delimiters and literal plus signs.
enum TrollStoreInstallRules {
    static func installURL(for ipaURL: URL) -> URL? {
        let path = ipaURL.pathComponents
        guard ipaURL.scheme == "https", ipaURL.host == "github.com",
              ipaURL.user == nil, ipaURL.password == nil, ipaURL.port == nil,
              ipaURL.fragment == nil, path.count == 7,
              Array(path.prefix(5)) == ["/", "wm0104", "RepoPocket", "releases", "download"],
              path[5] != ".", path[5] != "..", !path[5].isEmpty,
              path[6].hasSuffix(".ipa"),
              path[6] == "RepoPocket.ipa" || path[6].hasPrefix("RepoPocket-") else { return nil }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = ipaURL.absoluteString.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        var components = URLComponents()
        components.scheme = "apple-magnifier"
        components.host = "install"
        components.percentEncodedQuery = "url=" + encoded
        return components.url
    }
}
