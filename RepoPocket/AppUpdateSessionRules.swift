import Foundation

struct AppUpdateSessionRules {
    static let cooldown: TimeInterval = 6 * 60 * 60
    private(set) var attempted = false
    mutating func claim(now: Date, last: Date?) -> Bool {
        guard !attempted else { return false }
        attempted = true
        guard last.map({ now.timeIntervalSince($0) >= Self.cooldown }) ?? true else { return false }
        return true
    }
    static func version(_ version: String, build: String) -> String { "\(version)（\(build)）" }
}
