import Foundation
import Combine

struct DeviceAuthorization: Decodable {
    let device_code: String
    let user_code: String
    let verification_uri: String
    let expires_in: Int
    let interval: Int?
}
struct DeviceTokenResponse: Decodable {
    let access_token: String?
    let token_type: String?
    let error: String?
    let interval: Int?
}
enum DeviceOAuthRules {
    static func scope(privateRepositories: Bool, followUsers: Bool, writeProfile: Bool = false) -> String {
        (writeProfile ? "user" : "read:user") + (privateRepositories ? " repo" : " public_repo") + (followUsers ? " user:follow" : "")
    }
    static func clientID(_ source: String) throws -> String {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 100,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) && $0.isASCII }) else {
            throw AppError(text: "请填写你自己的 GitHub OAuth App Client ID。")
        }
        return value
    }
    static func validate(_ code: DeviceAuthorization) throws -> URL {
        guard let url = URL(string: code.verification_uri), url.scheme == "https", url.host == "github.com",
              url.path == "/login/device", url.user == nil, url.password == nil, url.port == nil,
              !code.device_code.isEmpty, !code.user_code.isEmpty, (1...3600).contains(code.expires_in) else {
            throw AppError(text: "GitHub 返回了无效的设备授权信息。")
        }
        return url
    }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.keys.sorted().map {
            ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + (fields[$0]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
    }
    // Retry transport interruptions only; rejection, cancellation and invalid credentials are terminal.
    static func isTransientNetworkFailure(_ error: Error) -> Bool {
        let failure = error as NSError
        guard failure.domain == NSURLErrorDomain else { return false }
        return [URLError.timedOut, .cannotFindHost, .cannotConnectToHost,
                .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet]
            .contains { $0.rawValue == failure.code }
    }
    static func failure(_ code: String) -> String {
        switch code {
        case "access_denied": return "你已取消 GitHub 授权。"
        case "expired_token": return "授权码已过期，请重新开始。"
        case "incorrect_client_credentials": return "Client ID 无效，请检查 OAuth App 配置。"
        case "device_flow_disabled": return "请先在 OAuth App 设置中启用 Device Flow。"
        default: return "设备授权失败，请检查 OAuth App 配置后重新开始。"
        }
    }
}

final class DeviceOAuthRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class DeviceOAuthController: ObservableObject {
    @Published private(set) var userCode = ""
    @Published private(set) var verificationURL: URL?
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    private var task: Task<Void, Never>?
    private var operation = UUID()
    private let session: URLSession
    private let wait: (UInt64) async throws -> Void
    init(session: URLSession? = nil, wait: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.session = session ?? Self.makeSession()
        self.wait = wait
    }
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: DeviceOAuthRedirectPolicy(), delegateQueue: nil)
    }
    func cancel() {
        operation = UUID(); task?.cancel(); task = nil; busy = false
        userCode = ""; verificationURL = nil
    }
    func start(clientID: String, privateRepositories: Bool, followUsers: Bool = false, writeProfile: Bool = false, api: GitHub, completed: @escaping () -> Void) {
        cancel(); message = ""; busy = true
        let identifier = operation
        task = Task { @MainActor in
            defer { if operation == identifier { busy = false; task = nil; userCode = ""; verificationURL = nil } }
            do {
                let client = try DeviceOAuthRules.clientID(clientID)
                let scope = DeviceOAuthRules.scope(privateRepositories: privateRepositories, followUsers: followUsers, writeProfile: writeProfile)
                let code: DeviceAuthorization = try await post("/login/device/code", fields: ["client_id": client, "scope": scope])
                let url = try DeviceOAuthRules.validate(code)
                try Task.checkCancellation(); guard operation == identifier, api.isCurrentSession else { return }
                userCode = code.user_code; verificationURL = url; message = "请在 GitHub 输入上方授权码；本页会等待授权结果。"
                let deadline = Date().addingTimeInterval(Double(code.expires_in))
                var interval = max(5, min(code.interval ?? 5, 60))
                var networkRetries = 0
                while Date() < deadline {
                    try await wait(UInt64(interval) * 1_000_000_000)
                    try Task.checkCancellation()
                    guard Date() < deadline, operation == identifier, api.isCurrentSession else { break }
                    let result: DeviceTokenResponse
                    do {
                        result = try await post("/login/oauth/access_token", fields: [
                            "client_id": client, "device_code": code.device_code,
                            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
                    } catch {
                        try Task.checkCancellation()
                        guard operation == identifier, api.isCurrentSession else { return }
                        guard DeviceOAuthRules.isTransientNetworkFailure(error), networkRetries < 3 else { throw error }
                        networkRetries += 1
                        // Respect the server interval and reduce frequency after a broken connection.
                        interval = min(3600, interval * 2)
                        message = "网络暂时中断，正在重试获取授权结果（\(networkRetries)/3）…"
                        continue
                    }
                    try Task.checkCancellation(); guard operation == identifier, api.isCurrentSession else { return }
                    if let token = result.access_token, !token.isEmpty, result.token_type?.lowercased() == "bearer" {
                        message = "GitHub 已授权，正在验证账号…"
                        var validationRetries = 0
                        while true {
                            try Task.checkCancellation()
                            guard operation == identifier, api.isCurrentSession else { return }
                            do {
                                try await api.addAccount(token: token)
                                break
                            } catch {
                                try Task.checkCancellation()
                                guard operation == identifier, api.isCurrentSession else { return }
                                guard DeviceOAuthRules.isTransientNetworkFailure(error), validationRetries < 3 else { throw error }
                                validationRetries += 1
                                message = "GitHub 已授权，网络暂时中断，正在重试验证账号（\(validationRetries)/3）…"
                                // Retain this token in memory; never request a second token after receipt.
                                try await wait(UInt64(1 << validationRetries) * 1_000_000_000)
                            }
                        }
                        if operation == identifier { message = "授权成功，账号已保存。"; completed() }
                        return
                    }
                    switch result.error {
                    case "authorization_pending":
                        message = "请在 GitHub 输入上方授权码；本页会等待授权结果。"
                        continue
                    case "slow_down": interval = min(3600, max(interval + 5, result.interval ?? 0))
                    default: throw AppError(text: DeviceOAuthRules.failure(result.error ?? "unknown"))
                    }
                }
                throw AppError(text: "授权码已过期，请重新开始。")
            } catch {
                if operation == identifier, !RefreshFailure.isCancellation(error) {
                    message = DeviceOAuthRules.isTransientNetworkFailure(error)
                        ? "网络连接暂时不可用，请检查网络后重新开始授权。"
                        : error.localizedDescription
                }
            }
        }
    }
    private func post<T: Decodable>(_ path: String, fields: [String: String]) async throws -> T {
        guard ["/login/device/code", "/login/oauth/access_token"].contains(path) else { throw AppError(text: "无效授权接口") }
        var request = URLRequest(url: URL(string: "https://github.com" + path)!)
        request.httpMethod = "POST"; request.httpBody = DeviceOAuthRules.form(fields)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("RepoPocket", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, bytes.count <= 64 * 1024 else {
            if let result = try? JSONDecoder().decode(DeviceTokenResponse.self, from: bytes), let error = result.error { throw AppError(text: DeviceOAuthRules.failure(error)) }
            throw AppError(text: "无法连接 GitHub 授权服务，请稍后重试。")
        }
        return try JSONDecoder().decode(T.self, from: bytes)
    }
}
