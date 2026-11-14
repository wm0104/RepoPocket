import Foundation

struct WorkspaceComparison: Decodable { let status: String }

enum WorkspaceBaselineRules {
    static func validRevision(_ value: String) -> Bool {
        (7...40).contains(value.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
    static func matches(original: LocalSnapshot, verified: LocalSnapshot) -> Bool {
        original.hashes == verified.hashes
    }
    static func retryable(domain: String, code: Int) -> Bool {
        domain == NSURLErrorDomain && [NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet].contains(code)
    }
}

// Archive redirects may go to codeload/raw hosts. Never forward API credentials cross-host.
final class ArchiveRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https",
              ["api.github.com", "codeload.github.com", "raw.githubusercontent.com"].contains(url.host ?? "") else {
            completionHandler(nil); return
        }
        var redirected = request
        if url.host != response.url?.host {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(redirected)
    }
}
