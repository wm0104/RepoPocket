import Foundation

final class ReleaseAssetRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https",
              ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "") else { completionHandler(nil); return }
        var redirected = request
        // Even same-host redirects are unsigned; never send account tokens to attachment/CDN.
        redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(redirected)
    }
}
