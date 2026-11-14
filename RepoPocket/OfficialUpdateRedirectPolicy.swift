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
