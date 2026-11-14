import Foundation

/// Makes one lightweight, credential-free request on first launch so iOS shows its
/// cellular-data permission prompt right away, instead of interrupting the user later
/// while they paste a Token or wait for an update check.
enum NetworkWarmup {
    static let key = "RepoPocket.network.warmed.v1"
    static let url = URL(string: "https://api.github.com/")!

    /// No credentials, no body, no query: only a HEAD probe so the system prompt can appear.
    static func request() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    /// Runs at most once per install unless the probe never reached the network.
    static func runOnceIfNeeded(session: URLSession = .shared,
                                defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: key) else { return }
        guard let response = try? await session.data(for: request()).1,
              response is HTTPURLResponse else { return }
        defaults.set(true, forKey: key)
    }
}
