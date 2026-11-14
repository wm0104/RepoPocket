import Foundation

struct AppUpdateSessionRules {
    /// App entry (launch and returning to the foreground) probes at most once per 15 minutes.
    static let cooldown: TimeInterval = 15 * 60
    static let probeVersion = "1.0.3-rc.1"
    static func isUpdateProbe(_ version: String) -> Bool { version == probeVersion }
    private(set) var attempted = false
    /// A new app entry may probe again; the per-account timestamp still spaces checks by `cooldown`.
    mutating func beginEntry() { attempted = false }
    mutating func claim(now: Date, last: Date?) -> Bool {
        guard !attempted else { return false }
        attempted = true
        guard last.map({ now.timeIntervalSince($0) >= Self.cooldown }) ?? true else { return false }
        return true
    }
    static func version(_ version: String, build: String) -> String { version }
}
