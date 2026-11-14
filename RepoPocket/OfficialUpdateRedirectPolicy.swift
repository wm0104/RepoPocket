import Foundation

// Update metadata is expected at one immutable official API endpoint.
// Reject every redirect so an authenticated request never reaches assets/CDNs.
final class OfficialUpdateRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// README rendering may redirect after a repository rename. Keep authenticated
// requests on the official HTTPS API origin so credentials never reach a CDN.
final class GitHubAPIRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        func isGitHubAPI(_ url: URL?) -> Bool {
            guard let url, url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "api.github.com",
                  url.port == nil || url.port == 443,
                  url.user == nil, url.password == nil else { return false }
            return true
        }
        completionHandler(isGitHubAPI(task.currentRequest?.url) && isGitHubAPI(request.url) ? request : nil)
    }
}
